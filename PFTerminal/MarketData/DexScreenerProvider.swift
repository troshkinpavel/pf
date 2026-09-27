import Foundation

/// On-chain tokens identified by chain + contract. Picks the most liquid pair per token.
struct DexScreenerProvider: MarketDataProvider {
    let name = "DexScreener"
    private let base = "https://api.dexscreener.com"

    func supports(_ asset: Asset) -> Bool { asset.chain != nil && asset.contractAddress != nil }

    private struct Pair: Decodable {
        struct Token: Decodable { let address: String; let name: String?; let symbol: String? }
        struct Liquidity: Decodable { let usd: Double? }
        let chainId: String
        let baseToken: Token
        let priceUsd: String?
        let priceChange: [String: FlexDouble]?
        let volume: [String: FlexDouble]?
        let liquidity: Liquidity?
        let marketCap: Double?
    }

    func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        guard currency.uppercased() == "USD" else { throw MarketError.unsupported }
        var out: [AssetID: Quote] = [:]
        let byChain = Dictionary(grouping: assets.filter(supports), by: { $0.chain!.lowercased() })
        for (chain, list) in byChain {
            for chunk in stride(from: 0, to: list.count, by: 30).map({ Array(list[$0..<min($0 + 30, list.count)]) }) {
                let addrs = chunk.map { $0.contractAddress! }.joined(separator: ",")
                guard let url = URL(string: "\(base)/tokens/v1/\(chain)/\(addrs)") else { continue }
                let pairs = try await HTTP.json([Pair].self, url)
                let ts = Date()
                for a in chunk {
                    let best = pairs.filter { $0.baseToken.address.lowercased() == a.contractAddress!.lowercased() }
                        .max { ($0.liquidity?.usd ?? 0) < ($1.liquidity?.usd ?? 0) }
                    guard let b = best, let ps = b.priceUsd, let p = Decimal(string: ps, locale: Locale(identifier: "en_US_POSIX")), p > 0 else { continue }
                    var ch: [ChangePeriod: Double] = [:]
                    ch[.h1] = b.priceChange?["h1"]?.value
                    ch[.h24] = b.priceChange?["h24"]?.value
                    out[a.id] = Quote(price: p, change: ch, marketCap: b.marketCap.map(Decimal.of),
                                      volume24h: b.volume?["h24"]?.value.map(Decimal.of), source: name, timestamp: ts)
                }
            }
        }
        return out
    }

    private struct SearchResult: Decodable { let pairs: [Pair]? }

    func search(_ query: String) async throws -> [Asset] {
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
