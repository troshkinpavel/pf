import PFCore
import Foundation
import Observation

// Model Context Protocol, server side (JSON-RPC 2.0 over the relay's stdio lines).
// Methods: initialize · ping · tools/list · tools/call · resources/list · resources/templates/list ·
// resources/read · prompts/list · prompts/get. Everything else: method not found.

enum MCP {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// PF's own tool/resource API version: bumped only for breaking schema changes.
    static let apiVersion = 1

    static func errorLine(id: JSON, code: Int, message: String, data: JSON? = nil) -> String {
        var e: [(String, JSON)] = [("code", .int(code)), ("message", .str(message))]
        if let data { e.append(("data", data)) }
        return JSON.obj([("jsonrpc", "2.0"), ("id", id), ("error", .obj(e))]).text
    }

    static func resultLine(id: JSON, _ result: JSON) -> String {
        JSON.obj([("jsonrpc", "2.0"), ("id", id), ("result", result)]).text
    }

    static func notificationLine(_ method: String) -> String {
        JSON.obj([("jsonrpc", "2.0"), ("method", .str(method))]).text
    }
}

/// One frozen operation waiting for the user (docs/PLAN-0.8.md §6).
struct AgentConfirmation: Identifiable {
    enum State: String { case pending, confirmed, denied, expired, failed }
    let id: String
    let tool: String
    let tier: AgentTier
    let client: String
    let connection: Int
    let portfolio: UUID?
    /// What the user reads: one line per row, already redacted only for the agent-facing copy.
    let title: String
    let lines: [String]
    let createdAt: Date
    let expiresAt: Date
    var state: State = .pending
    var result: JSON?
    var error: AgentFailure?
    let run: @MainActor () throws -> JSON
}

/// Agent Access runtime state: settings, the socket server, sessions, confirmations, activity.
@MainActor @Observable
final class AgentRuntime {
    struct Session: Equatable {
        let id: Int
        var client = "unknown client"
        var version = ""
        var protocolVersion = MCP.supportedVersions[0]
        var connectedAt = Date()
        var lastRequestAt = Date()
    }

    var settings: AgentSettings
    var sessions: [Int: Session] = [:]
    var lastConnected: (client: String, at: Date)?
    var pending: [AgentConfirmation] = []
    /// Outcomes for pf_get_confirmation, kept 30 min.
    var finished: [String: AgentConfirmation] = [:]
    var audit: AgentAuditLog
    var serverError: String?
    var lastWriteAt: Date?
    var listening = false
    @ObservationIgnored var server: AgentServer?
    /// Prices fetched for agent requests about assets PF doesn't track (like the transaction
    /// sheet's candidate quotes): never added to `quotes`, so they don't join the refresh set.
    @ObservationIgnored var quoteCache: [AssetID: Quote] = [:]
    /// Long-tail assets found by online search for agent requests (outside the bundled registry).
    @ObservationIgnored var foundAssets: [AssetID: Asset] = [:]
    /// Real providers for agent lookups while the app runs on mock prices (demo only).
    @ObservationIgnored var liveRouter: ProviderRouter?
    @ObservationIgnored var expiryTask: Task<Void, Never>?
    /// Tests inject a credential and skip the Keychain.
    @ObservationIgnored var credentialOverride: String?
    @ObservationIgnored let socketDirectory: URL?

    static let confirmationLifetime: TimeInterval = 120
    static let maxPending = 5

    init(settings: AgentSettings, auditDirectory: URL?, socketDirectory: URL? = nil) {
        self.settings = settings
        self.audit = AgentAuditLog(directory: auditDirectory)
        self.socketDirectory = socketDirectory
    }

    var credential: String {
        if let c = credentialOverride { return c }
        if let c = Keychain.get(Self.keychainAccount) { return c }
        let c = AgentTransport.newCredential()
        Keychain.set(c, for: Self.keychainAccount)
        return c
    }
    static let keychainAccount = "agent-mcp-credential"

    func regenerateCredential() {
        if credentialOverride != nil { credentialOverride = AgentTransport.newCredential(); return }
        Keychain.set(AgentTransport.newCredential(), for: Self.keychainAccount)
    }

    var socketURL: URL { AgentTransport.socketURL(in: socketDirectory ?? FileManager.default.temporaryDirectory) }
    var connected: Bool { !sessions.isEmpty }
}

extension AppStore {
    // MARK: dispatch

    /// One MCP line in, zero or one line out.
    func agentHandle(_ line: Data, connection: Int) async -> [Data] {
        let rt = agent
        guard rt.settings.enabled else { return [Data(MCP.errorLine(id: .null, code: -32001, message: "agent access is off").utf8)] }
        guard let msg = try? JSON.parse(line) else { return [Data(MCP.errorLine(id: .null, code: -32700, message: "parse error").utf8)] }
        guard case .obj = msg else { return [Data(MCP.errorLine(id: .null, code: -32600, message: "invalid request (batches are not supported)").utf8)] }
        let id = msg["id"]
        guard msg["jsonrpc"]?.string == "2.0", let method = msg["method"]?.string else {
            if msg["result"] != nil || msg["error"] != nil { return [] }   // a reply to nothing we sent
            return [Data(MCP.errorLine(id: id ?? .null, code: -32600, message: "invalid request").utf8)]
        }
        if let id, !(id.string != nil || id.double != nil) { return [Data(MCP.errorLine(id: .null, code: -32600, message: "invalid id").utf8)] }
        rt.sessions[connection]?.lastRequestAt = Date()
        guard let id else { agentNotification(method, msg["params"], connection: connection); return [] }
        let params = msg["params"] ?? .obj([])
        guard case .obj = params else { return [Data(MCP.errorLine(id: id, code: -32602, message: "params must be an object").utf8)] }
        do {
            let result = try await agentMethod(method, params, connection: connection)
            return [Data(MCP.resultLine(id: id, result).utf8)]
        } catch let e as MCPMethodError {
            return [Data(MCP.errorLine(id: id, code: e.code, message: e.message, data: e.data).utf8)]
        } catch {
            return [Data(MCP.errorLine(id: id, code: -32603, message: "internal error").utf8)]
        }
    }

    struct MCPMethodError: Error { let code: Int; let message: String; var data: JSON? }

    private func agentNotification(_ method: String, _ params: JSON?, connection: Int) {
        // notifications/initialized, notifications/cancelled, …: nothing to do.
    }

    private func agentMethod(_ method: String, _ p: JSON, connection: Int) async throws -> JSON {
        switch method {
        case "initialize":
            let asked = p["protocolVersion"]?.string ?? MCP.supportedVersions[0]
            let version = MCP.supportedVersions.contains(asked) ? asked : MCP.supportedVersions[0]
            var s = agent.sessions[connection] ?? AgentRuntime.Session(id: connection)
            s.client = String((p["clientInfo"]?["name"]?.string ?? "unknown client").prefix(60))
            s.version = String((p["clientInfo"]?["version"]?.string ?? "").prefix(30))
            s.protocolVersion = version
            agent.sessions[connection] = s
            agent.lastConnected = (s.client, Date())
            return .obj([
                ("protocolVersion", .str(version)),
                ("capabilities", ["tools": ["listChanged": true], "resources": ["listChanged": true, "subscribe": false], "prompts": ["listChanged": false]]),
                ("serverInfo", .obj([("name", "pf-terminal"), ("title", "PF Terminal"), ("version", .str(installedVersion.display)), ("pfMcpApiVersion", .int(MCP.apiVersion))])),
                ("instructions", .str(Self.agentInstructions)),
            ])
        case "ping":
            return .obj([])
        case "tools/list":
            return .obj([("tools", .arr(agentVisibleTools.map(\.listing)))])
        case "tools/call":
            guard let name = p["name"]?.string else { throw MCPMethodError(code: -32602, message: "tools/call needs a name") }
            let args = p["arguments"] ?? .obj([])
            guard case .obj = args else { throw MCPMethodError(code: -32602, message: "arguments must be an object") }
            guard AgentTools.byName[name] != nil else { throw MCPMethodError(code: -32602, message: "unknown tool: \(name.prefix(64))") }
            await agentPrefetchQuote(args["asset"]?.string)
            return agentCallTool(name, args, connection: connection)
        case "resources/list":
            return .obj([("resources", .arr(agentResourceList))])
        case "resources/templates/list":
            return .obj([("resourceTemplates", .arr(AgentResources.templates))])
        case "resources/read":
            guard let uri = p["uri"]?.string else { throw MCPMethodError(code: -32602, message: "resources/read needs a uri") }
            if let (_, a) = AgentResources.route(uri) { await agentPrefetchQuote(a["asset"]?.string) }
            return try agentReadResource(uri, connection: connection)
        case "prompts/list":
            return .obj([("prompts", .arr(AgentPrompts.all.map(\.listing)))])
        case "prompts/get":
            guard let name = p["name"]?.string, let pr = AgentPrompts.all.first(where: { $0.name == name }) else {
                throw MCPMethodError(code: -32602, message: "unknown prompt")
            }
            return pr.render(p["arguments"])
        case "logging/setLevel":
            return .obj([])
        default:
            throw MCPMethodError(code: -32601, message: "method not found: \(method.prefix(64))")
        }
    }

    static let agentInstructions = """
    PF Terminal is a local-first crypto portfolio tracker. It never trades or moves funds: when the user \
    asks to buy or sell, they mean recording that transaction in their tracker (pf_add_transaction). \
    These tools read the user's portfolio and, \
    when the user allowed it, change it through PF's own validation. Amounts may be omitted when the \
    user hasn't exposed exact values: say so instead of guessing. Assets are identified by canonical ids \
    (e.g. cg:bitcoin); call pf_resolve_asset when a ticker is ambiguous. Changes to the ledger and \
    deletions return confirmation_required: the user approves or denies them in PF Terminal, then \
    pf_get_confirmation returns the outcome. Use dry_run to preview a transaction. Start with \
    pf_get_portfolio_context.
    """

    // MARK: tools/call

    /// Permission → lock → handler → (confirmation) → audit. Tool errors come back as isError results.
    func agentCallTool(_ name: String, _ args: JSON, connection: Int) -> JSON {
        let tool = AgentTools.byName[name]!
        let s = agent.settings
        let client = agent.sessions[connection]?.client ?? "unknown client"
        func fail(_ f: AgentFailure, portfolio: String? = nil) -> JSON {
            agentAudit(connection, client, tool, portfolio: portfolio, result: "error", error: f.code.rawValue)
            return AgentTools.errorResult(f)
        }
        if tool.tier.isWrite && s.mode != .readWrite { return fail(AgentFailure(.readOnly)) }
        if let d = tool.data, !AgentExposure(s: s).allows(d) { return fail(AgentFailure(.permissionDenied, "\(tool.dataLabel) not exposed to agents (PF Terminal → Settings → agents)")) }
        if tool.tier != .status {
            if locked { return fail(AgentFailure(.appLocked)) }
            if protectedDataWaiting || ledgerLoadDeferred { return fail(AgentFailure(.protectedDataUnavailable)) }
        }
        do {
            let a = try AgentArgs(args, allowed: tool.argNames)
            let outcome = try agentRun(tool, a)
            switch outcome {
            case let .result(j, pid):
                agentAudit(connection, client, tool, portfolio: pid, result: "ok")
                if tool.tier.isWrite { agent.lastWriteAt = Date() }
                return AgentTools.okResult(j)
            case let .confirm(op):
                if a.bool("dry_run") == true { return AgentTools.okResult(op.preview) }
                if !tool.tier.needsConfirmation(s) {
                    let j = try op.run()
                    agentAudit(connection, client, tool, portfolio: op.portfolio.map(Self.shortID), result: "ok")
                    agent.lastWriteAt = Date()
                    return AgentTools.okResult(j)
                }
                let c = try agentRequestConfirmation(op, tool: tool, client: client, connection: connection)
                agentAudit(connection, client, tool, portfolio: op.portfolio.map(Self.shortID), result: "confirmation_requested", confirmation: c.id)
                return AgentTools.okResult(.obj([
                    ("status", "confirmation_required"), ("confirmation_id", .str(c.id)),
                    ("summary", .arr(op.agentLines.map(JSON.str))), ("expires_at", .date(c.expiresAt)),
                    ("next", "ask the user to confirm in PF Terminal, then call pf_get_confirmation"),
                ]))
            }
        } catch let f as AgentFailure {
            return fail(f)
        } catch {
            return fail(AgentFailure(.internalError))
        }
    }

    /// Any coin, as the add-transaction sheet finds it: a ticker outside the bundled registry is
    /// looked up online (unique exact match, else the candidates come back as asset_ambiguous), and
    /// an asset PF doesn't track gets one quote through the provider router and its backoff.
    /// With mock prices (demo) both fall back to the real providers. Silent on failure.
    func agentPrefetchQuote(_ q: String?) async {
        guard let q, agent.settings.enabled, !locked else { return }
        var a: Asset?, notFound = false
        do { a = try agentAsset(q) } catch let f as AgentFailure { notFound = f.code == .assetNotFound } catch {}
        if a == nil, notFound {
            let hits = await (mockMarket ? agentLiveRouter : router).search(q)
            for h in hits.prefix(20) { agent.foundAssets[h.id] = h }
            if agent.foundAssets.count > 200 { agent.foundAssets = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) }) }
            a = try? agentAsset(q)
        }
        guard let a, agentQuote(a.id) == nil else { return }
        var qt = await router.quotes(for: [routed(a)], currency: settings.currency).quotes[a.id]
        if qt == nil, mockMarket { qt = await agentLiveRouter.quotes(for: [a], currency: settings.currency).quotes[a.id] }
        if let qt { agent.quoteCache[a.id] = qt }
    }

    private var agentLiveRouter: ProviderRouter {
        if let r = agent.liveRouter { return r }
        let r = ProviderRouter(providers: [BinanceProvider(), BybitProvider(), CoinGeckoProvider(apiKey: Keychain.get("coingecko-api-key")), DexScreenerProvider()])
        agent.liveRouter = r
        return r
    }

    /// Tracked price first, then one fetched for an agent request (5 min).
    func agentQuote(_ id: AssetID) -> Quote? {
        if let q = valuationQuotes[id] { return q }
        if let q = agent.quoteCache[id], Date().timeIntervalSince(q.timestamp) < 300 { return q }
        return nil
    }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    func agentAudit(_ connection: Int, _ client: String, _ tool: AgentTool, portfolio: String? = nil, result: String, error: String? = nil, confirmation: String? = nil) {
        let e = AgentAuditEntry(at: Date(), connection: connection, client: client, tool: tool.name, tier: tool.tier.rawValue,
                                portfolio: portfolio, result: result, error: error, confirmation: confirmation)
        agent.audit.append(e, persist: agent.settings.keepAudit)
    }

    // MARK: confirmations

    func agentRequestConfirmation(_ op: AgentOperation, tool: AgentTool, client: String, connection: Int) throws -> AgentConfirmation {
        agentExpireConfirmations()
        guard agent.pending.count < AgentRuntime.maxPending else { throw AgentFailure(.rateLimited, "\(AgentRuntime.maxPending) requests already wait for the user") }
        let now = Date()
        let c = AgentConfirmation(id: "cf_" + AgentTransport.newCredential().dropFirst(4).prefix(22), tool: tool.name, tier: tool.tier, client: client, connection: connection,
                                  portfolio: op.portfolio, title: op.title, lines: op.userLines, createdAt: now,
                                  expiresAt: now.addingTimeInterval(AgentRuntime.confirmationLifetime), run: op.run)
        agent.pending.append(c)
        agentScheduleExpiry()
        if settings.alertBanner { Notifier.postAlert(id: "pf.agent.confirm", title: "PF Terminal · agent request", body: "\(client) is waiting for your confirmation", sound: false) }
        return c
    }

    /// The user's answer in the overlay. Confirm runs the frozen operation once.
    func agentResolve(_ id: String, confirm: Bool) {
        agentExpireConfirmations()
        guard let i = agent.pending.firstIndex(where: { $0.id == id }) else { return }
        guard !confirm || !locked else { return }   // details and confirm need an unlocked app
        var c = agent.pending.remove(at: i)
        let tool = AgentTools.byName[c.tool]!
        if confirm {
            do {
                c.result = try c.run()
                c.state = .confirmed
                agent.lastWriteAt = Date()
                message = "✓ agent request confirmed · " + c.title
            } catch let f as AgentFailure {
                c.state = .failed; c.error = f
                message = "✗ agent request failed · " + f.message
            } catch {
                c.state = .failed; c.error = AgentFailure(.internalError)
            }
        } else {
            c.state = .denied
            message = "agent request denied · nothing changed"
        }
        agent.finished[c.id] = c
        agentAudit(c.connection, c.client, tool, portfolio: c.portfolio.map(Self.shortID), result: c.state.rawValue, error: c.error?.code.rawValue, confirmation: c.id)
    }

    func agentExpireConfirmations(now: Date = Date()) {
        let gone = agent.pending.filter { $0.expiresAt <= now }
        guard !gone.isEmpty || agent.finished.contains(where: { now.timeIntervalSince($0.value.expiresAt) > 1800 }) else { return }
        agent.pending.removeAll { $0.expiresAt <= now }
        for var c in gone {
            c.state = .expired
            agent.finished[c.id] = c
            if let t = AgentTools.byName[c.tool] { agentAudit(c.connection, c.client, t, portfolio: c.portfolio.map(Self.shortID), result: "expired", confirmation: c.id) }
        }
        agent.finished = agent.finished.filter { now.timeIntervalSince($0.value.expiresAt) <= 1800 }
    }

    private func agentScheduleExpiry() {
        agent.expiryTask?.cancel()
        guard let next = agent.pending.map(\.expiresAt).min() else { return }
        agent.expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, next.timeIntervalSinceNow + 0.05) * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.agentExpireConfirmations()
            self.agentScheduleExpiry()
        }
    }
}
