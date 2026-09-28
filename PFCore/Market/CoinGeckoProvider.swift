import Foundation

/// Broad coverage REST provider. Sends only CoinGecko ids — never quantities or values.
public struct CoinGeckoProvider: MarketDataProvider {
    public init(apiKey: String? = nil) { self.apiKey = apiKey }
    public let name = "CoinGecko"
    /// Optional demo/pro key from the Keychain.
    public var apiKey: String?

    private var base: String { "https://api.coingecko.com/api/v3" }
    private var headers: [String: String] { apiKey.map { ["x-cg-demo-api-key": $0] } ?? [:] }

    public func supports(_ asset: Asset) -> Bool { asset.coingeckoID != nil }

    private struct Market: Decodable {
        public let id: String
        public let current_price: Double?
        public let market_cap: Double?
        public let total_volume: Double?
        public let circulating_supply: Double?
        public let ath: Double?
        public let price_change_percentage_1h_in_currency: Double?
        public let price_change_percentage_24h_in_currency: Double?
        public let price_change_percentage_7d_in_currency: Double?
        public let price_change_percentage_30d_in_currency: Double?
        public let price_change_percentage_1y_in_currency: Double?
    }

    public func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        let byID = Dictionary(assets.compactMap { a in a.coingeckoID.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var out: [AssetID: Quote] = [:]
        let ids = Array(byID.keys).sorted()
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            var c = URLComponents(string: base + "/coins/markets")!
            c.queryItems = [
                .init(name: "vs_currency", value: currency.lowercased()),
                .init(name: "ids", value: chunk.joined(separator: ",")),
                .init(name: "price_change_percentage", value: "1h,24h,7d,30d,1y"),
                .init(name: "per_page", value: "250"),
            ]
            let rows = try await HTTP.json([Market].self, c.url!, headers: headers)
            let ts = Date()
            for m in rows {
                guard let a = byID[m.id], let p = m.current_price else { continue }
                var ch: [ChangePeriod: Double] = [:]
                ch[.h1] = m.price_change_percentage_1h_in_currency
                ch[.h24] = m.price_change_percentage_24h_in_currency
                ch[.d7] = m.price_change_percentage_7d_in_currency
                ch[.d30] = m.price_change_percentage_30d_in_currency
                ch[.y1] = m.price_change_percentage_1y_in_currency
                out[a.id] = Quote(price: .of(p), change: ch,
                                  marketCap: m.market_cap.flatMap { $0 > 0 ? Decimal.of($0) : nil }, circulatingSupply: m.circulating_supply.flatMap { $0 > 0 ? Decimal.of($0) : nil },
                                  volume24h: m.total_volume.map(Decimal.of), ath: m.ath.flatMap { $0 > 0 ? Decimal.of($0) : nil }, source: name, timestamp: ts)
            }
        }
        return out
    }

    private struct Chart: Decodable { let prices: [[Double]] }

    public func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] {
        guard let id = asset.coingeckoID else { throw MarketError.unsupported }
        let days: String = {
            switch range {
            case .h1, .d1, .h24: "1"
            case .w1, .d7: "7"
            case .m1, .d30: "30"
            case .m3: "90"
            case .ytd, .y1: "365"
            case .all: "max"
            }
        }()
        func fetch(_ d: String) async throws -> [PricePoint] {
            var c = URLComponents(string: base + "/coins/\(id)/market_chart")!
            c.queryItems = [.init(name: "vs_currency", value: currency.lowercased()), .init(name: "days", value: d)]
            let r = try await HTTP.json(Chart.self, c.url!, headers: headers)
            return r.prices.compactMap { $0.count == 2 ? PricePoint(time: Date(timeIntervalSince1970: $0[0] / 1000), price: $0[1]) : nil }
        }
        do { return try await fetch(days) }
        catch MarketError.unavailable(let code) where days == "max" && (code == 401 || code == 400) {
            return try await fetch("365")    // keyless tier caps history at 365 days
        }
    }

    private struct SearchResult: Decodable {
        public struct Coin: Decodable { let id: String; let name: String; let symbol: String }
        public let coins: [Coin]
    }

    public func search(_ query: String) async throws -> [Asset] {
        var c = URLComponents(string: base + "/search")!
        c.queryItems = [.init(name: "query", value: query)]
        let r = try await HTTP.json(SearchResult.self, c.url!, headers: headers)
        return r.coins.prefix(8).map {
            Asset(id: Asset.makeID(coingeckoID: $0.id, chain: nil, contract: nil, symbol: $0.symbol),
                  symbol: $0.symbol.uppercased(), name: $0.name, coingeckoID: $0.id,
                  binanceSymbol: AssetCatalog.binanceSymbol(forCoinGecko: $0.id))
        }
    }
}
