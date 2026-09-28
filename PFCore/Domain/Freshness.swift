import Foundation

/// How current the market data behind the portfolio is. Shared by macOS and iOS so both
/// label the same state the same way. Colors are per platform (UI layer).
public enum Freshness: Equatable, Sendable {
    case live, syncing, stale(TimeInterval), partial(Int), offline, noData

    public var label: String {
        switch self {
        case .live: "LIVE"; case .syncing: "SYNCING"; case let .stale(a): "STALE \(DateFmt.age(a))"
        case let .partial(n): "PARTIAL · \(n) unpriced"
        case .offline: "OFFLINE"; case .noData: "NO DATA"
        }
    }
    public var glyph: String { switch self { case .live: "●"; case .syncing: "◐"; default: "○" } }
    public var isLive: Bool { self == .live || self == .syncing }

    /// LIVE only when every held asset has a fresh, non-cached quote (interval + 30 s grace).
    public static func evaluate(online: Bool, inFlight: Bool, held: [AssetID], quotes: [AssetID: Quote],
                         hasSucceeded: Bool, refreshSeconds: Int, now: Date) -> Freshness {
        if !online { return .offline }
        if inFlight { return .syncing }
        if held.isEmpty { return hasSucceeded ? .live : .noData }
        let qs = held.compactMap { quotes[$0] }
        guard let oldest = qs.map(\.timestamp).min() else { return .noData }
        let age = now.timeIntervalSince(oldest)
        let fresh = !qs.contains { $0.source == "cache" } && age <= TimeInterval(refreshSeconds) + 30
        if !fresh { return .stale(max(age, 0)) }
        return qs.count == held.count ? .live : .partial(held.count - qs.count)
    }

    /// Age of the oldest quote among held assets (for "prices 18m old").
    public static func oldestQuoteAge(held: [AssetID], quotes: [AssetID: Quote], now: Date) -> TimeInterval? {
        held.compactMap { quotes[$0]?.timestamp }.min().map { max(0, now.timeIntervalSince($0)) }
    }
}
