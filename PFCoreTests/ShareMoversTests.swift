import Foundation
import Testing
import PFCore

/// Share card "TOP GAINERS" and the snapshot-history fallback.
struct ShareMoversTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = Asset(id: "cg:a", symbol: "AAA", name: "a", coingeckoID: "a")
    let b = Asset(id: "cg:b", symbol: "BBB", name: "b", coingeckoID: "b")
    let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!
    let pf = UUID()

    @Test func gainersAreYourReturnOverThePeriodNotThePriceMove() {
        // AAA: price +82% over 30 days, but bought 5 days ago at 180 → now 182 (+1.1% for you).
        // BBB: held all month, 100 → 120 (+20%).
        let txs = [
            Transaction(portfolioID: pf, assetID: a.id, type: .buy, quantity: 10, price: 180, timestamp: now.addingTimeInterval(-5 * 86400)),
            Transaction(portfolioID: pf, assetID: b.id, type: .buy, quantity: 10, price: 90, timestamp: now.addingTimeInterval(-60 * 86400)),
            Transaction(portfolioID: pf, assetID: usdc.id, type: .buy, quantity: 1000, price: 1, timestamp: now.addingTimeInterval(-60 * 86400)),
        ]
        let quotes: [AssetID: Quote] = [
            a.id: Quote(price: 182, change: [.d30: 82], source: "t", timestamp: now),
            b.id: Quote(price: 120, change: [.d30: 20], source: "t", timestamp: now),
            usdc.id: Quote(price: 1, change: [.d30: 0.01], source: "t", timestamp: now),
        ]
        let s = PortfolioEngine.summarize(transactions: txs, assets: [a.id: a, b.id: b, usdc.id: usdc], quotes: quotes, now: now)
        let mv = MoversEngine.movers(summary: s, transactions: txs, quotes: quotes, series: [:], range: .d30, now: now)
        #expect(abs((mv.first { $0.id == a.id }?.periodReturn ?? 0) - 100.0 * 20 / 1800) < 1e-9, "only since the buy")
        #expect(abs((mv.first { $0.id == b.id }?.periodReturn ?? 0) - 20) < 1e-9)
        #expect(mv.first { $0.id == a.id }?.changePct == 82, "Movers screen keeps the price move")
        var c = ShareConfig(); c.period = .d30; c.privacy = .custom; c.custom = [.pct, .movers]; c.moverType = .gainers; c.moverCount = 5
        let card = ShareCardBuilder.build(config: c, summary: s, performance: nil, history: [], movers: mv, now: now, fmt: Fmt(style: .comma, currency: "USD"))
        #expect(card.movers?.map(\.symbol) == ["BBB", "AAA"], "ranked by your return; stablecoins left out")
        #expect(card.moversSub == "your return")
    }

    @Test func noPositiveReturnMeansNoGainers() {
        let txs = [Transaction(portfolioID: pf, assetID: b.id, type: .buy, quantity: 1, price: 100, timestamp: now.addingTimeInterval(-60 * 86400))]
        let quotes = [b.id: Quote(price: 80, change: [.d30: -20], source: "t", timestamp: now)]
        let s = PortfolioEngine.summarize(transactions: txs, assets: [b.id: b], quotes: quotes, now: now)
        let mv = MoversEngine.movers(summary: s, transactions: txs, quotes: quotes, series: [:], range: .d30, now: now)
        var c = ShareConfig(); c.period = .d30; c.privacy = .custom; c.custom = [.movers]; c.moverType = .gainers
        let card = ShareCardBuilder.build(config: c, summary: s, performance: nil, history: [], movers: mv, now: now, fmt: Fmt(style: .comma, currency: "USD"))
        #expect(card.movers?.isEmpty == true && card.moversSub == "none this period", "a loser is never listed as a gainer")
    }

    @Test func snapshotFallbackTWRIsNotFooledByAProfitableSell() {
        // Buy 10 @100 (cost 1000). Price doubles. Sell 5 @200: cash out 1000, cost basis −500.
        let t0 = now.addingTimeInterval(-40 * 86400)   // held for the whole range, no price history → snapshots
        let txs = [Transaction(portfolioID: pf, assetID: b.id, type: .buy, quantity: 10, price: 100, timestamp: t0),
                   Transaction(portfolioID: pf, assetID: b.id, type: .sell, quantity: 5, price: 200, timestamp: now.addingTimeInterval(-86400))]
        let snaps = [PortfolioSnapshotValue(timestamp: now.addingTimeInterval(-25 * 86400), value: 1000, costBasis: 1000, unrealized: 0),
                     PortfolioSnapshotValue(timestamp: now.addingTimeInterval(-2 * 86400), value: 2000, costBasis: 1000, unrealized: 1000),
                     PortfolioSnapshotValue(timestamp: now.addingTimeInterval(-3600), value: 1000, costBasis: 500, unrealized: 500)]
        let s = PortfolioEngine.summarize(transactions: txs, assets: [b.id: b], quotes: [b.id: Quote(price: 200, source: "t", timestamp: now)], now: now)
        let c = PortfolioHistoryEngine.chart(transactions: txs, summary: s, range: .d30, points: 30, series: [:], now: now) { _ in snaps }
        #expect(c.twr.count == 3)
        #expect(abs((c.twrPercent ?? 0) - 100) < 1e-6, "price doubled: +100%, no cliff at the sell (got \(c.twrPercent ?? .nan))")
    }
}
