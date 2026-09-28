import Foundation

// The only data the widget extension ever sees. Written by the app (which owns market data and
// all portfolio calculations), read by the widget. Foundation-only so an iOS target can reuse it.
// Never contains transactions, quantities, cost basis, addresses or keys.

/// What the snapshot may contain. `percentageOnly` strips every currency amount at build time.
public enum WidgetPrivacyMode: String, Codable, CaseIterable, Sendable {
    case full, percentageOnly
}

public struct WidgetMover: Codable, Hashable, Identifiable, Sendable {
    public init(id: String, symbol: String, changePercent: Double, impact: Decimal? = nil) { self.id = id; self.symbol = symbol; self.changePercent = changePercent; self.impact = impact }
    public let id: String               // canonical AssetID (e.g. "cg:bitcoin"), used for deep links
    public let symbol: String
    public let changePercent: Double    // 24h price change
    public let impact: Decimal?         // 24h $ contribution to the portfolio; nil in percentageOnly
}

public struct WidgetPosition: Codable, Hashable, Identifiable, Sendable {
    public init(id: String, symbol: String, value: Decimal? = nil, allocation: Double? = nil, change24h: Double? = nil, returnPercent: Double? = nil) { self.id = id; self.symbol = symbol; self.value = value; self.allocation = allocation; self.change24h = change24h; self.returnPercent = returnPercent }
    public let id: String
    public let symbol: String
    public let value: Decimal?          // nil in percentageOnly
    public let allocation: Double?      // % of portfolio
    public let change24h: Double?
    public let returnPercent: Double?   // unrealized, on cost basis
}

public struct WidgetPerformancePoint: Codable, Hashable, Sendable {
    public init(timestamp: Date, normalizedValue: Double) { self.timestamp = timestamp; self.normalizedValue = normalizedValue }
    public let timestamp: Date
    public let normalizedValue: Double  // 0…1 within the period: shape only, never size
}

public struct WidgetPortfolioSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion = currentSchema

    public init(schemaVersion: Int = WidgetPortfolioSnapshot.currentSchema, generatedAt: Date, quotesAsOf: Date? = nil, refreshInterval: TimeInterval,
                isStale: Bool, hasPortfolio: Bool, portfolioValue: Decimal? = nil, dailyChangeValue: Decimal? = nil,
                dailyChangePercent: Double? = nil, unrealizedPnL: Decimal? = nil, unrealizedPnLPercent: Double? = nil,
                gainers: [WidgetMover], impact: [WidgetMover], positions: [WidgetPosition], performance: [WidgetPerformancePoint],
                performanceRange: String, performanceChangePercent: Double? = nil, privacyMode: WidgetPrivacyMode, currencyCode: String,
                numberStyle: NumberStyle, contextID: String = "all", contextName: String = "PORTFOLIO", contextGlyph: String = "Σ",
                homeScreenValues: Bool = true, lockScreenValues: Bool = false) {
        self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.quotesAsOf = quotesAsOf; self.refreshInterval = refreshInterval
        self.isStale = isStale; self.hasPortfolio = hasPortfolio; self.portfolioValue = portfolioValue; self.dailyChangeValue = dailyChangeValue
        self.dailyChangePercent = dailyChangePercent; self.unrealizedPnL = unrealizedPnL; self.unrealizedPnLPercent = unrealizedPnLPercent
        self.gainers = gainers; self.impact = impact; self.positions = positions; self.performance = performance
        self.performanceRange = performanceRange; self.performanceChangePercent = performanceChangePercent; self.privacyMode = privacyMode
        self.currencyCode = currencyCode; self.numberStyle = numberStyle; self.contextID = contextID; self.contextName = contextName
        self.contextGlyph = contextGlyph; self.homeScreenValues = homeScreenValues; self.lockScreenValues = lockScreenValues
    }

    public var generatedAt: Date
    public var quotesAsOf: Date?            // oldest quote among held assets
    public var refreshInterval: TimeInterval
    public var isStale: Bool                // the app's own freshness said stale/offline/partial when written
    public var hasPortfolio: Bool

    public var portfolioValue: Decimal?
    public var dailyChangeValue: Decimal?
    public var dailyChangePercent: Double?
    public var unrealizedPnL: Decimal?
    public var unrealizedPnLPercent: Double?

    public var gainers: [WidgetMover]       // by 24h % change
    public var impact: [WidgetMover]        // by |24h $ contribution|
    public var positions: [WidgetPosition]  // by value
    public var performance: [WidgetPerformancePoint]
    public var performanceRange: String     // e.g. "24H"
    public var performanceChangePercent: Double?

    public var privacyMode: WidgetPrivacyMode
    public var currencyCode: String
    public var numberStyle: NumberStyle

    /// Which portfolio context this snapshot describes (stable id, not the mutable name).
    public var contextID: String = "all"
    public var contextName: String = "PORTFOLIO"
    public var contextGlyph: String = "Σ"

    /// Per-surface permission for currency amounts (iOS privacy settings). Amounts exist in the
    /// snapshot only when `privacyMode == .full`; these flags narrow where they may be shown.
    /// Defaults keep the macOS behavior: home widgets follow `privacyMode`, Lock Screen never.
    public var homeScreenValues: Bool = true
    public var lockScreenValues: Bool = false

    public enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, quotesAsOf, refreshInterval, isStale, hasPortfolio, portfolioValue, dailyChangeValue,
             dailyChangePercent, unrealizedPnL, unrealizedPnLPercent, gainers, impact, positions, performance, performanceRange,
             performanceChangePercent, privacyMode, currencyCode, numberStyle, contextID, contextName, contextGlyph,
             homeScreenValues, lockScreenValues
    }

    /// Amounts may be drawn on this surface.
    public var showsValuesOnHomeScreen: Bool { privacyMode == .full && homeScreenValues }
    public var showsValuesOnLockScreen: Bool { privacyMode == .full && lockScreenValues }

    public var fmt: Fmt { Fmt(style: numberStyle, currency: currencyCode) }
    /// Short label for widget headers: "MAIN", "LONG TERM", "ALL".
    public var contextLabel: String { contextID == "all" ? "ALL" : contextName }
    public var best24: WidgetMover? { gainers.first }
}

extension WidgetPortfolioSnapshot {
    public init(from decoder: Decoder) throws {
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
        homeScreenValues = try c.decodeIfPresent(Bool.self, forKey: .homeScreenValues) ?? true
        lockScreenValues = try c.decodeIfPresent(Bool.self, forKey: .lockScreenValues) ?? false
    }
}

/// Freshness as the widget communicates it. Widgets are not realtime: never "LIVE".
public enum WidgetFreshness: Equatable, Sendable {
    case fresh(TimeInterval)      // within the app's refresh interval (+30 s grace, the app's LIVE rule)
    case aging(TimeInterval)      // older than that but under 15 min
    case stale(TimeInterval)      // ≥ 15 min, or the app itself had stale data

    public static let staleAfter: TimeInterval = 15 * 60

    public static func evaluate(_ s: WidgetPortfolioSnapshot, now: Date) -> WidgetFreshness {
        let age = max(0, now.timeIntervalSince(s.quotesAsOf ?? s.generatedAt))
        if s.isStale || age >= staleAfter { return .stale(age) }
        return age <= s.refreshInterval + 30 ? .fresh(age) : .aging(age)
    }

    public var age: TimeInterval { switch self { case let .fresh(a), let .aging(a), let .stale(a): a } }
    public var isStale: Bool { if case .stale = self { return true }; return false }

    /// "now", "2m", "3h", "2d"
    public static func ageLabel(_ a: TimeInterval) -> String { a < 60 ? "now" : DateFmt.age(a) }
}

/// A portfolio a widget can be pinned to (published by the app; archived ones are omitted).
public struct WidgetPortfolioRef: Codable, Hashable, Identifiable, Sendable {
    public init(id: String, name: String, glyph: String) { self.id = id; self.name = name; self.glyph = glyph }
    public let id: String        // PortfolioContext.storageKey: UUID string or "all"
    public let name: String
    public let glyph: String
}

/// Atomic JSON files in the App Group container:
///   widget-snapshot.json            active context (widgets that follow the app)
///   widget-snapshot-<context>.json  one per live portfolio and "all"
///   widget-portfolios.json          index for the widget's portfolio picker
public enum WidgetSnapshotStore {
    public static let widgetKind = "PFPortfolioWidget"
    public static let fileName = "widget-snapshot.json"
    public static let indexName = "widget-portfolios.json"

    public static var containerURL: URL? {
        guard let g = appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g)
    }

    /// nil context → the file that follows the app's active context.
    public static func url(for context: String?) -> URL? {
        containerURL?.appendingPathComponent(context.map { "widget-snapshot-\($0).json" } ?? fileName)
    }

    public static func readIndex() -> [WidgetPortfolioRef] {
        guard let u = containerURL?.appendingPathComponent(indexName), let d = try? Data(contentsOf: u) else { return [] }
        return (try? decoder.decode([WidgetPortfolioRef].self, from: d)) ?? []
    }

    /// Set per build from `PF_APP_GROUP_RUNTIME` (Info.plist key `PFAppGroup`): `group.io.github.troskinpavel.pf`
    /// in provisioned builds, empty (no shared container) in unprovisioned ones.
    public static var appGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "PFAppGroup") as? String, !g.isEmpty, !g.hasPrefix("."), !g.contains("$(") else { return nil }
        return g
    }

    public static var defaultURL: URL? { url(for: nil) }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // default date encoding: exact round-trip
        return e
    }()
    public static let decoder = JSONDecoder()

    /// Temp file + rename: a reader sees the old or the new file, never a partial one.
    public static func write(_ s: WidgetPortfolioSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(s).write(to: url, options: .atomic)
    }

    /// nil when missing, unreadable, or from a newer schema. Never throws into the widget.
    /// Writes one snapshot per context (plus the one that follows the active context) and the
    /// picker index, removes files of contexts that no longer exist, then the caller reloads
    /// timelines. Every file is written atomically.
    public static func publish(active: WidgetPortfolioSnapshot, contexts: [String: WidgetPortfolioSnapshot],
                        index: [WidgetPortfolioRef], to dir: URL) throws {
        try write(active, to: dir.appendingPathComponent(fileName))
        for (k, snap) in contexts { try write(snap, to: dir.appendingPathComponent("widget-snapshot-\(k).json")) }
        try encoder.encode(index).write(to: dir.appendingPathComponent(indexName), options: .atomic)
        // Archived / deleted portfolios must not keep feeding widgets.
        let keep = Set(contexts.keys.map { "widget-snapshot-\($0).json" })
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where f.hasPrefix("widget-snapshot-") && !keep.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    public static func read(from url: URL?) -> WidgetPortfolioSnapshot? {
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? decoder.decode(WidgetPortfolioSnapshot.self, from: data),
              s.schemaVersion <= WidgetPortfolioSnapshot.currentSchema else { return nil }
        return s
    }
}

/// `pfterminal://portfolio`, `pfterminal://asset/<canonical id or symbol>`.
public enum PFLink {
    public static let scheme = "pfterminal"

    public enum Route: Equatable { case portfolio, movers, asset(String) }

    public static var portfolio: URL { URL(string: "\(scheme)://portfolio")! }
    /// `pfterminal://portfolio?pf=<context>`: opens that portfolio (UUID or "all").
    public static func portfolio(context: String?) -> URL {
        guard let context, var c = URLComponents(url: portfolio, resolvingAgainstBaseURL: false) else { return portfolio }
        c.queryItems = [URLQueryItem(name: "pf", value: context)]
        return c.url ?? portfolio
    }
    /// The portfolio context a link asks for, if any.
    public static func context(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pf" }?.value
    }
    public static var movers: URL { URL(string: "\(scheme)://movers")! }
    public static func asset(_ id: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "asset"; c.path = "/" + id
        return c.url ?? portfolio
    }

    public static func route(_ url: URL) -> Route? {
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
