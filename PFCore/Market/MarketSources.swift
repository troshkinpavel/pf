import Foundation

// Market sources, verified mappings and price status. Views render `SourceState`; nothing
// here is decided in the UI (docs/DEVELOPMENT.md → Market sources).

/// A market-data source. Raw value = provider name. Extensible: `MarketSource("Gate.io")`.
public struct MarketSource: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { rawValue = raw }

    public static let binance = MarketSource("Binance")
    public static let bybit = MarketSource("Bybit")
    public static let coingecko = MarketSource("CoinGecko")
    public static let dexscreener = MarketSource("DexScreener")
    public static let cache = MarketSource("cache")

    /// Automatic priority: live exchange feeds, then batched CoinGecko, then canonical DEX pools.
    public static let autoOrder: [MarketSource] = [.binance, .bybit, .coingecko, .dexscreener]
    /// Sources with a public live feed (WebSocket).
    public static let streaming: Set<MarketSource> = [.binance, .bybit]

    public var label: String {
        switch self {
        case .dexscreener: "DEX"
        case .cache: "CACHE"
        default: rawValue.uppercased()
        }
    }
    public var description: String { rawValue }
}

/// Verified mappings only: the asset's own identifiers, the registry, the curated overlay.
/// Nothing is inferred from a ticker.
public enum MarketMappings {
    /// Quotes that count as USD for exchange pairs.
    static let usdQuotes = ["USDT", "USDC", "FDUSD"]

    /// A Binance/Bybit pair is usable only if it quotes in a USD stablecoin (rejects e.g. USDTTRY).
    public static func validBinance(_ s: String?) -> String? { validUSDPair(s) }
    static func validUSDPair(_ s: String?) -> String? {
        guard let s = s?.uppercased(), let q = usdQuotes.first(where: { s.hasSuffix($0) }), s.count > q.count else { return nil }
        return s
    }

    public static func binanceSymbol(_ a: Asset, registry: AssetRegistry = .shared) -> String? {
        validUSDPair(a.binanceSymbol) ?? validUSDPair(registry.entry(for: a)?.binanceSymbol)
    }

    public static func bybitSymbol(_ a: Asset, registry: AssetRegistry = .shared) -> String? {
        validUSDPair(registry.entry(for: a)?.bybitSymbol)
    }

    public static func coingeckoID(_ a: Asset, registry: AssetRegistry = .shared) -> String? {
        a.coingeckoID ?? registry.entry(for: a)?.coingeckoId
    }

    /// CoinGecko platform id → DexScreener chain id, for chains whose id is certain.
    public static let dexChains: [String: String] = [
        "ethereum": "ethereum", "binance-smart-chain": "bsc", "solana": "solana", "base": "base",
        "arbitrum-one": "arbitrum", "polygon-pos": "polygon", "avalanche": "avalanche", "optimistic-ethereum": "optimism",
        "sui": "sui", "tron": "tron", "the-open-network": "ton", "zksync": "zksync", "blast": "blast", "linea": "linea",
        "celo": "celo", "cronos": "cronos", "mantle": "mantle",
    ]

    public struct DexTarget: Hashable, Sendable { public var chain: String; public var contract: String }

    /// Canonical contracts to ask DexScreener about. A token the user picked by chain + contract
    /// (not in the registry) keeps its own; registry assets use only their verified contracts.
    public static func dexTargets(_ a: Asset, registry: AssetRegistry = .shared) -> [DexTarget] {
        var out: [DexTarget] = []
        if let c = a.chain, let x = a.contractAddress { out.append(DexTarget(chain: c.lowercased(), contract: x.lowercased())) }
        if let e = registry.entry(for: a) {
            for (platform, contract) in e.contracts.sorted(by: { $0.key < $1.key }) {
                if let chain = dexChains[platform] { out.append(DexTarget(chain: chain, contract: contract.lowercased())) }
            }
        }
        if let f = AssetCatalog.dexFallback[a.id] { out += f.chains.map { DexTarget(chain: $0, contract: f.contract.lowercased()) } }
        var seen = Set<DexTarget>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Sources that can price this asset, in automatic priority order.
    public static func availableSources(_ a: Asset, registry: AssetRegistry = .shared) -> [MarketSource] {
        var s: [MarketSource] = []
        if binanceSymbol(a, registry: registry) != nil { s.append(.binance) }
        if bybitSymbol(a, registry: registry) != nil { s.append(.bybit) }
        if coingeckoID(a, registry: registry) != nil { s.append(.coingecko) }
        if !dexTargets(a, registry: registry).isEmpty { s.append(.dexscreener) }
        return s
    }

    /// The order to try for this asset: the user's preferred source (if available), then auto.
    public static func route(_ a: Asset, registry: AssetRegistry = .shared) -> [MarketSource] {
        let avail = availableSources(a, registry: registry)
        guard let p = a.preferredSource.map(MarketSource.init(rawValue:)), avail.contains(p) else { return avail }
        return [p] + avail.filter { $0 != p }
    }
}

/// Price status thresholds, in one place.
public enum MarketStatusPolicy {
    /// A streamed price younger than this is LIVE (illiquid pairs can be quiet for a while).
    public static let liveThreshold: TimeInterval = 120
    /// A stored / polled price younger than this is CACHED; older is DELAYED.
    public static let cachedThreshold: TimeInterval = 5 * 60
    /// Older than this is STALE.
    public static let staleThreshold: TimeInterval = 15 * 60
    /// A stream silent for this long is treated as down (heartbeat / stale detection).
    public static let streamSilence: TimeInterval = 90
}

public enum PriceStatus: Equatable, Sendable {
    case live(MarketSource)
    case cached(age: TimeInterval)
    case delayed(age: TimeInterval)
    case fallback(MarketSource)
    case stale(age: TimeInterval)
    case noPrice

    public var label: String {
        switch self {
        case let .live(s): "LIVE · \(s.label)"
        case let .cached(a): "CACHED · \(Self.age(a))"
        case let .delayed(a): "DELAYED · \(Self.age(a))"
        case let .fallback(s): "FALLBACK · \(s.label)"
        case let .stale(a): "STALE · \(Self.age(a))"
        case .noPrice: "NO PRICE"
        }
    }

    public var isLive: Bool { if case .live = self { true } else { false } }
    public var isFallback: Bool { if case .fallback = self { true } else { false } }

    static func age(_ s: TimeInterval) -> String {
        let s = max(0, Int(s))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Everything the UI shows about where an asset's price comes from.
public struct SourceState: Equatable, Sendable {
    public var available: [MarketSource]
    public var preferred: MarketSource?           // nil = Auto
    public var expected: MarketSource?            // first choice: preferred, else best available
    public var active: MarketSource?              // who produced the current price
    public var updatedAt: Date?
    public var status: PriceStatus

    public var isLive: Bool { status.isLive }
    public var isFallback: Bool { status.isFallback }

    /// - streaming: sources with a healthy live feed for this asset right now.
    public static func evaluate(_ a: Asset, quote: Quote?, streaming: Set<MarketSource>, now: Date = Date(),
                                registry: AssetRegistry = .shared) -> SourceState {
        let avail = MarketMappings.availableSources(a, registry: registry)
        let preferred = a.preferredSource.map(MarketSource.init(rawValue:)).flatMap { avail.contains($0) ? $0 : nil }
        let expected = preferred ?? avail.first
        guard let q = quote else {
            return SourceState(available: avail, preferred: preferred, expected: expected, active: nil, updatedAt: nil, status: .noPrice)
        }
        let active = MarketSource(rawValue: q.source)
        let age = max(0, now.timeIntervalSince(q.timestamp))
        let status: PriceStatus = {
            if age > MarketStatusPolicy.staleThreshold { return .stale(age: age) }
            let isFallback = active != .cache && expected != nil && active != expected
            if streaming.contains(active), age <= MarketStatusPolicy.liveThreshold {
                return isFallback ? .fallback(active) : .live(active)
            }
            if isFallback { return .fallback(active) }
            return age <= MarketStatusPolicy.cachedThreshold ? .cached(age: age) : .delayed(age: age)
        }()
        return SourceState(available: avail, preferred: preferred, expected: expected, active: active, updatedAt: q.timestamp, status: status)
    }
}
