import Foundation

// The only data the widget extension ever sees. Written by the app (which owns market data and
// all portfolio calculations), read by the widget. Foundation-only so an iOS target can reuse it.
// Never contains transactions, quantities, cost basis, addresses or keys.

/// What the snapshot may contain. `percentageOnly` strips every currency amount at build time.
enum WidgetPrivacyMode: String, Codable, CaseIterable, Sendable {
    case full, percentageOnly
}

struct WidgetMover: Codable, Hashable, Identifiable, Sendable {
    let id: String               // canonical AssetID (e.g. "cg:bitcoin"), used for deep links
    let symbol: String
    let changePercent: Double    // 24h price change
    let impact: Decimal?         // 24h $ contribution to the portfolio; nil in percentageOnly
}

struct WidgetPosition: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let symbol: String
    let value: Decimal?          // nil in percentageOnly
    let allocation: Double?      // % of portfolio
    let change24h: Double?
    let returnPercent: Double?   // unrealized, on cost basis
}

struct WidgetPerformancePoint: Codable, Hashable, Sendable {
    let timestamp: Date
    let normalizedValue: Double  // 0…1 within the period: shape only, never size
}

struct WidgetPortfolioSnapshot: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schemaVersion = currentSchema
    var generatedAt: Date
    var quotesAsOf: Date?            // oldest quote among held assets
    var refreshInterval: TimeInterval
    var isStale: Bool                // the app's own freshness said stale/offline/partial when written
    var hasPortfolio: Bool

    var portfolioValue: Decimal?
    var dailyChangeValue: Decimal?
    var dailyChangePercent: Double?
    var unrealizedPnL: Decimal?
    var unrealizedPnLPercent: Double?

    var gainers: [WidgetMover]       // by 24h % change
    var impact: [WidgetMover]        // by |24h $ contribution|
    var positions: [WidgetPosition]  // by value
    var performance: [WidgetPerformancePoint]
    var performanceRange: String     // e.g. "24H"
    var performanceChangePercent: Double?

    var privacyMode: WidgetPrivacyMode
    var currencyCode: String
    var numberStyle: NumberStyle

    /// Which portfolio context this snapshot describes (stable id, not the mutable name).
    var contextID: String = "all"
    var contextName: String = "PORTFOLIO"
    var contextGlyph: String = "Σ"

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, quotesAsOf, refreshInterval, isStale, hasPortfolio, portfolioValue, dailyChangeValue,
             dailyChangePercent, unrealizedPnL, unrealizedPnLPercent, gainers, impact, positions, performance, performanceRange,
             performanceChangePercent, privacyMode, currencyCode, numberStyle, contextID, contextName, contextGlyph
    }

    var fmt: Fmt { Fmt(style: numberStyle, currency: currencyCode) }
    /// Short label for widget headers: "MAIN", "LONG TERM", "ALL".
    var contextLabel: String { contextID == "all" ? "ALL" : contextName }
    var best24: WidgetMover? { gainers.first }
}

extension WidgetPortfolioSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        quotesAsOf = try c.decodeIfPresent(Date.self, forKey: .quotesAsOf)
        refreshInterval = try c.decode(TimeInterval.self, forKey: .refreshInterval)
        isStale = try c.decode(Bool.self, forKey: .isStale)
        hasPortfolio = try c.decode(Bool.self, forKey: .hasPortfolio)
        portfolioValue = try c.decodeIfPresent(Decimal.self, forKey: .portfolioValue)
        dailyChangeValue = try c.decodeIfPresent(Decimal.self, forKey: .dailyChangeValue)
        dailyChangePercent = try c.decodeIfPresent(Double.self, forKey: .dailyChangePercent)
        unrealizedPnL = try c.decodeIfPresent(Decimal.self, forKey: .unrealizedPnL)
        unrealizedPnLPercent = try c.decodeIfPresent(Double.self, forKey: .unrealizedPnLPercent)
        gainers = try c.decode([WidgetMover].self, forKey: .gainers)
        impact = try c.decode([WidgetMover].self, forKey: .impact)
        positions = try c.decode([WidgetPosition].self, forKey: .positions)
        performance = try c.decode([WidgetPerformancePoint].self, forKey: .performance)
        performanceRange = try c.decode(String.self, forKey: .performanceRange)
        performanceChangePercent = try c.decodeIfPresent(Double.self, forKey: .performanceChangePercent)
        privacyMode = try c.decode(WidgetPrivacyMode.self, forKey: .privacyMode)
        currencyCode = try c.decode(String.self, forKey: .currencyCode)
        numberStyle = try c.decode(NumberStyle.self, forKey: .numberStyle)
        contextID = try c.decodeIfPresent(String.self, forKey: .contextID) ?? "all"
        contextName = try c.decodeIfPresent(String.self, forKey: .contextName) ?? "PORTFOLIO"
        contextGlyph = try c.decodeIfPresent(String.self, forKey: .contextGlyph) ?? "Σ"
    }
}

/// Freshness as the widget communicates it. Widgets are not realtime: never "LIVE".
enum WidgetFreshness: Equatable, Sendable {
    case fresh(TimeInterval)      // within the app's refresh interval (+30 s grace, the app's LIVE rule)
    case aging(TimeInterval)      // older than that but under 15 min
    case stale(TimeInterval)      // ≥ 15 min, or the app itself had stale data

    static let staleAfter: TimeInterval = 15 * 60

    static func evaluate(_ s: WidgetPortfolioSnapshot, now: Date) -> WidgetFreshness {
        let age = max(0, now.timeIntervalSince(s.quotesAsOf ?? s.generatedAt))
        if s.isStale || age >= staleAfter { return .stale(age) }
        return age <= s.refreshInterval + 30 ? .fresh(age) : .aging(age)
    }

    var age: TimeInterval { switch self { case let .fresh(a), let .aging(a), let .stale(a): a } }
    var isStale: Bool { if case .stale = self { return true }; return false }

    /// "now", "2m", "3h", "2d"
    static func ageLabel(_ a: TimeInterval) -> String { a < 60 ? "now" : DateFmt.age(a) }
}

/// A portfolio a widget can be pinned to (published by the app; archived ones are omitted).
struct WidgetPortfolioRef: Codable, Hashable, Identifiable, Sendable {
    let id: String        // PortfolioContext.storageKey: UUID string or "all"
    let name: String
    let glyph: String
}

/// Atomic JSON files in the App Group container:
///   widget-snapshot.json            active context (widgets that follow the app)
///   widget-snapshot-<context>.json  one per live portfolio and "all"
///   widget-portfolios.json          index for the widget's portfolio picker
enum WidgetSnapshotStore {
    static let widgetKind = "PFPortfolioWidget"
    static let fileName = "widget-snapshot.json"
    static let indexName = "widget-portfolios.json"

    static var containerURL: URL? {
        guard let g = appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g)
    }

    /// nil context → the file that follows the app's active context.
    static func url(for context: String?) -> URL? {
        containerURL?.appendingPathComponent(context.map { "widget-snapshot-\($0).json" } ?? fileName)
    }

    static func readIndex() -> [WidgetPortfolioRef] {
        guard let u = containerURL?.appendingPathComponent(indexName), let d = try? Data(contentsOf: u) else { return [] }
        return (try? decoder.decode([WidgetPortfolioRef].self, from: d)) ?? []
    }

    /// Set per build from `PF_APP_GROUP_RUNTIME` (Info.plist key `PFAppGroup`): `group.io.github.troskinpavel.pf`
    /// in provisioned builds, empty (no shared container) in unprovisioned ones.
    static var appGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "PFAppGroup") as? String, !g.isEmpty, !g.hasPrefix("."), !g.contains("$(") else { return nil }
        return g
    }

    static var defaultURL: URL? { url(for: nil) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // default date encoding: exact round-trip
        return e
    }()
    static let decoder = JSONDecoder()

    /// Temp file + rename: a reader sees the old or the new file, never a partial one.
    static func write(_ s: WidgetPortfolioSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(s).write(to: url, options: .atomic)
    }

    /// nil when missing, unreadable, or from a newer schema. Never throws into the widget.
    static func read(from url: URL?) -> WidgetPortfolioSnapshot? {
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? decoder.decode(WidgetPortfolioSnapshot.self, from: data),
              s.schemaVersion <= WidgetPortfolioSnapshot.currentSchema else { return nil }
        return s
    }
}

/// `pfterminal://portfolio`, `pfterminal://asset/<canonical id or symbol>`.
enum PFLink {
    static let scheme = "pfterminal"

    enum Route: Equatable { case portfolio, movers, asset(String) }

    static var portfolio: URL { URL(string: "\(scheme)://portfolio")! }
    static var movers: URL { URL(string: "\(scheme)://movers")! }
    static func asset(_ id: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "asset"; c.path = "/" + id
        return c.url ?? portfolio
    }

    static func route(_ url: URL) -> Route? {
        guard url.scheme == scheme else { return nil }
        switch url.host {
        case "portfolio": return .portfolio
        case "movers": return .movers
        case "asset":
            let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            return id.isEmpty ? .portfolio : .asset(id.removingPercentEncoding ?? id)
        default: return nil
        }
    }
}
