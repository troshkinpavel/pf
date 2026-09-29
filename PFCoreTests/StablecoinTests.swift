import Foundation
import Testing
import PFCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!
private let usdt = AssetCatalog.known.first { $0.symbol == "USDT" }!

private func q(_ p: String, ch: Double = 0.03, at: Date = t0) -> Quote {
    Quote(price: Decimal(string: p)!, change: [.h24: ch], source: "CoinGecko", timestamp: at)
}
private func buy(_ a: Asset, _ qty: Decimal, _ price: Decimal) -> Transaction {
    Transaction(assetID: a.id, type: .buy, quantity: qty, price: price, timestamp: t0.addingTimeInterval(-86400 * 30))
}
private func value(_ id: AssetID, _ quote: Quote?, currency: String = "USD") -> Decimal? {
    Stablecoins.valuationQuotes(quote.map { [id: $0] } ?? [:], assets: [id], currency: currency, now: t0)[id]?.price
}

struct StablecoinModelTests {
    @Test func whitelistCarriesPegMetadata() {
        for sym in ["USDT", "USDC", "DAI", "USDS", "FDUSD", "PYUSD"] {
            let a = AssetCatalog.known.first { $0.symbol == sym }
            #expect(a?.isStablecoin == true, "\(sym)")
            #expect(a?.pegCurrency == "USD" && a?.targetPeg == 1, "\(sym)")
        }
        #expect(!btc.isStablecoin && btc.stablecoinPeg == nil)
        #expect(Stablecoins.tolerance == Decimal(string: "0.005"))
    }
}

struct StablecoinValuationTests {
    @Test func slightlyBelowPegIsValuedAtOne() {
        #expect(value(usdc.id, q("0.9998")) == 1)
        #expect(Stablecoins.check(usdc.id, quote: q("0.9998"), currency: "USD")?.status == .normal)
    }

    @Test func slightlyAbovePegIsValuedAtOne() {
        #expect(value(usdt.id, q("1.002")) == 1)
    }

    @Test func toleranceEdgeIsInclusive() {
        #expect(value(usdc.id, q("0.995")) == 1)
        #expect(value(usdc.id, q("1.005")) == 1)
    }

    @Test func depegBelowUsesMarketPrice() {
        #expect(value(usdc.id, q("0.97")) == Decimal(string: "0.97"))
        let c = Stablecoins.check(usdc.id, quote: q("0.97"), currency: "USD")
        #expect(c?.status == .depeg && c?.valuationPrice == Decimal(string: "0.97"))
        #expect(abs((c?.deviationPercent ?? 0) + 3) < 1e-9)
    }

    @Test func depegAboveUsesMarketPrice() {
        #expect(value(usdt.id, q("1.02")) == Decimal(string: "1.02"))
        #expect(Stablecoins.check(usdt.id, quote: q("1.0051"), currency: "USD")?.status == .depeg)
    }

    @Test func healthyPegHasNoDailyChange() {
        let v = Stablecoins.valuationQuotes([usdc.id: q("0.9998", ch: -0.04)], assets: [usdc.id], currency: "USD")
        #expect(v[usdc.id]?.change24h == 0)
        let d = Stablecoins.valuationQuotes([usdc.id: q("0.97", ch: -3)], assets: [usdc.id], currency: "USD")
        #expect(d[usdc.id]?.change24h == -3, "a depeg keeps its real move")
    }

    @Test func noQuoteYetIsValuedAtPegAndMarkedUnchecked() {
        #expect(value(usdc.id, nil) == 1)
        let c = Stablecoins.check(usdc.id, quote: nil, currency: "USD")
        #expect(c?.status == .unchecked && c?.market == nil && c?.checkedAt == nil)
    }

    @Test func lastKnownStateSurvivesProviderFailure() {
        // Providers fail → the cached quote stays. An old depeg stays a depeg; an old healthy
        // check keeps the peg and is due for a re-check.
        let old = t0.addingTimeInterval(-3600)
        #expect(value(usdc.id, q("0.96", at: old)) == Decimal(string: "0.96"))
        #expect(value(usdc.id, q("1.0001", at: old)) == 1)
        #expect(Stablecoins.needsMarketCheck(usdc.id, quote: q("1.0001", at: old), currency: "USD", now: t0))
        #expect(!Stablecoins.needsMarketCheck(usdc.id, quote: q("1.0001", at: t0.addingTimeInterval(-60)), currency: "USD", now: t0))
        #expect(Stablecoins.needsMarketCheck(usdc.id, quote: q("0.96", at: t0), currency: "USD", now: t0), "a depeg is polled normally")
        #expect(Stablecoins.needsMarketCheck(usdc.id, quote: nil, currency: "USD", now: t0))
        #expect(Stablecoins.needsMarketCheck(btc.id, quote: q("60000", at: t0), currency: "USD", now: t0), "others unchanged")
    }

    @Test func otherLedgerCurrenciesUseTheMarketPrice() {
        #expect(value(usdc.id, q("0.92"), currency: "EUR") == Decimal(string: "0.92"))
        #expect(Stablecoins.check(usdc.id, quote: q("0.92"), currency: "EUR") == nil)
    }

    @Test func nonStableAssetsAreUnchanged() {
        let quotes = [btc.id: q("60123.45", ch: 2.5)]
        #expect(Stablecoins.valuationQuotes(quotes, assets: [btc.id], currency: "USD") == quotes)
    }

    @Test func seriesFlattensNoiseButKeepsRealDepegs() {
        let pts = [PricePoint(time: t0, price: 0.9991), PricePoint(time: t0.addingTimeInterval(60), price: 0.87),
                   PricePoint(time: t0.addingTimeInterval(120), price: 1.004)]
        let s = Stablecoins.valuationSeries(PriceSeries(pts), for: usdc.id, currency: "USD")
        #expect(s.points.map(\.price) == [1, 0.87, 1])
        let b = PriceSeries([PricePoint(time: t0, price: 0.9991)])
        #expect(Stablecoins.valuationSeries(b, for: btc.id, currency: "USD") == b)
    }
}

struct StablecoinPortfolioTests {
    private func summary(_ txs: [Transaction], _ quotes: [AssetID: Quote]) -> PortfolioSummary {
        let assets = Dictionary(uniqueKeysWithValues: [btc, usdc, usdt].map { ($0.id, $0) })
        let vq = Stablecoins.valuationQuotes(quotes, assets: Array(assets.keys), currency: "USD", now: t0)
        return PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: vq, now: t0)
    }

    @Test func mixedBTCAndStablecoinTotal() {
        let s = summary([buy(btc, 1, 50000), buy(usdc, 10000, Decimal(string: "0.9998")!)],
                        [btc.id: q("60000"), usdc.id: q("0.9997")])
        #expect(s.totalValue == 70000, "BTC 60,000 + USDC 10,000 at peg")
        #expect(s.unpriced.isEmpty && !s.isPartial)
        let st = s.positions.first { $0.asset.id == usdc.id }!
        #expect(st.value == 10000 && st.position.costBasis == Decimal(string: "9998"), "cost basis preserved")
        #expect(abs((st.allocation ?? 0) - 100.0 / 7) < 1e-9)
    }

    @Test func stablecoinAtPegAddsNo24hMove() {
        let s = summary([buy(usdc, 10000, 1)], [usdc.id: q("0.9990", ch: -0.09)])
        #expect(s.change24h == 0)
    }

    @Test func depegFlowsIntoTheTotal() {
        let s = summary([buy(btc, 1, 50000), buy(usdc, 10000, 1)], [btc.id: q("60000"), usdc.id: q("0.97")])
        #expect(s.totalValue == 69700)
    }

    @Test func partialTotalsStayCorrect() {
        // BTC has no quote (unpriced); USDC has none either but is valued at its peg.
        let s = summary([buy(btc, 1, 50000), buy(usdc, 5000, 1)], [:])
        #expect(s.totalValue == 5000)
        #expect(s.unpriced == [btc.id] && s.isPartial)
    }

    @Test func stablecoinsAreNotRankedAsInvestments() {
        let eth = AssetCatalog.known.first { $0.symbol == "ETH" }!
        let assets = Dictionary(uniqueKeysWithValues: [btc, eth, usdc].map { ($0.id, $0) })
        let txs = [buy(btc, 1, 50000), buy(eth, 1, 2000), buy(usdc, 1000, 1)]
        let vq = Stablecoins.valuationQuotes([btc.id: q("60000", ch: 2), eth.id: q("2100", ch: 1), usdc.id: q("0.9999")],
                                             assets: Array(assets.keys), currency: "USD", now: t0)
        let s = PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: vq, now: t0)
        #expect(s.best?.symbol == "BTC" && s.worst?.symbol == "ETH", "USDC's 0% isn't the worst investment")
        #expect(s.worst24?.symbol == "ETH")
    }

    @Test func flatHistoryForAPegWithoutSeries() {
        let f = Stablecoins.flatSeries(.usd, until: t0)
        #expect(f.price(at: t0.addingTimeInterval(-86400 * 400)) == 1 && f.price(at: t0) == 1)
    }

    @Test func widgetSnapshotUsesTheSameValuation() {
        let s = summary([buy(btc, 1, 50000), buy(usdc, 10000, 1)], [btc.id: q("60000"), usdc.id: q("1.001")])
        let snap = WidgetSnapshotBuilder.build(.init(
            summary: s, movers24h: [], performance: [], performanceStart: t0, performanceRange: "24H", hasPortfolio: true,
            refreshInterval: 60, isStale: false, privacy: .full, currency: "USD", numberStyle: .comma, now: t0))
        #expect(snap.portfolioValue == 70000)
        #expect(snap.positions.first { $0.symbol == "USDC" }?.value == 10000)
    }
}
