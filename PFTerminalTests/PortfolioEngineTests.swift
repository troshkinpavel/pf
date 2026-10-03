import PFCore
import PFCoreTestSupport
import Foundation
import Testing
@testable import PFTerminal

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
private func day(_ s: String) -> Date { DateFmt.parseYMD(s)! }
private func tx(_ type: TransactionType, _ q: String, _ p: String, _ date: String, fee: String = "0", asset: AssetID = "cg:bitcoin") -> Transaction {
    Transaction(assetID: asset, type: type, quantity: d(q), price: d(p), timestamp: day(date), fee: d(fee))
}
private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private let eth = AssetCatalog.known.first { $0.symbol == "ETH" }!
private let assets = [btc.id: btc, eth.id: eth]
private func quote(_ p: String, ch24: Double? = nil, supply: String? = nil) -> Quote {
    Quote(price: d(p), change: ch24.map { [.h24: $0] } ?? [:], circulatingSupply: supply.map(d), source: "test", timestamp: Date())
}

struct LedgerTests {
    @Test func weightedAverageAcrossMultipleBuys() {
        let p = PortfolioEngine.positions([tx(.buy, "1", "100", "2025-01-01"), tx(.buy, "3", "200", "2025-02-01")])[btc.id]!
        #expect(p.quantity == 4)
        #expect(p.costBasis == 700)
        #expect(p.averageEntry == d("175"))
    }

    @Test func feesAreAddedToCostBasis() {
        let p = PortfolioEngine.positions([tx(.buy, "2", "100", "2025-01-01", fee: "10")])[btc.id]!
        #expect(p.costBasis == 210)
        #expect(p.averageEntry == 105)
    }

    @Test func partialSellRealizesAgainstAverageCost() {
        let p = PortfolioEngine.positions([
            tx(.buy, "1", "100", "2025-01-01"), tx(.buy, "1", "300", "2025-01-02"),
            tx(.sell, "1", "400", "2025-01-03", fee: "5"),
        ])[btc.id]!
        #expect(p.quantity == 1)
        #expect(p.costBasis == 200)           // avg 200 unchanged by a sell
        #expect(p.averageEntry == 200)
        #expect(p.realizedPnL == 195)          // 400 − 5 − 200
    }

    @Test func fullSellClosesExactly() {
        // 3 units at 100/3 average would leave division residue without the exact-exit rule.
        let p = PortfolioEngine.positions([tx(.buy, "3", "33.333333", "2025-01-01", fee: "0.000001"), tx(.sell, "3", "50", "2025-02-01")])[btc.id]!
        #expect(p.quantity == 0)
        #expect(p.costBasis == 0)
        #expect(p.realizedPnL == 150 - d("100"))
        #expect(p.averageEntry == nil)
    }

    @Test func transfersMoveQuantityWithoutRealizingGains() {
        let p = PortfolioEngine.positions([
            tx(.buy, "2", "100", "2025-01-01"), tx(.transferOut, "1", "0", "2025-01-02", fee: "1"),
            tx(.transferIn, "1", "150", "2025-01-03"),
        ])[btc.id]!
        #expect(p.quantity == 2)
        #expect(p.costBasis == 250)
        #expect(p.realizedPnL == -1)           // only the transfer fee
    }

    @Test func oversellIsRejectedByValidation() {
        let errs = PortfolioEngine.validate([tx(.buy, "1", "100", "2025-01-02"), tx(.sell, "1", "100", "2025-01-01")])
        #expect(errs.contains { if case .oversold = $0 { return true }; return false })
    }

    @Test func editingAHistoricalTransactionRecalculates() {
        var ledger = [tx(.buy, "1", "100", "2025-01-01"), tx(.buy, "1", "200", "2025-02-01")]
        #expect(PortfolioEngine.positions(ledger)[btc.id]!.averageEntry == 150)
        ledger[0].price = 300
        #expect(PortfolioEngine.positions(ledger)[btc.id]!.averageEntry == 250)
        ledger.remove(at: 1)
        #expect(PortfolioEngine.positions(ledger)[btc.id]!.quantity == 1)
    }
}

struct SummaryTests {
    let txs = [tx(.buy, "1", "100", "2024-01-01"), tx(.buy, "10", "10", "2024-01-01", asset: "cg:ethereum")]

    @Test func totalsUnrealizedAndReturn() {
        let s = PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: [btc.id: quote("150"), eth.id: quote("5")])
        #expect(s.totalValue == 200)
        #expect(s.costBasis == 200)
        #expect(s.unrealized == 0)
        #expect(s.returnPct == 0)
        #expect(s.positions.first?.asset.id == btc.id)     // sorted by value
        #expect(s.best?.symbol == "BTC" && s.best!.value == 50)
        #expect(s.worst?.symbol == "ETH" && s.worst!.value == -50)
    }

    @Test func missingQuoteIsNotZero() {
        let s = PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: [btc.id: quote("150")])
        #expect(s.isPartial)
        #expect(s.valuation(eth.id)?.value == nil)
        #expect(Fmt().money(s.valuation(eth.id)?.value) == "$—")
    }

    /// The 24h driver is the biggest absolute contributor, not the biggest % mover.
    @Test func driverIsLargestAbsoluteContribution() {
        // BTC +2% on a 150 position = +2.94; ETH +10% on a 5·10=50 position = +4.55; ETH wins.
        // Then flip sizes so BTC wins despite the smaller %.
        let q1: [AssetID: Quote] = [btc.id: quote("150", ch24: 2), eth.id: quote("5", ch24: 10)]
        let s1 = PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: q1)
        #expect(s1.driver?.valuation.asset.symbol == "ETH")
        let q2: [AssetID: Quote] = [btc.id: quote("1500", ch24: 2), eth.id: quote("5", ch24: 10)]
        let s2 = PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: q2)
        #expect(s2.driver?.valuation.asset.symbol == "BTC")
        #expect(s2.best24?.symbol == "ETH")
    }

    @Test func portfolio24hChangeMatchesSumOfContributions() {
        let q: [AssetID: Quote] = [btc.id: quote("102", ch24: 2), eth.id: quote("9", ch24: -10)]
        let s = PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: q)
        // BTC: 102 − 100 = 2; ETH: 90 − 100 = −10
        #expect(abs(s.change24h!.double - -8) < 1e-9)
        #expect(abs(s.change24hPct! - (-8.0 / 200 * 100)) < 1e-9)
    }

    @Test func intradayBuyIsNotCountedAsGain() {
        let now = Date()
        let ledger = [tx(.buy, "1", "100", "2024-01-01"),
                      Transaction(assetID: btc.id, type: .buy, quantity: 1, price: 100, timestamp: now.addingTimeInterval(-3600))]
        let s = PortfolioEngine.summarize(transactions: ledger, assets: assets, quotes: [btc.id: quote("100", ch24: 0)], now: now)
        #expect(s.change24h == 0)                         // value doubled, but only through a deposit
    }

    @Test func demoLedgerReproducesPrototypeFigures() async throws {
        let q = try await MockMarketDataProvider().quotes(for: MockMarketDataProvider.assets, currency: "USD")
        let a = Dictionary(uniqueKeysWithValues: MockMarketDataProvider.assets.map { ($0.id, $0) })
        let s = PortfolioEngine.summarize(transactions: DemoPortfolio.transactions(), assets: a, quotes: q)
        let f = Fmt()
        #expect(f.money(s.totalValue) == "$48,147.77")
        #expect(f.signed(s.unrealized) == "+$10,696.22")
        #expect(f.money(s.costBasis) == "$37,451.56")
        #expect(s.driver?.valuation.asset.symbol == "SOL")
        #expect(f.num(s.driver!.share, 1) == "60.0")
        #expect(f.pct(s.change24hPct) == "+2.40%")
    }
}

struct HistoryTests {
    @Test func reconstructionUsesHoldingsAtEachTime() {
        let s = PriceSeries([PricePoint(time: day("2025-01-01"), price: 100), PricePoint(time: day("2025-01-31"), price: 100)])
        let ledger = [tx(.buy, "1", "100", "2025-01-10"), tx(.buy, "1", "100", "2025-01-20")]
        let grid = [day("2025-01-05"), day("2025-01-15"), day("2025-01-25")]
        let pts = PortfolioHistoryEngine.reconstruct(transactions: ledger, grid: grid, series: [btc.id: s])
        #expect(pts.map(\.value) == [0, 100, 200])      // not 200 everywhere
        #expect(pts.map(\.cost) == [0, 100, 200])
    }

    @Test func missingPriceYieldsGapNotZero() {
        let ledger = [tx(.buy, "1", "100", "2025-01-01")]
        let pts = PortfolioHistoryEngine.reconstruct(transactions: ledger, grid: [day("2025-01-05")], series: [:])
        #expect(pts.first?.value == nil)
    }

    @Test func interpolatesBetweenPoints() {
        let s = PriceSeries([PricePoint(time: Date(timeIntervalSince1970: 0), price: 100), PricePoint(time: Date(timeIntervalSince1970: 100), price: 200)])
        #expect(s.price(at: Date(timeIntervalSince1970: 50)) == 150)
        #expect(s.price(at: Date(timeIntervalSince1970: -10)) == nil)
    }

    @Test func pnlAndTWRIgnoreDeposits() {
        // Price flat at 100, a second buy doubles the value: no gain, index stays at 1.
        let s = PriceSeries([PricePoint(time: day("2025-01-01"), price: 100), PricePoint(time: day("2025-02-01"), price: 100)])
        let ledger = [tx(.buy, "1", "100", "2025-01-02"), tx(.buy, "1", "100", "2025-01-10")]
        let pts = PortfolioHistoryEngine.reconstruct(transactions: ledger, grid: [day("2025-01-05"), day("2025-01-15")], series: [btc.id: s])
        #expect(pts.map(\.value) == [100, 200])
        #expect(pts.map(\.pnl) == [0, 0])
        #expect(PortfolioHistoryEngine.twrIndex(pts) == [1, 1])
    }

    @Test func twrCapturesDrawdownDespiteNewMoney() {
        // Price halves, then more is bought: value goes up, but performance is −50%.
        let s = PriceSeries([PricePoint(time: day("2025-01-01"), price: 100), PricePoint(time: day("2025-01-10"), price: 50),
                             PricePoint(time: day("2025-02-01"), price: 50)])
        let ledger = [tx(.buy, "1", "100", "2025-01-01"), tx(.buy, "10", "50", "2025-01-12")]
        let grid = [day("2025-01-02"), day("2025-01-11"), day("2025-01-20")]
        let pts = PortfolioHistoryEngine.reconstruct(transactions: ledger, grid: grid, series: [btc.id: s])
        let twr = PortfolioHistoryEngine.twrIndex(pts)
        #expect(pts.last?.value == 550)                                   // value rose via the deposit
        #expect(abs(twr.last! - twr[0] * 50 / pts[0].value!) < 1e-9)      // but the index halved
        #expect(pts.last?.pnl.map { abs($0 - -50) < 1e-9 } == true)
        #expect(PortfolioHistoryEngine.drawdown(twr).max < -0.4)
        // Money-weighted: −$~44 on (~$94 start value + $500 new capital) ≈ −7.5%, not −50%.
        let mw = PortfolioHistoryEngine.moneyWeightedReturn(from: pts[0], to: pts[2])!
        #expect(mw < 0 && mw > -10)
    }

    @Test func drawdownFromPeak() {
        let dd = PortfolioHistoryEngine.drawdown([100, 120, 90, 110, 60, 130])
        #expect(abs(dd.max - -0.5) < 1e-12)
        #expect(dd.maxIndex == 4)
        #expect(dd.current == 0)
    }
}

struct ScenarioTests {
    @Test func targetScenario() {
        let s = ScenarioEngine.evaluate(target: d("0.1"), quantity: 3_435_000, costBasis: d("6386.85"), currentPrice: d("0.00431"),
                                        portfolioTotal: d("48286.22"), circulatingSupply: d("91400000000"), ath: d("0.0636"))
        #expect(s.positionValue == 343_500)
        #expect(s.profit == d("337113.15"))
        #expect(Fmt().num(s.multiple!, 2) == "53.78")
        #expect(Fmt().num(s.returnPct!, 1) == "5,278.2")
        #expect(s.impliedMarketCap == 9_140_000_000)
        #expect(Fmt().num(s.vsATH!, 2) == "1.57")
        #expect(Fmt().money(s.portfolioValue, 0) == "$376,981")
    }

    @Test func noImpliedMarketCapWithoutSupply() {
        let s = ScenarioEngine.evaluate(target: 2, quantity: 1, costBasis: 1, currentPrice: 1, portfolioTotal: 1, circulatingSupply: nil, ath: nil)
        #expect(s.impliedMarketCap == nil)
        #expect(s.multiple == 2)
    }

    @Test func presetsAreAboveCurrentAndIncreasing() {
        for p in [d("0.00431"), d("91420"), d("3840"), d("1")] {
            let ps = ScenarioEngine.presets(for: p)
            #expect(ps.count >= 3)
            #expect(ps.allSatisfy { $0 > p })
            #expect(zip(ps, ps.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test func targetInputForms() {
        #expect(NumberInput.target("0.1", current: 1) == d("0.1"))
        #expect(NumberInput.target(".1", current: 1) == d("0.1"))
        #expect(NumberInput.target("$0.10", current: 1) == d("0.1"))
        #expect(NumberInput.target("150k", current: 1) == 150_000)
        #expect(NumberInput.target("25x", current: 2) == 50)
        #expect(NumberInput.target("abc", current: 2) == nil)
        #expect(NumberInput.parse("-5") == nil)
        // "1.234,56" number style: comma is the decimal separator, dots group.
        #expect(NumberInput.parse("0,10", style: .dot) == d("0.1"))
        #expect(NumberInput.parse("500.000,00", style: .dot) == 500_000)
        #expect(NumberInput.parse("1.234.567", style: .dot) == 1_234_567)
        #expect(NumberInput.parse("0.1", style: .dot) == d("0.1"))
        #expect(NumberInput.parse("1,234.5", style: .comma) == d("1234.5"))
    }
}
