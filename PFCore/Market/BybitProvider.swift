import Foundation

/// Bybit v5 public spot market data (REST): current tickers and klines for verified pairs only
/// (MarketMappings.bybitSymbol: registry / curated overlay, never a ticker guess). No key, no auth.
/// USD-stablecoin quoted pairs are treated as USD, like Binance.
public struct BybitProvider: MarketDataProvider {
    public init() {}
    public let name = "Bybit"
    private let base = "https://api.bybit.com/v5/market"

    public func supports(_ asset: Asset) -> Bool { MarketMappings.bybitSymbol(asset) != nil }

    struct Envelope<T: Decodable>: Decodable { let retCode: Int; let result: T? }
    struct Tickers: Decodable {
        struct Row: Decodable { let symbol: String; let lastPrice: String; let price24hPcnt: String?; let turnover24h: String? }
        let list: [Row]
    }
    struct Klines: Decodable { let list: [[String]] }

    public func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        guard currency.uppercased() == "USD" else { throw MarketError.unsupported }
        let bySym = Dictionary(assets.compactMap { a in MarketMappings.bybitSymbol(a).map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        guard !bySym.isEmpty else { return [:] }
        var c = URLComponents(string: base + "/tickers")!
        c.queryItems = [.init(name: "category", value: "spot")]
        // One symbol: ask for it; several: one request for all spot tickers (still a single call).
        if bySym.count == 1 { c.queryItems?.append(.init(name: "symbol", value: bySym.keys.first)) }
        return Self.parseTickers(try await HTTP.get(c.url!), bySymbol: bySym, at: Date())
    }

    static func parseTickers(_ data: Data, bySymbol: [String: Asset], at ts: Date) -> [AssetID: Quote] {
        guard let e = try? JSONDecoder().decode(Envelope<Tickers>.self, from: data), e.retCode == 0, let rows = e.result?.list else { return [:] }
        var out: [AssetID: Quote] = [:]
        for r in rows {
            guard let a = bySymbol[r.symbol], let p = Decimal(string: r.lastPrice, locale: Locale(identifier: "en_US_POSIX")), p > 0 else { continue }
            var ch: [ChangePeriod: Double] = [:]
            ch[.h24] = r.price24hPcnt.flatMap(Double.init).map { $0 * 100 }
            out[a.id] = Quote(price: p, change: ch, volume24h: r.turnover24h.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) },
                              source: "Bybit", timestamp: ts)
        }
        return out
    }

    public func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] {
        guard currency.uppercased() == "USD", let s = MarketMappings.bybitSymbol(asset) else { throw MarketError.unsupported }
        let (interval, limit): (String, Int) = {
            switch range {
            case .h1: ("1", 60)
            case .d1, .h24: ("15", 96)
            case .w1, .d7: ("60", 168)
            case .m1, .d30: ("240", 180)
            case .m3: ("D", 90)
            case .ytd, .y1: ("D", 365)
            case .all: ("W", 1000)
            }
        }()
        var c = URLComponents(string: base + "/kline")!
        c.queryItems = [.init(name: "category", value: "spot"), .init(name: "symbol", value: s),
                        .init(name: "interval", value: interval), .init(name: "limit", value: String(limit))]
        return Self.parseKlines(try await HTTP.get(c.url!))
    }

    /// Rows are [start ms, open, high, low, close, volume, turnover], newest first.
    static func parseKlines(_ data: Data) -> [PricePoint] {
        guard let e = try? JSONDecoder().decode(Envelope<Klines>.self, from: data), e.retCode == 0, let rows = e.result?.list else { return [] }
        return rows.compactMap { r in
            guard r.count > 4, let t = Double(r[0]), let close = Double(r[4]) else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: t / 1000), price: close)
        }.sorted { $0.time < $1.time }
    }
}
