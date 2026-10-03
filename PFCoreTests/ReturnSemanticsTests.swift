import Foundation
import Testing
import PFCore

// RETURN semantics: unrealized vs realized vs total P&L vs total return, from the one ledger engine.

private let btc = Asset(id: "cg:bitcoin", symbol: "BTC", name: "Bitcoin", coingeckoID: "bitcoin")
private let pf = UUID()
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func tx(_ type: TransactionType, _ q: Decimal, _ p: Decimal, fee: Decimal = 0, day: Double = 0) -> Transaction {
    Transaction(portfolioID: pf, assetID: btc.id, type: type, quantity: q, price: p, timestamp: t0.addingTimeInterval(day * 86400), fee: fee)
}
private func summary(_ txs: [Transaction], price: Decimal) -> PortfolioSummary {
    PortfolioEngine.summarize(transactions: txs, assets: [btc.id: btc],
                              quotes: [btc.id: Quote(price: price, source: "test", timestamp: t0)], now: t0.addingTimeInterval(400 * 86400))
}
private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

struct ReturnSemanticsTests {
    @Test func buyOnly() {
        let s = summary([tx(.buy, 2, 100)], price: 150)
        #expect(s.unrealized == 100 && s.realized == 0 && s.totalPnL == 100)
        #expect(near(s.totalReturnPct, 50) && near(s.unrealizedReturnPct, 50))
        #expect(s.invested == 200 && s.netContributed == 200)
    }

    @Test func partialSaleAtProfit() {
        // Buy 2 @100, sell 1 @200, price now 200: realized 100, unrealized 100 on 100 cost.
        let s = summary([tx(.buy, 2, 100), tx(.sell, 1, 200, day: 1)], price: 200)
        #expect(s.realized == 100 && s.unrealized == 100 && s.totalPnL == 200)
        #expect(near(s.unrealizedReturnPct, 100), "unrealized only: what is still held")
        #expect(near(s.totalReturnPct, 100), "total: 200 P&L on 200 invested")
        #expect(s.netContributed == 0, "200 in, 200 out")
    }

    @Test func partialSaleAtLoss() {
        // Buy 2 @100, sell 1 @50, price now 120.
        let s = summary([tx(.buy, 2, 100), tx(.sell, 1, 50, day: 1)], price: 120)
        #expect(s.realized == -50 && s.unrealized == 20 && s.totalPnL == -30)
        #expect(near(s.unrealizedReturnPct, 20))
        #expect(near(s.totalReturnPct, -15), "the old RETURN showed +20% here")
    }

    @Test func fullyClosedPosition() {
        let s = summary([tx(.buy, 1, 100, fee: 1), tx(.sell, 1, 160, fee: 1, day: 1)], price: 999)
        #expect(s.positions.isEmpty && s.closed.count == 1)
        #expect(s.realized == 58 && s.unrealized == 0 && s.totalPnL == 58)
        #expect(s.unrealizedReturnPct == nil, "nothing held, no unrealized return")
        #expect(near(s.totalReturnPct, 58.0 / 101.0 * 100))
    }

    @Test func depositsAndContributions() {
        // Transfer in 1 @ cost 100, later buy 1 @ 300; price 300. A deposit is capital, not performance.
        let s = summary([tx(.transferIn, 1, 100), tx(.buy, 1, 300, day: 30)], price: 300)
        #expect(s.invested == 400 && s.netContributed == 400)
        #expect(s.totalPnL == 200 && near(s.totalReturnPct, 50))
    }

    @Test func mixedRealizedAndUnrealized() {
        let txs = [tx(.buy, 4, 100), tx(.sell, 2, 150, day: 10), tx(.buy, 2, 200, day: 20), tx(.sell, 1, 180, day: 30)]
        let s = summary(txs, price: 250)
        let p = s.positions[0].position
        #expect(p.invested == 800 && s.invested == 800)
        #expect(s.totalPnL == s.realized + s.unrealized)
        #expect(near(s.totalReturnPct, (s.totalPnL / 800).double * 100))
        #expect(near(s.positions[0].totalReturnPct, s.totalReturnPct!), "one asset: position and portfolio agree")
        #expect(!near(s.totalReturnPct, s.unrealizedReturnPct!))
    }

    @Test func partiallyPricedPortfolioHasNoTotalReturn() {
        let eth = Asset(id: "cg:ethereum", symbol: "ETH", name: "Ethereum", coingeckoID: "ethereum")
        let txs = [tx(.buy, 1, 100), Transaction(portfolioID: pf, assetID: eth.id, type: .buy, quantity: 1, price: 10, timestamp: t0)]
        let s = PortfolioEngine.summarize(transactions: txs, assets: [btc.id: btc, eth.id: eth],
                                          quotes: [btc.id: Quote(price: 150, source: "t", timestamp: t0)], now: t0.addingTimeInterval(86400))
        #expect(s.totalReturnPct == nil, "an unpriced position would understate it")
    }

    @Test func twrIgnoresDeposits() {
        // Value doubles with a deposit and no market move: TWR 0%.
        let pts = [HistoryPoint(time: t0, value: 100, cost: 100, invested: 100),
                   HistoryPoint(time: t0.addingTimeInterval(86400), value: 110, cost: 100, invested: 100),
                   HistoryPoint(time: t0.addingTimeInterval(2 * 86400), value: 210, cost: 200, invested: 200)]
        let c = PortfolioChart(value: pts.compactMap(\.value), twr: PortfolioHistoryEngine.twrIndex(pts), points: pts)
        #expect(near(c.twrPercent, 10))
    }
}
