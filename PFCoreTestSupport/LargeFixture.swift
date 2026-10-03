import Foundation
import PFCore

/// Reproducible large-ledger fixture for performance checks: 10,000 transactions, 60 assets,
/// 3 portfolios, 3 years of daily prices. Deterministic (seeded).
public enum LargeFixture {
    public static let now = Date(timeIntervalSince1970: 1_800_000_000)
    public static func make(_ n: Int = 10_000, assets k: Int = 60, portfolios np: Int = 3) -> (PortfolioDocument, [AssetID: Quote], [AssetID: PriceSeries]) {
        var rng = SplitMix(seed: 42)
        var d = PortfolioDocument.fresh(now: now.addingTimeInterval(-1100 * 86400))
        for i in 1..<np { _ = try? d.createPortfolio(name: "P\(i)", glyph: "◇") }
        d.assets = (0..<k).map { Asset(id: "cg:a\($0)", symbol: "A\($0)", name: "asset \($0)", coingeckoID: "a\($0)") }
        var held: [String: Decimal] = [:]
        let start = now.addingTimeInterval(-1095 * 86400)
        for i in 0..<n {
            let a = d.assets[Int(rng.next() % UInt64(k))], p = d.portfolios[Int(rng.next() % UInt64(np))]
            let key = "\(p.id)|\(a.id)", h = held[key] ?? 0
            let sell = h > 2 && rng.next() % 3 == 0
            let q = Decimal(Int(rng.next() % 5) + 1)
            let t = Transaction(portfolioID: p.id, assetID: a.id, type: sell ? .sell : .buy, quantity: sell ? min(q, h) : q,
                                price: Decimal(Int(rng.next() % 900) + 100), timestamp: start.addingTimeInterval(Double(i) * 1095 * 86400 / Double(n)), fee: 1)
            held[key] = sell ? h - t.quantity : h + q
            d.transactions.append(t)
        }
        let quotes = Dictionary(uniqueKeysWithValues: d.assets.map { ($0.id, Quote(price: 500, change: [.h24: 1.5], source: "t", timestamp: now)) })
        let series = Dictionary(uniqueKeysWithValues: d.assets.map { a in
            (a.id, PriceSeries((0..<1100).map { PricePoint(time: start.addingTimeInterval(Double($0) * 86400), price: 300 + Double($0 % 400)) }))
        })
        return (d, quotes, series)
    }

    public struct SplitMix { public var seed: UInt64; public init(seed: UInt64) { self.seed = seed }; public mutating func next() -> UInt64 { seed &+= 0x9E3779B97F4A7C15; var z = seed; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
}

