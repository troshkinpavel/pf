import Darwin
import Foundation
import Security

// Agent Access transport (docs/PLAN-0.8.md §3): a Unix domain socket inside PF's sandbox
// container, owned by the running app only while Agent Access is on. No network port.
// The MCP client launches PF's own binary with `--mcp` (MCPRelay), which connects here.

enum AgentTransport {
    /// MCP stdio framing: one JSON message per line. Longer lines are refused.
    static let maxLine = 1 << 20
    static let relayProtocol = 1

    /// `~/Library/Containers/<bundle id>/Data/tmp/pf-mcp.sock` for the sandboxed app and its relay
    /// (same container); a test passes its own directory.
    static func socketURL(in dir: URL = FileManager.default.temporaryDirectory) -> URL {
        dir.appendingPathComponent("pf-mcp.sock")
    }

    /// sockaddr_un holds 104 bytes including the terminator.
    static func fits(_ url: URL) -> Bool { url.path.utf8.count < 104 }

    static func address(_ url: URL) -> sockaddr_un {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        withUnsafeMutableBytes(of: &a.sun_path) { raw in
            for (i, b) in bytes.prefix(raw.count - 1).enumerated() { raw[i] = b }
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return a
    }

    /// Writes all of `data` (blocking socket). false when the peer is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// Splits a byte buffer into complete lines; keeps the rest. nil = a line exceeded `maxLine`.
    static func takeLines(_ buf: inout Data) -> [Data]? {
        var out: [Data] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]
            buf = Data(buf[(nl + 1)...])
            if line.count > maxLine { return nil }
            let trimmed = line.last == 0x0D ? Data(line.dropLast()) : Data(line)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        if buf.count > maxLine { return nil }
        return out
    }

    // MARK: peer identity

    /// True when the connected process is signed like this one (same designated requirement):
    /// only PF's own binary, launched as the relay, may talk to the socket.
    static func peerIsThisApp(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL = 0, LOCAL_PEERTOKEN = 6 (sys/un.h)
        guard getsockopt(fd, 0, 6, &token, &len) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &peer) == errSecSuccess, let peer else { return false }
        var me: SecCode?, meStatic: SecStaticCode?, req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(peer, [], req) == errSecSuccess
    }

    /// Constant-time comparison for the credential.
    static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var d: UInt8 = 0
        for i in x.indices { d |= x[i] ^ y[i] }
        return d == 0
    }

    static func newCredential() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return "pfm_" + Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The app side: listens while Agent Access is on. Every connection starts with a handshake
/// line `{"pf_relay":1,"token":"…","client":"…"}`, then carries MCP JSON-RPC lines.
final class AgentServer: @unchecked Sendable {
    struct Peer: Sendable { let id: Int; let pid: Int32 }

    /// Called on the main actor: handshake (token) → accepted?; then each MCP line → reply lines.
    typealias Authorize = @MainActor (_ token: String, _ peer: Peer) -> Bool
    typealias Handle = @MainActor (_ line: Data, _ peer: Peer) async -> [Data]
    typealias Closed = @MainActor (_ peer: Peer) -> Void

    let url: URL
    private let queue = DispatchQueue(label: "pf.agent.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var conns: [Int: Conn] = [:]
    private var nextID = 1
    private let authorize: Authorize, handle: Handle, closed: Closed
    /// Tests: accept any peer (the test host isn't the relay binary in its own process).
    var requirePeerSignature = true

    /// Touched only on `queue`.
    private final class Conn: @unchecked Sendable {
        let id: Int, fd: Int32, pid: Int32
        /// Replies are written here, blocking, so a slow reader never stalls other connections.
        let out = DispatchQueue(label: "pf.agent.conn.out")
        var source: DispatchSourceRead?
        var buf = Data()
        var authed = false
        var authing = false
        /// Lines that arrived while the handshake was being checked.
        var early: [Data] = []
        var inbox: AsyncStream<Data>.Continuation?
        init(id: Int, fd: Int32, pid: Int32) { self.id = id; self.fd = fd; self.pid = pid }
    }

    init(url: URL, authorize: @escaping Authorize, handle: @escaping Handle, closed: @escaping Closed) {
        self.url = url; self.authorize = authorize; self.handle = handle; self.closed = closed
    }

    enum StartError: Error, CustomStringConvertible {
        case pathTooLong, socket(Int32)
        var description: String {
            switch self { case .pathTooLong: "socket path too long"; case let .socket(e): "socket error \(e)" }
        }
    }

    func start() throws {
        guard AgentTransport.fits(url) else { throw StartError.pathTooLong }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)   // a stale socket from a crash
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        var addr = AgentTransport.address(url)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { let e = errno; close(fd); throw StartError.socket(e) }
        chmod(url.path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); unlink(url.path); throw StartError.socket(e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { close(fd) }
        acceptSource = src
        src.resume()
    }

    /// Closes the listener and every connection, removes the socket file. Synchronous.
    func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            listenFD = -1
            unlink(url.path)
            for c in conns.values { drop(c) }
            conns.removeAll()
        }
    }

    /// A server-initiated line (e.g. notifications/tools/list_changed) to every client.
    func broadcast(_ line: Data) {
        queue.async { for c in self.conns.values where c.authed { c.out.async { AgentTransport.writeAll(c.fd, line + [0x0A]) } } }
    }

    var connectionCount: Int { queue.sync { conns.values.filter(\.authed).count } }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // macOS: the accepted socket inherits O_NONBLOCK from the listener; replies larger than
            // the socket buffer would be cut short. Writes are blocking (on the connection's queue).
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var tv = timeval(tv_sec: 10, tv_usec: 0)   // a client that stops reading can't block a write forever
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var pid: Int32 = 0
            var plen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, 0, 2 /* LOCAL_PEERPID */, &pid, &plen)
            if requirePeerSignature, !AgentTransport.peerIsThisApp(fd) {
                AgentTransport.writeAll(fd, Data(#"{"pf_relay":1,"ok":false,"error":"peer_rejected"}"#.utf8 + [0x0A]))
                close(fd)
                continue
            }
            let c = Conn(id: nextID, fd: fd, pid: pid)
            nextID += 1
            conns[c.id] = c
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readable(c) }
            c.source = src
            src.resume()
        }
    }

    private func readable(_ c: Conn) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(c.fd, &chunk, chunk.count)
        if n == 0 && c.authed {
            // The client half-closed: answer what it sent, then close (the pump calls remove).
            c.source?.cancel(); c.source = nil
            c.inbox?.finish()
            return
        }
        if n <= 0 { remove(c); return }
        c.buf.append(contentsOf: chunk[0..<n])
        guard let lines = AgentTransport.takeLines(&c.buf) else {
            AgentTransport.writeAll(c.fd, Data(MCP.errorLine(id: .null, code: -32600, message: "message too large").utf8 + [0x0A]))
            remove(c)
            return
        }
        for l in lines {
            if c.authed { c.inbox?.yield(l) }
            else if c.authing { c.early.append(l) }
            else { handshake(c, l); if conns[c.id] == nil { return } }
        }
    }

    private func handshake(_ c: Conn, _ line: Data) {
        guard let j = try? JSON.parse(line), j["pf_relay"]?.double == Double(AgentTransport.relayProtocol), let token = j["token"]?.string else {
            AgentTransport.writeAll(c.fd, Data(#"{"pf_relay":1,"ok":false,"error":"bad_handshake"}"#.utf8 + [0x0A]))
            remove(c)
            return
        }
        let peer = Peer(id: c.id, pid: c.pid)
        // Hop to the main actor for the credential check; later lines wait in `early`.
        c.authing = true
        Task { @MainActor [weak self] in
            let ok = self?.authorize(token, peer) ?? false
            self?.queue.async {
                guard let self, self.conns[c.id] != nil else { return }
                if !ok {
                    AgentTransport.writeAll(c.fd, Data(#"{"pf_relay":1,"ok":false,"error":"invalid_credential"}"#.utf8 + [0x0A]))
                    self.remove(c, notify: false)
                    return
                }
                c.authed = true; c.authing = false
                AgentTransport.writeAll(c.fd, Data(#"{"pf_relay":1,"ok":true}"#.utf8 + [0x0A]))
                self.startPump(c, peer)
                for l in c.early { c.inbox?.yield(l) }
                c.early = []
            }
        }
    }

    /// Messages of one connection are handled in order, one at a time, on the main actor.
    private func startPump(_ c: Conn, _ peer: Peer) {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        c.inbox = cont
        let fd = c.fd
        Task { @MainActor [weak self] in
            for await line in stream {
                guard let self else { return }
                let replies = await self.handle(line, peer)
                guard !replies.isEmpty else { continue }
                self.queue.async {
                    guard self.conns[c.id] != nil else { return }
                    c.out.async { for r in replies { AgentTransport.writeAll(fd, r + [0x0A]) } }
                }
            }
            self?.queue.async { if let self, self.conns[c.id] != nil { self.remove(c) } }
        }
    }

    private func remove(_ c: Conn, notify: Bool = true) {
        guard conns.removeValue(forKey: c.id) != nil else { return }
        let wasAuthed = c.authed
        drop(c)
        if notify && wasAuthed { let p = Peer(id: c.id, pid: c.pid); Task { @MainActor [weak self] in self?.closed(p) } }
    }

    private func drop(_ c: Conn) {
        c.inbox?.finish()
        c.source?.cancel(); c.source = nil
        let fd = c.fd
        c.out.async { close(fd) }   // after any reply still being written
    }
}

/// `PF Terminal --mcp`: what the MCP client launches. A byte relay between stdio and the running
/// app's socket; it never opens PF data itself. Exits when either side closes.
enum MCPRelay {
    /// `PF_MCP_DEBUG=1`: stage trace on stderr (MCP clients show it in their server log). No secrets.
    private static let debug = ProcessInfo.processInfo.environment["PF_MCP_DEBUG"] == "1"
    private static func trace(_ s: String) { if debug { FileHandle.standardError.write(Data(("pf-mcp: " + s + "\n").utf8)) } }

    static func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let token = ProcessInfo.processInfo.environment["PF_MCP_TOKEN"] ?? ""
        let url = AgentTransport.socketURL()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = AgentTransport.address(url)
        let connected = fd >= 0 && AgentTransport.fits(url) && withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        trace("socket \(connected ? "connected" : "unavailable (errno \(errno))") · credential \(token.isEmpty ? "missing" : "present")")
        guard connected else {
            return unavailable(code: "pf_unavailable", "PF Terminal isn't running, or Agent Access is off. Open PF Terminal → Settings → agents.")
        }
        let client = ProcessInfo.processInfo.environment["PF_MCP_CLIENT"] ?? ""
        let hello: JSON = ["pf_relay": .int(AgentTransport.relayProtocol), "token": .str(token), "client": .str(client)]
        guard AgentTransport.writeAll(fd, Data(hello.text.utf8 + [0x0A])) else { return unavailable(code: "pf_unavailable", "PF Terminal closed the connection.") }
        // Handshake reply.
        var buf = Data()
        var reply: JSON?
        var chunk = [UInt8](repeating: 0, count: 4096)
        while reply == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if let line = AgentTransport.takeLines(&buf)?.first { reply = try? JSON.parse(line) }
        }
        trace("handshake " + (reply?.text ?? "no reply"))
        guard reply?["ok"]?.bool == true else {
            let e = reply?["error"]?.string ?? "pf_unavailable"
            let why = e == "invalid_credential" ? "The credential in this client's configuration doesn't match. Copy the configuration again from PF Terminal → Settings → agents."
                : e == "peer_rejected" ? "PF Terminal only accepts its own signed executable as the MCP command."
                : "PF Terminal refused the connection (\(e))."
            close(fd)
            return unavailable(code: e, why)
        }
        // socket → stdout on a thread; stdin → socket here. Leftover bytes after the handshake go first.
        let out = Thread {
            if !buf.isEmpty { FileHandle.standardOutput.write(buf) }
            var c = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &c, c.count)
                if n <= 0 { exit(0) }   // PF closed: access turned off or the app quit
                let d = Data(c[0..<n])
                var off = 0
                while off < d.count {
                    let w = d.withUnsafeBytes { Darwin.write(1, $0.baseAddress! + off, d.count - off) }
                    if w <= 0 { exit(0) }
                    off += w
                }
            }
        }
        out.start()
        var c = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(0, &c, c.count)
            if n <= 0 { break }
            if !AgentTransport.writeAll(fd, Data(c[0..<n])) { break }
        }
        shutdown(fd, SHUT_WR)
        // Let the last replies drain, then leave.
        Thread.sleep(forTimeInterval: 0.5)
        return 0
    }

    /// No connection: answer each request with a JSON-RPC error until stdin closes, so the
    /// client shows why instead of a silent failure.
    private static func unavailable(code: String, _ message: String) -> Int32 {
        var buf = Data()
        var c = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(0, &c, c.count)
            if n <= 0 { return 1 }
            buf.append(contentsOf: c[0..<n])
            guard let lines = AgentTransport.takeLines(&buf) else { return 1 }
            for l in lines {
                guard let j = try? JSON.parse(l), let id = j["id"], j["method"] != nil else { continue }   // notifications get no reply
                let line = MCP.errorLine(id: id, code: -32001, message: message, data: ["code": .str(code)])
                FileHandle.standardOutput.write(Data(line.utf8 + [0x0A]))
            }
        }
    }
}
