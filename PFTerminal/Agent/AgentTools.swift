import PFCore
import Foundation

// MCP tool catalogue (API version 1). Names use "_" : several clients reject "." in tool names.
// Schemas are strict (additionalProperties: false); AgentArgs enforces the same on input.

struct AgentTool {
    let name: String
    let title: String
    let description: String
    let tier: AgentTier
    var data: AgentData?
    var props: [(String, JSON)] = []
    var required: [String] = []
    var dryRun = false

    var argNames: Set<String> { Set(props.map(\.0) + (dryRun ? ["dry_run"] : [])) }
    var dataLabel: String {
        switch data { case .transactions?: "transaction history"; case .watchlist?: "the watchlist"; case .alerts?: "alerts"; case .scenarios?: "scenarios"; case nil: "this" }
    }

    var listing: JSON {
        var p = props
        if dryRun { p.append(("dry_run", S.bool("preview only: validates with PF's accounting and returns what would change; nothing is saved"))) }
        let schema: JSON = .obj([("type", "object"), ("properties", .obj(p)), ("required", .arr(required.map(JSON.str))), ("additionalProperties", false)])
        let annotations: JSON = .obj([
            ("title", .str(title)), ("readOnlyHint", .bool(!tier.isWrite)), ("destructiveHint", .bool(tier == .destructive)),
            ("idempotentHint", .bool(!tier.isWrite)), ("openWorldHint", false),
        ])
        return .obj([("name", .str(name)), ("title", .str(title)), ("description", .str(description)), ("inputSchema", schema), ("annotations", annotations)])
    }
}

/// JSON Schema fragments.
enum S {
    static func str(_ d: String, _ e: [String]? = nil) -> JSON {
        var o: [(String, JSON)] = [("type", "string"), ("description", .str(d))]
        if let e { o.append(("enum", .arr(e.map(JSON.str)))) }
        return .obj(o)
    }
    static func num(_ d: String, nullable: Bool = false) -> JSON {
        .obj([("type", nullable ? .arr(["number", "string", "null"]) : .arr(["number", "string"])), ("description", .str(d + " (a number, or its decimal digits as a string for exact amounts)"))])
    }
    static func int(_ d: String, min: Int, max: Int) -> JSON { .obj([("type", "integer"), ("minimum", .int(min)), ("maximum", .int(max)), ("description", .str(d))]) }
    static func bool(_ d: String) -> JSON { .obj([("type", "boolean"), ("description", .str(d))]) }
    static func nullableStr(_ d: String) -> JSON { .obj([("type", .arr(["string", "null"])), ("description", .str(d))]) }

    static let portfolio = str("portfolio name, id, or \"all\" (default: the portfolio active in PF Terminal)")
    static let asset = str("canonical asset id (e.g. cg:bitcoin, dex:base:0x…) or a ticker that matches exactly one asset")
    static let date = str("date, YYYY-MM-DD (default: today)")
}

enum AgentTools {
    static let all: [AgentTool] = [
        // status + reads
        AgentTool(name: "pf_status", title: "PF status", description: "PF Terminal version, MCP API version, access mode, what is exposed, and whether PF is locked. Always available.", tier: .status),
        AgentTool(name: "pf_list_portfolios", title: "List portfolios", description: "Active portfolios (name, id, positions, 24h %, value when exposed) and which one is active in PF.", tier: .read),
        AgentTool(name: "pf_get_portfolio_context", title: "Portfolio context", description: "Compact overview for an agent: value, total return, TWR, today's market move vs flows and top contributors, allocation, drawdown, alerts. Start here.", tier: .read,
                  props: [("portfolio", S.portfolio)]),
        AgentTool(name: "pf_get_portfolio_summary", title: "Portfolio summary", description: "Value, cost basis, unrealized / realized / total P&L, total return, 24h change, best and worst positions.", tier: .read,
                  props: [("portfolio", S.portfolio)]),
        AgentTool(name: "pf_get_positions", title: "Positions", description: "Open positions with price, 24h %, weight, unrealized return and (when exposed) quantity, value, cost and P&L.", tier: .read,
                  props: [("portfolio", S.portfolio), ("include_closed", S.bool("also list fully exited positions (realized P&L only)"))]),
        AgentTool(name: "pf_get_asset", title: "Asset", description: "One asset: market data, the position in the portfolio, portfolio impact today / 7d / 30d, target weight, watch, scenario targets and alerts.", tier: .read,
                  props: [("asset", S.asset), ("portfolio", S.portfolio)], required: ["asset"]),
        AgentTool(name: "pf_resolve_asset", title: "Resolve asset", description: "Canonical asset ids for a ticker or name: the user's own assets first, then PF's registry. Use when a ticker is ambiguous.", tier: .read,
                  props: [("query", S.str("ticker or name"))], required: ["query"]),
        AgentTool(name: "pf_get_transactions", title: "Transactions", description: "Ledger transactions, newest first.", tier: .read, data: .transactions,
                  props: [("portfolio", S.portfolio), ("asset", S.asset), ("since", S.str("only on or after this date, YYYY-MM-DD")), ("limit", S.int("maximum rows (default 50)", min: 1, max: 500))]),
        AgentTool(name: "pf_get_what_changed", title: "What changed", description: "Change over today / 7d / 30d split into market move and money in / out (excluded from performance), per-asset impact, allocation drift and a one-line summary.", tier: .read,
                  props: [("portfolio", S.portfolio), ("period", S.str("today, 7d or 30d (default today)", ["today", "7d", "30d"]))]),
        AgentTool(name: "pf_get_analytics", title: "Analytics", description: "Net contributed, cost basis, unrealized / realized / total P&L, total return, TWR (all time), max and current drawdown, best and worst positions, allocation.", tier: .read,
                  props: [("portfolio", S.portfolio)]),
        AgentTool(name: "pf_get_benchmark", title: "Benchmark", description: "Time-weighted return vs BTC and ETH buy-and-hold over a range, in percentage points.", tier: .read,
                  props: [("portfolio", S.portfolio), ("range", S.str("1M, 3M, 6M, 1Y or ALL (default 1Y)", ["1M", "3M", "6M", "1Y", "ALL"]))]),
        AgentTool(name: "pf_get_watchlist", title: "Watchlist", description: "Watched assets: price, 24h, since added, planned entry, distance to entry, target, alert state.", tier: .read, data: .watchlist),
        AgentTool(name: "pf_get_alerts", title: "Alerts", description: "Alert rules (number, condition, state, repeat, distance) and the recent log.", tier: .read, data: .alerts),
        AgentTool(name: "pf_get_scenarios", title: "Scenarios", description: "The user's scenarios (target prices and weights per asset) projected on current holdings. The user's targets, not forecasts.", tier: .read, data: .scenarios),
        AgentTool(name: "pf_get_health", title: "Health", description: "Price freshness, live feeds, iCloud sync, ledger and recovery-snapshot status.", tier: .read),
        AgentTool(name: "pf_get_confirmation", title: "Confirmation outcome", description: "Outcome of a request that needed the user's confirmation: pending, confirmed (with the result), denied, expired or failed.", tier: .read,
                  props: [("confirmation_id", S.str("id returned with confirmation_required"))], required: ["confirmation_id"]),

        // ledger writes
        AgentTool(name: "pf_add_transaction", title: "Add transaction", description: "Records a buy, sell or transfer the user made elsewhere in their PF ledger (bookkeeping only: PF never places orders or moves funds; \"buy 10 SOL\" means record it). Validated by PF (oversold, dates, canonical asset). Always needs the user's confirmation in PF; use dry_run to preview.", tier: .ledger,
                  props: [("portfolio", S.portfolio), ("type", S.str("transaction type", ["buy", "sell", "transfer_in", "transfer_out"])), ("asset", S.asset),
                          ("amount", S.num("quantity of the asset, > 0")), ("price", S.num("price per unit in the ledger currency; omit for today's market price (buy / sell today only)")),
                          ("date", S.date), ("fee", S.num("fee in the ledger currency, ≥ 0")), ("note", S.str("note (≤ 500 characters)"))],
                  required: ["type", "asset", "amount"], dryRun: true),
        AgentTool(name: "pf_update_transaction", title: "Update transaction", description: "Changes an existing transaction (same id). Replaces history: always confirmed in PF.", tier: .destructive,
                  props: [("transaction_id", S.str("transaction id from pf_get_transactions")), ("type", S.str("transaction type", ["buy", "sell", "transfer_in", "transfer_out"])),
                          ("amount", S.num("quantity, > 0")), ("price", S.num("price per unit")), ("date", S.date), ("fee", S.num("fee, ≥ 0")), ("note", S.nullableStr("note; null clears it"))],
                  required: ["transaction_id"], dryRun: true),
        AgentTool(name: "pf_delete_transaction", title: "Delete transaction", description: "Deletes one transaction (refused when a later transaction depends on it). Always confirmed in PF; a recovery snapshot is taken first.", tier: .destructive,
                  props: [("transaction_id", S.str("transaction id from pf_get_transactions"))], required: ["transaction_id"], dryRun: true),
        AgentTool(name: "pf_convert_watch_to_position", title: "Convert watch to position", description: "Buys a watched asset: records the transaction, archives the watch item and carries its target, note and alert over. Always confirmed in PF.", tier: .ledger, data: .watchlist,
                  props: [("asset", S.asset), ("portfolio", S.portfolio), ("amount", S.num("quantity bought, > 0")), ("price", S.num("price per unit; omit for today's market price")),
                          ("date", S.date), ("fee", S.num("fee, ≥ 0")), ("carry_target", S.bool("keep the watch target (default true)")),
                          ("carry_note", S.bool("keep the note (default true)")), ("carry_alert", S.bool("arm a target alert (default true)"))],
                  required: ["asset", "amount"], dryRun: true),

        // watchlist
        AgentTool(name: "pf_add_watch", title: "Watch asset", description: "Adds an asset to the watchlist (or updates the active item for it).", tier: .write, data: .watchlist,
                  props: [("asset", S.asset), ("entry", S.num("planned entry price")), ("target", S.num("target price")), ("note", S.str("note"))], required: ["asset"]),
        AgentTool(name: "pf_update_watch", title: "Update watch", description: "Changes entry, target or note of a watched asset; null clears a field.", tier: .write, data: .watchlist,
                  props: [("asset", S.asset), ("entry", S.num("planned entry price", nullable: true)), ("target", S.num("target price", nullable: true)), ("note", S.nullableStr("note"))], required: ["asset"]),
        AgentTool(name: "pf_remove_watch", title: "Remove watch", description: "Removes a watched asset from the watchlist. Always confirmed in PF.", tier: .destructive, data: .watchlist,
                  props: [("asset", S.asset)], required: ["asset"]),

        // alerts
        AgentTool(name: "pf_create_alert", title: "Create alert", description: "Creates an alert rule from PF's alert grammar. Examples: \"sol above 160\", \"btc below 80000\", \"eth pnl below -20\", \"sol weight 35\", \"main value above 100000\", \"any move 10\", \"any depeg 0.5\", \"main drawdown 20\", \"sol target\". dry_run returns a 30-day backtest.", tier: .write, data: .alerts,
                  props: [("condition", S.str("rule in PF's alert grammar (see description)")), ("repeat", S.str("once (default), cross (every crossing) or daily", ["once", "cross", "daily"])), ("note", S.str("note"))],
                  required: ["condition"], dryRun: true),
        AgentTool(name: "pf_update_alert", title: "Update alert", description: "Changes an alert rule's condition, repeat mode or note.", tier: .write, data: .alerts,
                  props: [("alert", S.int("rule number (#n)", min: 1, max: 100_000)), ("condition", S.str("new condition in PF's alert grammar")),
                          ("repeat", S.str("once, cross or daily", ["once", "cross", "daily"])), ("note", S.nullableStr("note; null clears it"))],
                  required: ["alert"], dryRun: true),
        AgentTool(name: "pf_pause_alert", title: "Pause alert", description: "Pauses or resumes an alert rule.", tier: .write, data: .alerts,
                  props: [("alert", S.int("rule number (#n)", min: 1, max: 100_000)), ("paused", S.bool("true pauses, false resumes"))], required: ["alert", "paused"]),
        AgentTool(name: "pf_rearm_alert", title: "Re-arm alert", description: "Re-arms a fired alert rule.", tier: .write, data: .alerts,
                  props: [("alert", S.int("rule number (#n)", min: 1, max: 100_000))], required: ["alert"]),
        AgentTool(name: "pf_delete_alert", title: "Delete alert", description: "Deletes an alert rule. Always confirmed in PF.", tier: .destructive, data: .alerts,
                  props: [("alert", S.int("rule number (#n)", min: 1, max: 100_000))], required: ["alert"]),

        // scenarios
        AgentTool(name: "pf_create_scenario", title: "Create scenario", description: "Creates a named scenario, optionally with target prices / weights.", tier: .write, data: .scenarios,
                  props: [("name", S.str("scenario name (unique)")), ("targets", targetsSchema)], required: ["name"]),
        AgentTool(name: "pf_update_scenario", title: "Update scenario", description: "Renames a scenario and / or sets target prices and weights (null clears a weight).", tier: .write, data: .scenarios,
                  props: [("scenario", S.str("scenario name, key (c, b, u) or id")), ("name", S.str("new name")), ("targets", targetsSchema)], required: ["scenario"]),
        AgentTool(name: "pf_duplicate_scenario", title: "Duplicate scenario", description: "Copies a scenario with its targets.", tier: .write, data: .scenarios,
                  props: [("scenario", S.str("scenario name, key (c, b, u) or id"))], required: ["scenario"]),
        AgentTool(name: "pf_delete_scenario", title: "Delete scenario", description: "Deletes a scenario and its targets. Always confirmed in PF.", tier: .destructive, data: .scenarios,
                  props: [("scenario", S.str("scenario name, key (c, b, u) or id"))], required: ["scenario"]),
    ]

    static let targetsSchema: JSON = .obj([
        ("type", "array"), ("maxItems", .int(100)), ("description", "per-asset targets"),
        ("items", .obj([("type", "object"), ("additionalProperties", false), ("required", ["asset"]), ("properties", .obj([
            ("asset", S.asset), ("price", S.num("target price, > 0")), ("weight", S.num("target weight in %, 0–100; null clears", nullable: true)),
        ]))])),
    ])

    static let byName: [String: AgentTool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    // MARK: results

    static func okResult(_ j: JSON) -> JSON {
        .obj([("content", .arr([.obj([("type", "text"), ("text", .str(j.text))])])), ("structuredContent", j), ("isError", false)])
    }

    static func errorResult(_ f: AgentFailure) -> JSON {
        var e: [(String, JSON)] = [("code", .str(f.code.rawValue)), ("message", .str(f.message))]
        if let d = f.data { e.append(("details", d)) }
        let j: JSON = .obj([("error", .obj(e))])
        return .obj([("content", .arr([.obj([("type", "text"), ("text", .str(j.text))])])), ("structuredContent", j), ("isError", true)])
    }
}

extension AppStore {
    /// Tools the client sees: write tools only in read + write, data tools only when exposed.
    var agentVisibleTools: [AgentTool] {
        let s = agent.settings, ex = AgentExposure(s: s)
        return AgentTools.all.filter { t in (!t.tier.isWrite || s.mode == .readWrite) && (t.data.map(ex.allows) ?? true) }
    }
}

/// A frozen, validated change: what the user confirms is exactly what runs.
struct AgentOperation {
    var title: String
    /// Full detail for the user in PF (their own data).
    var userLines: [String]
    /// The same, redacted by the exposure settings, for the agent.
    var agentLines: [String]
    var portfolio: UUID?
    /// dry_run answer.
    var preview: JSON
    let run: @MainActor () throws -> JSON
}

enum AgentOutcome {
    case result(JSON, portfolio: String?)
    case confirm(AgentOperation)
}

/// Typed, validated tool arguments. Unknown keys are rejected.
struct AgentArgs {
    let raw: [(String, JSON)]

    init(_ j: JSON, allowed: Set<String>) throws {
        raw = j.object ?? []
        if let bad = raw.first(where: { !allowed.contains($0.0) }) { throw AgentFailure(.invalidArgument, "unknown argument: \(bad.0.prefix(40))") }
    }

    func has(_ k: String) -> Bool { raw.contains { $0.0 == k } }
    func value(_ k: String) -> JSON? { raw.first { $0.0 == k }?.1 }
    func isNull(_ k: String) -> Bool { value(k)?.isNull == true }

    func string(_ k: String, required: Bool = false, max: Int = 200) throws -> String? {
        guard let v = value(k), !v.isNull else { if required { throw AgentFailure(.invalidArgument, "\(k) is required") }; return nil }
        guard let s = v.string else { throw AgentFailure(.invalidArgument, "\(k) must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && t.isEmpty { throw AgentFailure(.invalidArgument, "\(k) is required") }
        guard t.count <= max else { throw AgentFailure(.invalidArgument, "\(k) is longer than \(max) characters") }
        guard !t.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" }) else { throw AgentFailure(.invalidArgument, "\(k) contains control characters") }
        return t
    }

    func bool(_ k: String) -> Bool? { value(k)?.bool }
    func boolStrict(_ k: String, required: Bool = false) throws -> Bool? {
        guard let v = value(k), !v.isNull else { if required { throw AgentFailure(.invalidArgument, "\(k) is required") }; return nil }
        guard let b = v.bool else { throw AgentFailure(.invalidArgument, "\(k) must be true or false") }
        return b
    }

    func int(_ k: String, required: Bool = false, range: ClosedRange<Int>) throws -> Int? {
        guard let v = value(k), !v.isNull else { if required { throw AgentFailure(.invalidArgument, "\(k) is required") }; return nil }
        guard let d = v.double, d == d.rounded(), let i = Int(exactly: d), range.contains(i) else { throw AgentFailure(.invalidArgument, "\(k) must be an integer in \(range.lowerBound)…\(range.upperBound)") }
        return i
    }

    /// An exact decimal: a JSON number or a plain decimal string ("0.42"). No NaN, no infinity,
    /// no exponent strings, no thousands separators (ambiguous across locales).
    func decimal(_ k: String, required: Bool = false, positive: Bool = false, nonNegative: Bool = false) throws -> Decimal? {
        guard let v = value(k), !v.isNull else { if required { throw AgentFailure(.invalidArgument, "\(k) is required") }; return nil }
        let d: Decimal?
        switch v {
        case let .dec(x): d = x
        case let .num(x): d = x.isFinite ? Decimal(string: String(x), locale: Locale(identifier: "en_US_POSIX")) : nil
        case let .str(s):
            let t = s.trimmingCharacters(in: .whitespaces)
            d = t.range(of: #"^-?\d{1,20}(\.\d{1,18})?$"#, options: .regularExpression) != nil ? Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) : nil
        default: d = nil
        }
        guard let d, !d.isNaN else { throw AgentFailure(.invalidArgument, "\(k) must be a decimal number") }
        if positive && d <= 0 { throw AgentFailure(.invalidArgument, "\(k) must be greater than 0") }
        if nonNegative && d < 0 { throw AgentFailure(.invalidArgument, "\(k) must not be negative") }
        guard abs(d) < Decimal(string: "1e18")! else { throw AgentFailure(.invalidArgument, "\(k) is out of range") }
        return d
    }

    /// YYYY-MM-DD, a real calendar date, not in the future.
    func date(_ k: String) throws -> String? {
        guard let s = try string(k, max: 10) else { return nil }
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let d = DateFmt.parseYMD(s), DateFmt.ymd(d) == s else {
            throw AgentFailure(.invalidArgument, "\(k) must be a date as YYYY-MM-DD")
        }
        guard d < Date().addingTimeInterval(86400) else { throw AgentFailure(.invalidArgument, "\(k) is in the future") }
        guard d > DateFmt.parseYMD("2009-01-01")! else { throw AgentFailure(.invalidArgument, "\(k) is before 2009") }
        return s
    }

    func choice(_ k: String, _ options: [String], default def: String? = nil) throws -> String? {
        guard let s = try string(k, max: 40) else { return def }
        guard options.contains(s) else { throw AgentFailure(.invalidArgument, "\(k) must be one of: " + options.joined(separator: ", ")) }
        return s
    }
}
