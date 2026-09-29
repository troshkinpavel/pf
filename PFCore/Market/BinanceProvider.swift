import Foundation

/// Public Binance spot market data for liquid USDT pairs. No credentials, read-only.
/// USDT pairs are treated as USD; other base currencies are left to other providers.
public struct BinanceProvider: MarketDataProvider {
    public init() {}
    public let name = "Binance"
    private let base = "https://api.binance.com/api/v3"

    /// Verified USD-quoted pairs only (the asset's own or the registry's; see MarketMappings).
    public func supports(_ asset: Asset) -> Bool { MarketMappings.binanceSymbol(asset) != nil }

    private struct Ticker: Decodable {
        public let symbol: String
        public let lastPrice: String
        public let priceChangePercent: String
        public let quoteVolume: String?
    }

    public func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        guard currency.uppercased() == "USD" else { throw MarketError.unsupported }
        let bySym = Dictionary(assets.compactMap { a in MarketMappings.binanceSymbol(a).map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        guard !bySym.isEmpty else { return [:] }
        var c = URLComponents(string: base + "/ticker/24hr")!
        let list = "[" + bySym.keys.sorted().map { "\"\($0)\"" }.joined(separator: ",") + "]"
        c.queryItems = [.init(name: "symbols", value: list)]
        let rows = try await HTTP.json([Ticker].self, c.url!)
        let ts = Date()
        var out: [AssetID: Quote] = [:]
        for t in rows {
            guard let a = bySym[t.symbol], let p = Decimal(string: t.lastPrice, locale: Locale(identifier: "en_US_POSIX")), p > 0 else { continue }
            out[a.id] = Quote(price: p, change: [.h24: Double(t.priceChangePercent) ?? 0],
                              volume24h: t.quoteVolume.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) },
                              source: name, timestamp: ts)
        }
        return out
    }

    public func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] {
        guard currency.uppercased() == "USD", let s = MarketMappings.binanceSymbol(asset) else { throw MarketError.unsupported }
        let (interval, limit): (String, Int) = {
            switch range {
            case .h1: ("1m", 60)
            case .d1, .h24: ("15m", 96)
            case .w1, .d7: ("1h", 168)
            case .m1, .d30: ("4h", 180)
            case .m3: ("1d", 90)
            case .ytd, .y1: ("1d", 365)
            case .all: ("1w", 1000)
            }
        }()
        var c = URLComponents(string: base + "/klines")!
        c.queryItems = [.init(name: "symbol", value: s), .init(name: "interval", value: interval), .init(name: "limit", value: String(limit))]
        let rows = try await HTTP.json([[FlexDouble]].self, c.url!)
        return rows.compactMap { r in
            guard r.count > 4, let t = r[0].value, let close = r[4].value else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: t / 1000), price: close)
        }
    }
}
