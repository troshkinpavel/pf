import PFCore
import Foundation

// Agent Access permissions (docs/AGENTS.md). Enforced here, in PF, for every tool and
// resource: the agent is never trusted to "not show" something.

/// Mac-local, app-only (not in PFCore's AppSettings, not synced). Off and least-privilege by default.
struct AgentSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case readOnly = "read only", readWrite = "read + write" }

    var enabled = false
    var mode: Mode = .readOnly
    /// Watchlist / alert / scenario writes ask first. Ledger changes and deletions always ask.
    var confirmWrites = true
    var exposeValues = false
    var exposeNotes = false
    var exposeTransactions = false
    var exposeWatchlist = true
    var exposeAlerts = true
    var exposeScenarios = true
    /// Keep the activity log in agent-audit.json (off: this session only).
    var keepAudit = true

    static let key = "pf.agent.v1"

    static func load(_ d: UserDefaults) -> AgentSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(AgentSettings.self, from: data) else { return AgentSettings() }
        return s
    }
    func save(_ d: UserDefaults) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) } }

    init() {}
    /// Tolerant: missing or unknown fields fall back to the (safe) defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? d.mode
        confirmWrites = (try? c.decode(Bool.self, forKey: .confirmWrites)) ?? d.confirmWrites
        exposeValues = (try? c.decode(Bool.self, forKey: .exposeValues)) ?? d.exposeValues
        exposeNotes = (try? c.decode(Bool.self, forKey: .exposeNotes)) ?? d.exposeNotes
        exposeTransactions = (try? c.decode(Bool.self, forKey: .exposeTransactions)) ?? d.exposeTransactions
        exposeWatchlist = (try? c.decode(Bool.self, forKey: .exposeWatchlist)) ?? d.exposeWatchlist
        exposeAlerts = (try? c.decode(Bool.self, forKey: .exposeAlerts)) ?? d.exposeAlerts
        exposeScenarios = (try? c.decode(Bool.self, forKey: .exposeScenarios)) ?? d.exposeScenarios
        keepAudit = (try? c.decode(Bool.self, forKey: .keepAudit)) ?? d.keepAudit
    }
}

/// Stable, machine-readable error codes (never stack traces or paths).
enum AgentError: String, Error {
    case permissionDenied = "permission_denied"
    case readOnly = "read_only"
    case appLocked = "app_locked"
    case confirmationRequired = "confirmation_required"
    case confirmationExpired = "confirmation_expired"
    case confirmationNotFound = "confirmation_not_found"
    case assetAmbiguous = "asset_ambiguous"
    case assetNotFound = "asset_not_found"
    case portfolioNotFound = "portfolio_not_found"
    case transactionNotFound = "transaction_not_found"
    case watchNotFound = "watch_not_found"
    case alertNotFound = "alert_not_found"
    case scenarioNotFound = "scenario_not_found"
    case invalidArgument = "invalid_argument"
    case validationFailed = "validation_failed"
    case conflict
    case stalePrice = "stale_price"
    case historyUnavailable = "history_unavailable"
    case protectedDataUnavailable = "protected_data_unavailable"
    case syncDeferred = "sync_deferred"
    case rateLimited = "rate_limited"
    case unknownTool = "unknown_tool"
    case internalError = "internal_error"

    var defaultMessage: String {
        switch self {
        case .permissionDenied: "not exposed to agents in PF Terminal → Settings → agents"
        case .readOnly: "agent access is read only"
        case .appLocked: "PF Terminal is locked · unlock it to continue"
        case .confirmationRequired: "waiting for confirmation in PF Terminal"
        case .confirmationExpired: "the confirmation expired · nothing changed"
        case .confirmationNotFound: "no such confirmation"
        case .assetAmbiguous: "more than one asset matches · pass a canonical asset id"
        case .assetNotFound: "no asset matches"
        case .portfolioNotFound: "no such portfolio"
        case .transactionNotFound: "no such transaction"
        case .watchNotFound: "no such watchlist item"
        case .alertNotFound: "no such alert rule"
        case .scenarioNotFound: "no such scenario"
        case .invalidArgument: "invalid argument"
        case .validationFailed: "PF rejected the change"
        case .conflict: "the data changed since this was requested · nothing changed"
        case .stalePrice: "no current price"
        case .historyUnavailable: "price history is loading · try again in a few seconds"
        case .protectedDataUnavailable: "the Mac is locked · PF's data is unavailable until it is unlocked"
        case .syncDeferred: "waiting for iCloud"
        case .rateLimited: "too many pending requests"
        case .unknownTool: "unknown tool"
        case .internalError: "internal error"
        }
    }
}

struct AgentFailure: Error {
    let code: AgentError
    let message: String
    var data: JSON?
    init(_ code: AgentError, _ message: String? = nil, data: JSON? = nil) { self.code = code; self.message = message ?? code.defaultMessage; self.data = data }
}

/// What a tool can do: decides mode + confirmation.
enum AgentTier: String {
    /// pf_status: answers whenever access is on, even locked.
    case status
    case read
    /// Watchlist / alerts / scenarios, non-destructive: confirmed when "confirm writes" is on.
    case write
    /// Adds to the ledger: always confirmed.
    case ledger
    /// Removes or replaces data: always confirmed.
    case destructive

    var isWrite: Bool { self == .write || self == .ledger || self == .destructive }
    func needsConfirmation(_ s: AgentSettings) -> Bool {
        switch self { case .status, .read: false; case .write: s.confirmWrites; case .ledger, .destructive: true }
    }
}

/// Data classes a tool needs exposed.
enum AgentData { case transactions, watchlist, alerts, scenarios }

/// Redaction in one place: every money / quantity figure goes through `money` / `qty`.
struct AgentExposure {
    let s: AgentSettings

    func allows(_ d: AgentData) -> Bool {
        switch d {
        case .transactions: s.exposeTransactions
        case .watchlist: s.exposeWatchlist
        case .alerts: s.exposeAlerts
        case .scenarios: s.exposeScenarios
        }
    }

    /// A portfolio-specific amount (value, cost, P&L $, flows, quantity × price): omitted unless exposed.
    func money(_ d: Decimal?) -> JSON? { s.exposeValues ? .opt(d) : nil }
    func money(_ d: Double?) -> JSON? { s.exposeValues ? .opt(d) : nil }
    /// Quantities reveal value with a public price: same rule.
    func qty(_ d: Decimal?) -> JSON? { s.exposeValues ? .opt(d) : nil }
    func note(_ n: String?) -> JSON? { s.exposeNotes ? .opt(n) : nil }
    var redacted: [String] {
        var r: [String] = []
        if !s.exposeValues { r.append("values") }
        if !s.exposeNotes { r.append("notes") }
        return r
    }
}

/// Bounded local activity log (no amounts, no notes, no credential).
struct AgentAuditEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var at: Date
    /// Connection number and the client's self-reported name (informational only).
    var connection: Int
    var client: String
    var tool: String
    var tier: String
    /// Portfolio id prefix (8 chars), never the name.
    var portfolio: String?
    /// ok · error · confirmation_requested · confirmed · denied · expired · failed
    var result: String
    var error: String?
    var confirmation: String?
}

struct AgentAuditLog {
    static let limit = 500
    let url: URL?
    private(set) var entries: [AgentAuditEntry] = []

    init(directory: URL?) {
        url = directory?.appendingPathComponent("agent-audit.json")
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder.iso.decode([AgentAuditEntry].self, from: d) { entries = e }
    }

    mutating func append(_ e: AgentAuditEntry, persist: Bool) {
        entries.append(e)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        if persist { save() } else if let url { try? FileManager.default.removeItem(at: url) }
    }

    mutating func clear() {
        entries = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func save() {
        guard let url, let d = try? JSONEncoder.iso.encode(entries) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
