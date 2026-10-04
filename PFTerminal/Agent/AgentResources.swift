import PFCore
import Foundation

// MCP resources: read-only views addressed by pf:// URIs. Each URI is a tool call underneath
// (same permission checks, lock rules, redaction and audit), never a file path.

enum AgentResources {
    static let templates: [JSON] = [
        tpl("pf://portfolio/{portfolio}", "Portfolio context", "Overview of one portfolio (name, id or all)"),
        tpl("pf://portfolio/{portfolio}/positions", "Positions", "Open positions of a portfolio"),
        tpl("pf://portfolio/{portfolio}/changes/{period}", "What changed", "Market move vs flows; period today, 7d or 30d"),
        tpl("pf://portfolio/{portfolio}/analytics", "Analytics", "Returns, TWR, drawdown, allocation"),
        tpl("pf://asset/{asset}", "Asset", "One asset by canonical id or unambiguous ticker"),
    ]

    private static func tpl(_ uri: String, _ name: String, _ d: String) -> JSON {
        .obj([("uriTemplate", .str(uri)), ("name", .str(name)), ("description", .str(d)), ("mimeType", "application/json")])
    }

    static func item(_ uri: String, _ name: String, _ d: String) -> JSON {
        .obj([("uri", .str(uri)), ("name", .str(name)), ("description", .str(d)), ("mimeType", "application/json")])
    }

    /// pf://… → (tool, arguments). nil: not a PF resource.
    static func route(_ uri: String) -> (String, JSON)? {
        guard uri.count <= 300, uri.hasPrefix("pf://"), !uri.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        let parts = uri.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
        guard !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return nil }
        switch parts.count {
        case 1:
            switch parts[0] {
            case "status": return ("pf_status", .obj([]))
            case "portfolios": return ("pf_list_portfolios", .obj([]))
            case "watchlist": return ("pf_get_watchlist", .obj([]))
            case "alerts": return ("pf_get_alerts", .obj([]))
            case "scenarios": return ("pf_get_scenarios", .obj([]))
            case "health": return ("pf_get_health", .obj([]))
            default: return nil
            }
        case 2:
            if parts[0] == "portfolio" { return ("pf_get_portfolio_context", ["portfolio": .str(parts[1])]) }
            if parts[0] == "asset" { return ("pf_get_asset", ["asset": .str(parts[1])]) }
            return nil
        case 3 where parts[0] == "portfolio":
            switch parts[2] {
            case "positions": return ("pf_get_positions", ["portfolio": .str(parts[1])])
            case "analytics": return ("pf_get_analytics", ["portfolio": .str(parts[1])])
            default: return nil
            }
        case 4 where parts[0] == "portfolio" && parts[2] == "changes":
            return ("pf_get_what_changed", ["portfolio": .str(parts[1]), "period": .str(parts[3])])
        default:
            return nil
        }
    }
}

extension AppStore {
    /// Concrete resources for what is exposed right now.
    var agentResourceList: [JSON] {
        let s = agent.settings
        var r = [AgentResources.item("pf://status", "PF status", "Version, access mode, exposure, lock state"),
                 AgentResources.item("pf://portfolios", "Portfolios", "Active portfolios"),
                 AgentResources.item("pf://health", "Health", "Prices, feeds, sync, ledger, recovery")]
        let names = ["all"] + doc.livePortfolios.map(\.name)
        for n in names {
            let e = n.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? n
            r.append(AgentResources.item("pf://portfolio/\(e)", "\(n) · context", "Portfolio overview"))
            r.append(AgentResources.item("pf://portfolio/\(e)/positions", "\(n) · positions", "Open positions"))
            r.append(AgentResources.item("pf://portfolio/\(e)/changes/today", "\(n) · what changed today", "Market move vs flows"))
            r.append(AgentResources.item("pf://portfolio/\(e)/changes/7d", "\(n) · what changed 7d", "Market move vs flows"))
            r.append(AgentResources.item("pf://portfolio/\(e)/analytics", "\(n) · analytics", "Returns, TWR, drawdown"))
        }
        if s.exposeWatchlist { r.append(AgentResources.item("pf://watchlist", "Watchlist", "Watched assets")) }
        if s.exposeAlerts { r.append(AgentResources.item("pf://alerts", "Alerts", "Alert rules and log")) }
        if s.exposeScenarios { r.append(AgentResources.item("pf://scenarios", "Scenarios", "The user's target scenarios")) }
        return r
    }

    func agentReadResource(_ uri: String, connection: Int) throws -> JSON {
        guard let (tool, args) = AgentResources.route(uri) else { throw MCPMethodError(code: -32002, message: "resource not found", data: ["uri": .str(String(uri.prefix(120)))]) }
        let r = agentCallTool(tool, args, connection: connection)
        guard let body = r["structuredContent"] else { throw MCPMethodError(code: -32603, message: "internal error") }
        if r["isError"]?.bool == true {
            throw MCPMethodError(code: -32001, message: body["error"]?["message"]?.string ?? "error", data: body["error"])
        }
        return .obj([("contents", .arr([.obj([("uri", .str(uri)), ("mimeType", "application/json"), ("text", .str(body.text))])]))])
    }
}

/// Lightweight prompt templates: PF supplies structure, the agent does the interpretation.
struct AgentPrompt {
    let name: String
    let title: String
    let description: String
    let body: (String) -> String

    var listing: JSON {
        .obj([("name", .str(name)), ("title", .str(title)), ("description", .str(description)),
              ("arguments", .arr([.obj([("name", "portfolio"), ("description", "portfolio name or all (default: the active one)"), ("required", false)])]))])
    }

    func render(_ args: JSON?) -> JSON {
        let p = String((args?["portfolio"]?.string ?? "").prefix(60)).filter { !$0.isNewline }
        let scope = p.isEmpty ? "the active portfolio" : "portfolio \"\(p)\""
        return .obj([("description", .str(description)),
                     ("messages", .arr([.obj([("role", "user"), ("content", .obj([("type", "text"), ("text", .str(body(scope)))]))])]))])
    }
}

enum AgentPrompts {
    static let all: [AgentPrompt] = [
        AgentPrompt(name: "portfolio_review", title: "Portfolio review", description: "A short review of the portfolio's state") { s in
            "Review \(s) in PF Terminal. Call pf_get_portfolio_context, then pf_get_positions. Summarise value and returns (total return and TWR), concentration, and what moved today. Separate market moves from deposits and withdrawals. Don't give financial advice; describe."
        },
        AgentPrompt(name: "weekly_portfolio_review", title: "Weekly review", description: "What changed over the last 7 days") { s in
            "Do a weekly review of \(s). Call pf_get_what_changed with period 7d and pf_get_benchmark with range 1M. Explain the market move vs money in / out, the top contributors and detractors, allocation drift, and how the time-weighted return compares with BTC and ETH."
        },
        AgentPrompt(name: "what_changed", title: "What changed today", description: "Today's move explained") { s in
            "Explain what changed in \(s) today. Call pf_get_what_changed (period today). Name the assets that drove the market move and whether any buys or sells (flows) happened."
        },
        AgentPrompt(name: "risk_review", title: "Risk review", description: "Concentration and drawdown") { s in
            "Review risk in \(s). Call pf_get_analytics and pf_get_portfolio_context. Describe concentration (largest weights), current and maximum drawdown, and positions far from their target weights if scenarios are available (pf_get_scenarios)."
        },
        AgentPrompt(name: "scenario_review", title: "Scenario review", description: "The user's own targets, projected") { s in
            "Review the user's scenarios for \(s). Call pf_get_scenarios. Compare conservative, base and bull projections, which assets contribute most of the upside, and targets that look stale against current prices. These are the user's targets, not forecasts."
        },
        AgentPrompt(name: "benchmark_review", title: "Benchmark review", description: "TWR vs BTC and ETH") { s in
            "Compare \(s) with BTC and ETH. Call pf_get_benchmark for 3M and 1Y. Report the time-weighted return against buy-and-hold BTC and ETH in percentage points, and note when history is missing."
        },
    ]
}
