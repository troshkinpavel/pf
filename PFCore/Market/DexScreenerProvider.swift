import Foundation

/// On-chain tokens, only by verified chain + contract (MarketMappings.dexTargets): the registry's
/// canonical contracts, the curated TEL chains, or a token the user picked by contract. Never by
/// ticker. Picks the most-traded pair per token (see `best`).
public struct DexScreenerProvider: MarketDataProvider {
    public init() {}
    public let name = "DexScreener"
    private let base = "https://api.dexscreener.com"

    public func supports(_ asset: Asset) -> Bool { !MarketMappings.dexTargets(asset).isEmpty }

    struct Pair: Decodable {
        public struct Token: Decodable { let address: String; let name: String?; let symbol: String? }
        public struct Liquidity: Decodable { let usd: Double? }
        public let chainId: String
        public let baseToken: Token
        public let priceUsd: String?
        public let priceChange: [String: FlexDouble]?
        public let volume: [String: FlexDouble]?
        public let liquidity: Liquidity?
        public let marketCap: Double?
    }

    public func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        guard currency.uppercased() == "USD" else { throw MarketError.unsupported }
        // (asset, chain, contract) per verified target; one request per chain batch.
        let targets = assets.flatMap { a in MarketMappings.dexTargets(a).map { (asset: a, chain: $0.chain, contract: $0.contract) } }
        let ids = Dictionary(grouping: targets, by: \.asset.id).compactMap { $0.value.first?.asset }
        var pairs: [AssetID: [Pair]] = [:]
        var lastError: Error?, answered = false
        for chain in Set(targets.map(\.chain)).sorted() {
            let list = targets.filter { $0.chain == chain }
            for chunk in stride(from: 0, to: list.count, by: 30).map({ Array(list[$0..<min($0 + 30, list.count)]) }) {
                let contracts = Array(Set(chunk.map(\.contract))).sorted()
                guard let url = URL(string: "\(base)/tokens/v1/\(chain)/\(contracts.joined(separator: ","))") else { continue }
                // One chain failing doesn't lose the others.
                do {
                    let got = try await HTTP.json([Pair].self, url)
                    answered = true
                    for x in chunk { pairs[x.asset.id, default: []] += got.filter { $0.baseToken.address.lowercased() == x.contract } }
                } catch { lastError = error }
            }
        }
        if !answered, let lastError { throw lastError }
        let ts = Date()
        var out: [AssetID: Quote] = [:]
        for a in ids {
            guard let b = Self.best(pairs[a.id] ?? []), let ps = b.priceUsd,
                  let p = Decimal(string: ps, locale: Locale(identifier: "en_US_POSIX")), p > 0 else { continue }
            var ch: [ChangePeriod: Double] = [:]
            ch[.h1] = b.priceChange?["h1"]?.value
            ch[.h24] = b.priceChange?["h24"]?.value
            out[a.id] = Quote(price: p, change: ch, marketCap: b.marketCap.map(Decimal.of),
                                    volume24h: b.volume?["h24"]?.value.map(Decimal.of), source: name, timestamp: ts)
        }
        return out
    }

    /// Pools below this USD liquidity are dust: a single tiny trade sets their price.
    static let minLiquidity: Double = 1_000

    /// The pair whose price is most current: highest 24h volume among pools with at least
    /// `minLiquidity`, ties broken by liquidity. The deepest pool is not always the one that
    /// trades (TEL on Ethereum: $55k liquidity, $543/day, price 20% off the market). If every
    /// pool is dust, the most liquid one.
    static func best(_ pairs: [Pair]) -> Pair? {
        let liq = { (p: Pair) in p.liquidity?.usd ?? 0 }
        let vol = { (p: Pair) in p.volume?["h24"]?.value ?? 0 }
        let priced = pairs.filter { $0.priceUsd != nil }
        let real = priced.filter { liq($0) >= minLiquidity }
        if real.isEmpty { return priced.max { liq($0) < liq($1) } }
        return real.max { (vol($0), liq($0)) < (vol($1), liq($1)) }
    }

    private struct SearchResult: Decodable { let pairs: [Pair]? }

    public func search(_ query: String) async throws -> [Asset] {
        var c = URLComponents(string: base + "/latest/dex/search")!
        c.queryItems = [.init(name: "q", value: query)]
        let r = try await HTTP.json(SearchResult.self, c.url!)
        var seen = Set<String>()
        // Thin pools quote garbage prices: only pairs with real liquidity are offered.
        return (r.pairs ?? []).filter { ($0.liquidity?.usd ?? 0) >= 10_000 }
            .sorted { ($0.liquidity?.usd ?? 0) > ($1.liquidity?.usd ?? 0) }.compactMap { p in
            let key = p.chainId + p.baseToken.address.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            let sym = (p.baseToken.symbol ?? "?").uppercased()
            return Asset(id: Asset.makeID(coingeckoID: nil, chain: p.chainId, contract: p.baseToken.address, symbol: sym),
                         symbol: sym, name: p.baseToken.name ?? sym, chain: p.chainId, contractAddress: p.baseToken.address)
        }.prefix(5).map { $0 }
    }
}
