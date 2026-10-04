import PFCore
import PFCoreUI
import AppKit
import SwiftUI

// 0.8 Agent Access lifecycle and UI glue (docs/PLAN-0.8.md). Off by default; the socket exists
// only while it is on, and the kill switch closes it and every connection at once.

extension AppStore {
    // MARK: lifecycle

    func agentStart() {
        guard agent.server == nil else { return }
        let server = AgentServer(url: agent.socketURL,
            authorize: { [weak self] token, peer in
                guard let self, self.agent.settings.enabled else { return false }
                let ok = AgentTransport.sameSecret(token, self.agent.credential)
                if ok { self.agent.sessions[peer.id] = AgentRuntime.Session(id: peer.id) }
                else { self.diagnostics.record(.app, .warning, "agent-credential-rejected") }
                return ok
            },
            handle: { [weak self] line, peer in await self?.agentHandle(line, connection: peer.id) ?? [] },
            closed: { [weak self] peer in self?.agent.sessions[peer.id] = nil })
        do {
            try server.start()
            agent.server = server
            agent.listening = true
            agent.serverError = nil
            diagnostics.record(.app, .info, "agent-access-on")
        } catch {
            agent.serverError = "\(error)"
            agent.listening = false
            diagnostics.record(.app, .error, "agent-access-failed", error: error)
        }
    }

    func agentStop() {
        agent.server?.stop()
        agent.server = nil
        agent.listening = false
        agent.sessions = [:]
        // Nothing waits for a user who switched access off.
        for var c in agent.pending {
            c.state = .denied
            agent.finished[c.id] = c
            if let t = AgentTools.byName[c.tool] { agentAudit(c.connection, c.client, t, result: "denied", error: "access_disabled", confirmation: c.id) }
        }
        agent.pending = []
    }

    /// Settings changes go through here: persisted, applied, announced to connected clients.
    func agentUpdate(_ change: (inout AgentSettings) -> Void) {
        let old = agent.settings
        change(&agent.settings)
        guard agent.settings != old else { return }
        agent.settings.save(defaults)
        if old.enabled != agent.settings.enabled {
            agent.settings.enabled ? agentStart() : agentStop()
            message = agent.settings.enabled ? "✓ agent access on · " + agent.settings.mode.rawValue + " · copy the configuration into your MCP client" : "✓ agent access off · no agent can read or change PF data"
        } else {
            // What clients may call changed: tell them to list tools again.
            agent.server?.broadcast(Data(MCP.notificationLine("notifications/tools/list_changed").utf8))
            agent.server?.broadcast(Data(MCP.notificationLine("notifications/resources/list_changed").utf8))
        }
        if !old.keepAudit, agent.settings.keepAudit { agent.audit.save() }
        if old.keepAudit, !agent.settings.keepAudit { agent.audit.clear() }
    }

    /// Kill switch: Settings, ⌘K "Disable MCP access".
    func disableAgentAccess() {
        guard agent.settings.enabled else { message = "agent access is already off"; return }
        agentUpdate { $0.enabled = false }
    }

    func enableAgentAccess() {
        agentUpdate { $0.enabled = true }
        settingsSection = "agents"
    }

    // MARK: connection

    var agentExecutablePath: String { Bundle.main.executablePath ?? "/Applications/PF Terminal.app/Contents/MacOS/PF Terminal" }

    /// The client configuration (claude_desktop_config.json, Cursor mcp.json, …).
    var agentClientConfiguration: String {
        let j: JSON = ["mcpServers": ["pf-terminal": .obj([("command", .str(agentExecutablePath)), ("args", ["--mcp"]), ("env", ["PF_MCP_TOKEN": .str(agent.credential)])])]]
        return Self.pretty(j)
    }

    static func pretty(_ j: JSON) -> String {
        guard let d = j.text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return j.text }
        return String(decoding: p, as: UTF8.self)
    }

    func copyAgentConfiguration() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentClientConfiguration, forType: .string)
        message = "✓ MCP configuration copied · it contains this Mac's agent credential · paste it into your client's MCP settings"
    }

    /// Claude Code (terminal or the desktop Code tab): one command, user scope.
    var agentClaudeCodeCommand: String {
        "claude mcp add pf-terminal --scope user -e PF_MCP_TOKEN=\(agent.credential) -- \"\(agentExecutablePath)\" --mcp"
    }

    func copyAgentClaudeCodeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentClaudeCodeCommand, forType: .string)
        message = "✓ Claude Code command copied · run it in Terminal, then start a new session · it contains this Mac's agent credential"
    }

    func regenerateAgentCredential() {
        agent.regenerateCredential()
        agentStop()
        if agent.settings.enabled { agentStart() }
        message = "✓ new agent credential · connected clients were disconnected · copy the configuration again"
    }

    func revealAgentExecutable() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agentExecutablePath)])
    }

    /// Launches PF's own relay like a client would and asks for pf_status: a harmless health request.
    func testAgentConnection() {
        guard agent.settings.enabled, agent.listening else { message = "✗ turn agent access on first"; return }
        let exe = agentExecutablePath, token = agent.credential
        message = "testing the MCP connection…"
        Task.detached {
            let r = AppStore.runRelayProbe(exe, token: token)
            await MainActor.run { [weak self] in self?.message = r }
        }
    }

    nonisolated static func runRelayProbe(_ exe: String, token: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--mcp"]
        var env = ProcessInfo.processInfo.environment
        env["PF_MCP_TOKEN"] = token
        env["PF_MCP_CLIENT"] = "PF connection test"
        p.environment = env
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "✗ connection test: could not start the relay" }
        let reqs = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"PF connection test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pf_status","arguments":{}}}"#,
        ]
        inp.fileHandleForWriting.write(Data((reqs.joined(separator: "\n") + "\n").utf8))
        var buf = Data()
        let deadline = Date().addingTimeInterval(5)
        var status: JSON?
        while Date() < deadline, status == nil {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
            for l in AgentTransport.takeLines(&buf) ?? [] {
                if let j = try? JSON.parse(l), j["id"]?.double == 2 { status = j }
            }
        }
        try? inp.fileHandleForWriting.close()
        p.terminate()
        guard let status else { return "✗ connection test: no answer from PF" }
        if let e = status["error"]?["message"]?.string { return "✗ connection test: " + e }
        let st = status["result"]?["structuredContent"]
        return "✓ connection test passed · MCP API v\(Int(st?["mcp_api_version"]?.double ?? 0)) · " + (st?["access_mode"]?.string?.replacingOccurrences(of: "_", with: " ") ?? "")
    }

    // MARK: status

    /// Status bar zone: only when something is worth seeing (a request waits, a client is connected, a recent write).
    var agentIndicator: (text: String, color: Color)? {
        guard agent.settings.enabled else { return nil }
        if !agent.pending.isEmpty { return ("⌁ confirm \(agent.pending.count)", Theme.acc) }
        if let w = agent.lastWriteAt, now.timeIntervalSince(w) < 300 { return ("⌁ agent wrote", Theme.t2) }
        if agent.connected { return ("⌁ agent", Theme.t3) }
        return nil
    }

    var agentStatusText: String {
        guard agent.settings.enabled else { return "off" }
        if agent.serverError != nil { return "error" }
        if !agent.pending.isEmpty { return "\(agent.pending.count) waiting" }
        return agent.connected ? "connected" : agent.settings.mode == .readWrite ? "read + write" : "read only"
    }

    // MARK: settings section

    private func agentRow(_ k: String, _ on: Bool, hint: String = "", _ set: @escaping (inout AgentSettings, Bool) -> Void) -> SettingRow {
        SettingRow(k: k, v: on ? "on" : "off", kind: .cycle, hint: hint) { _ in self.agentUpdate { set(&$0, !on) } }
    }

    var agentSettingsSection: SettingSection {
        let s = agent.settings
        var access: [SettingRow] = [
            SettingRow(k: "agent access", v: s.enabled ? "on" : "off", kind: .cycle, hint: "MCP · local only") { _ in self.agentUpdate { $0.enabled.toggle() } },
            SettingRow(k: "access mode", v: s.mode.rawValue, kind: s.enabled ? .cycle : .muted, hint: "writes go through PF's validation") { _ in
                self.agentUpdate { $0.mode = $0.mode == .readOnly ? .readWrite : .readOnly }
            },
            agentRow("confirm writes", s.confirmWrites, hint: "watchlist · alerts · scenarios") { $0.confirmWrites = $1 },
            SettingRow(k: "confirm ledger + deletions", v: "always", kind: .muted, hint: "can't be turned off"),
        ]
        if s.enabled { access.append(SettingRow(k: "disable agent access", v: "now", kind: .action, hint: "closes every connection") { _ in self.disableAgentAccess() }) }
        let exposure: [SettingRow] = [
            agentRow("exact values", s.exposeValues, hint: "values · amounts · P&L $ · entries") { $0.exposeValues = $1 },
            agentRow("notes", s.exposeNotes) { $0.exposeNotes = $1 },
            agentRow("transaction history", s.exposeTransactions) { $0.exposeTransactions = $1 },
            agentRow("watchlist", s.exposeWatchlist) { $0.exposeWatchlist = $1 },
            agentRow("alerts", s.exposeAlerts) { $0.exposeAlerts = $1 },
            agentRow("scenarios", s.exposeScenarios) { $0.exposeScenarios = $1 },
            SettingRow(k: "always shared", v: "percentages · weights · prices", kind: .muted),
        ]
        let sessions = agent.sessions.values.sorted { $0.connectedAt < $1.connectedAt }
        let connection: [SettingRow] = [
            SettingRow(k: "status", v: !s.enabled ? "off · nothing listening" : agent.serverError.map { "✗ " + $0 }
                       ?? (sessions.isEmpty ? "ready · no client connected" : sessions.map { $0.client }.joined(separator: ", ")),
                       kind: !s.enabled ? .info : agent.serverError != nil ? .bad : sessions.isEmpty ? .info : .ok),
            SettingRow(k: "transport", v: "stdio relay · unix socket in PF's container · no network port", kind: .muted),
            SettingRow(k: "last connected", v: agent.lastConnected.map { "\($0.client) · " + DateFmt.ymd($0.at) + " " + DateFmt.hms($0.at) } ?? "never", kind: .info),
            SettingRow(k: "configuration", v: "copy json", kind: .action, hint: "Claude Desktop · Cursor · others") { _ in self.copyAgentConfiguration() },
            SettingRow(k: "claude code", v: "copy command", kind: .action, hint: "terminal + desktop Code tab") { _ in self.copyAgentClaudeCodeCommand() },
            SettingRow(k: "executable", v: "reveal in Finder", kind: .action, hint: "args: --mcp") { _ in self.revealAgentExecutable() },
            SettingRow(k: "test connection", v: "run", kind: s.enabled ? .action : .muted, hint: "asks pf_status") { _ in self.testAgentConnection() },
            SettingRow(k: "credential", v: "regenerate", kind: .action, hint: "disconnects every client") { _ in self.regenerateAgentCredential() },
        ]
        let recent = agent.audit.entries.suffix(4).reversed().map { e in
            SettingRow(k: DateFmt.hms(e.at) + " " + e.tool.replacingOccurrences(of: "pf_", with: ""), v: e.result + (e.error.map { " · " + $0 } ?? ""),
                       kind: e.result == "error" || e.result == "denied" ? .bad : .info)
        }
        let audit: [SettingRow] = Array(recent) + [
            SettingRow(k: "activity", v: "open · \(agent.audit.entries.count)", kind: .action, hint: "⌘K agent activity") { _ in self.agentActivityOpen = true },
            agentRow("keep log on disk", s.keepAudit, hint: "off: this session only") { $0.keepAudit = $1 },
            SettingRow(k: "clear log", v: "clear", kind: .action) { _ in self.agent.audit.clear(); self.message = "✓ agent activity cleared" },
            SettingRow(k: "log never holds", v: "notes · amounts · credentials", kind: .muted),
        ]
        let connect: [SettingRow] = [
            SettingRow(k: "claude desktop (chat)", v: "Settings → Developer → Edit Config", kind: .muted),
            SettingRow(k: "  then", v: "paste the \"pf-terminal\" entry inside \"mcpServers\" · ⌘Q · reopen", kind: .muted),
            SettingRow(k: "claude code · code tab", v: "run the copied command · start a new session", kind: .muted),
            SettingRow(k: "cursor", v: "~/.cursor/mcp.json · same json", kind: .muted),
            SettingRow(k: "PF must be running", v: "the menu bar item is enough", kind: .muted),
            SettingRow(k: "guide", v: "open", kind: .action, hint: "docs/AGENTS.md") { _ in
                NSWorkspace.shared.open(URL(string: "https://github.com/troshkinpavel/pf/blob/main/docs/AGENTS.md")!)
            },
        ]
        let about: [SettingRow] = [
            SettingRow(k: "PF itself", v: "no server · no account · nothing uploaded", kind: .muted),
            SettingRow(k: "your agent", v: "a cloud agent's provider processes what you expose", kind: .muted),
            SettingRow(k: "while locked", v: "agents get app_locked · no data", kind: .muted),
        ]
        return SettingSection(id: "agents", title: "agents + mcp", status: agentStatusText,
                              statusColor: !s.enabled ? Theme.t3 : agent.serverError != nil ? Theme.neg : agent.pending.isEmpty ? (agent.connected ? Theme.pos : Theme.t2) : Theme.acc,
                              sub: s.enabled ? "local MCP access for AI agents · " + s.mode.rawValue : "off · no agent can read or change PF data", groups: [
            SettingGroup(h: "AGENT ACCESS", rows: access),
            SettingGroup(h: "EXPOSED DATA", rows: exposure),
            SettingGroup(h: "CONNECTION", rows: connection),
            SettingGroup(h: "CONNECT A CLIENT", rows: connect),
            SettingGroup(h: "ACTIVITY", rows: audit),
            SettingGroup(h: "WHERE DATA GOES", rows: about),
        ])
    }

    // MARK: palette

    var agentPaletteItems: [(PaletteItem, String)] {
        [
            (PaletteItem(label: "Open Agents & MCP", hint: "settings", run: { [weak self] in self?.palette = nil; self?.go(.settings); self?.selectSettingsSection("agents") }), "agent mcp ai claude cursor chatgpt"),
            (PaletteItem(label: agent.settings.enabled ? "Disable MCP access" : "Enable Agent Access", detail: agent.settings.enabled ? "kill switch · closes every connection" : "local MCP · read only by default",
                         run: { [weak self] in guard let self else { return }; self.palette = nil; self.agent.settings.enabled ? self.disableAgentAccess() : self.enableAgentAccess() }), "agent mcp disable enable kill switch access"),
            (PaletteItem(label: "Copy MCP configuration", detail: "for Claude, Cursor, …", run: { [weak self] in self?.palette = nil; self?.copyAgentConfiguration() }), "agent mcp config json claude cursor"),
            (PaletteItem(label: "Open agent activity", detail: "\(agent.audit.entries.count) entries", run: { [weak self] in self?.palette = nil; self?.agentActivityOpen = true }), "agent mcp audit log activity"),
        ]
    }
}
