import Foundation

/// Deterministic offline market for development, previews, screenshots and tests.
/// Never used unless explicitly selected (DEBUG setting or `--mock-market`).
/// Values reproduce the design prototype.
public struct MockMarketDataProvider: MarketDataProvider {
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }
    public let name = "Mock"
    public var now: @Sendable () -> Date = Date.init

    public struct Spec: Sendable {
        public init(price: Double, supply: Double, ath: Double, vol: Double, ch: [ChangePeriod: Double], noise: Double) { self.price = price; self.supply = supply; self.ath = ath; self.vol = vol; self.ch = ch; self.noise = noise }
        public let price: Double, supply: Double, ath: Double, vol: Double
        public let ch: [ChangePeriod: Double]
        public let noise: Double
    }

    public static let specs: [String: Spec] = [
        "bitcoin": .init(price: 91420, supply: 19.93e6, ath: 126_080, vol: 38.2e9, ch: [.h1: 0.12, .h24: 2.41, .d7: -0.84, .d30: 5.62, .y1: 38.9], noise: 1),
        "telcoin-2": .init(price: 0.00431, supply: 91.4e9, ath: 0.0636, vol: 14.8e6, ch: [.h1: 0.64, .h24: 8.72, .d7: 18.21, .d30: 41.3, .y1: 62.4], noise: 1.6),
        "zcash": .init(price: 182.4, supply: 16.3e6, ath: 5941.8, vol: 612e6, ch: [.h1: -0.21, .h24: -1.32, .d7: -6.4, .d30: 12.8, .y1: 84.2], noise: 1.3),
        "ethereum": .init(price: 3840, supply: 120.7e6, ath: 4953, vol: 21.4e9, ch: [.h1: 0.08, .h24: 1.87, .d7: 3.1, .d30: -2.2, .y1: 44.1], noise: 1.1),
    ]

    public static let assets: [Asset] = ["bitcoin", "telcoin-2", "zcash", "ethereum"].compactMap { id in AssetCatalog.known.first { $0.coingeckoID == id } }

    public func supports(_ asset: Asset) -> Bool { asset.coingeckoID.map { Self.specs[$0] != nil } ?? false }

    public func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        var out: [AssetID: Quote] = [:]
        for a in assets {
            guard let id = a.coingeckoID, let s = Self.specs[id] else { continue }
            out[a.id] = Quote(price: .of(s.price), change: s.ch, marketCap: .of(s.price * s.supply), circulatingSupply: .of(s.supply),
                              volume24h: .of(s.vol), ath: .of(s.ath), source: name, timestamp: now())
        }
        return out
    }

    public func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] {
        guard let id = asset.coingeckoID, let s = Self.specs[id] else { throw MarketError.unsupported }
        let end = now()
        let start = range == .all ? end.addingTimeInterval(-3 * 365 * 86400) : range.start(now: end, firstTransaction: nil)
        return PortfolioHistoryEngine.grid(start: start, end: end, count: 240).map { PricePoint(time: $0, price: Self.price(s, seed: id, at: $0, now: end)) }
    }

    public func search(_ query: String) async throws -> [Asset] {
        Self.assets.filter { Fuzzy.score(query, $0.symbol + " " + $0.name) > 0 }
    }

    /// Continuous deterministic path through the quoted period changes (knots), with seeded wiggle between knots.
    public static func price(_ s: Spec, seed: String, at t: Date, now: Date) -> Double {
        let ago = now.timeIntervalSince(t)
        func p(_ c: ChangePeriod) -> Double { s.price / (1 + (s.ch[c] ?? 0) / 100) }
        let knots: [(TimeInterval, Double)] = [
            (0, s.price), (3600, p(.h1)), (86400, p(.h24)), (7 * 86400, p(.d7)), (30 * 86400, p(.d30)),
            (365 * 86400, p(.y1)), (3 * 365 * 86400, p(.y1) / 1.8),
        ]
        guard ago > 0 else { return s.price }
        var k = 0
        while k < knots.count - 2 && ago > knots[k + 1].0 { k += 1 }
        let (a0, pa) = knots[k], (a1, pb) = knots[k + 1]
        let u = min(1, max(0, (ago - a0) / (a1 - a0)))
        let base = exp(log(pa) + (log(pb) - log(pa)) * u)
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let ph = Double(h % 1000) / 1000 * 2 * .pi
        let wig = sin(u * 13 + ph) * 0.5 + sin(u * 37 + ph * 2) * 0.3 + sin(u * 89 + ph * 3) * 0.2
        let amp = (0.015 + 0.25 * abs(log(pb / pa))) * s.noise
        return base * (1 + wig * amp * sin(.pi * u))
    }
}

public enum DemoPortfolio {
    /// The prototype's ledger, clearly marked demo; removable in one action.
    public static func transactions(portfolio: UUID = Transaction.unassigned) -> [Transaction] {
        let rows: [(String, Double, Double, String)] = [
            ("bitcoin", 0.12, 58400, "2024-09-06"), ("ethereum", 1.2, 3020, "2025-02-01"),
            ("telcoin", 1_200_000, 0.00241, "2025-11-04"), ("zcash", 30, 128.5, "2025-12-19"),
            ("bitcoin", 0.0813, 77740, "2026-01-22"), ("telcoin", 1_735_000, 0.00151, "2026-02-18"),
            ("zcash", 14.52, 195.03, "2026-04-07"), ("telcoin", 500_000, 0.00175, "2026-06-09"),
            ("ethereum", 0.612, 3730, "2026-07-15"),
        ]
        return rows.map { cg, q, p, d in
            Transaction(portfolioID: portfolio, assetID: "cg:" + cg, type: .buy, quantity: .of(q), price: .of(p), timestamp: DateFmt.parseYMD(d)!, note: "demo")
        }
    }
}
