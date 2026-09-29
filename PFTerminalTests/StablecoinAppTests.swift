import PFCore
import Foundation
import Testing
@testable import PFTerminal

/// App wiring for stablecoins: valuation, polling cadence and freshness all come from PFCore.
@MainActor
struct StablecoinAppTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
    private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!

    private func store(usdcQuoteAge: TimeInterval, usdcPrice: String = "0.9998") -> AppStore {
        var o = AppStore.Options()
        o.directory = nil; o.inMemory = true; o.mockMarket = true; o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf-stable-\(UUID().uuidString)")!
        let s = AppStore(o)   // not started: no providers, no network
        s.createEmpty()
        let pf = s.doc.portfolios[0].id, day = Date().addingTimeInterval(-86400 * 10)
        s.doc.assets = [btc, usdc]
        s.doc.transactions = [
            Transaction(portfolioID: pf, assetID: btc.id, type: .buy, quantity: 1, price: 50000, timestamp: day),
            Transaction(portfolioID: pf, assetID: usdc.id, type: .buy, quantity: 10000, price: 1, timestamp: day),
        ]
        s.quotes = [
            btc.id: Quote(price: 60000, change: [.h24: 1], source: "CoinGecko", timestamp: Date()),
            usdc.id: Quote(price: Decimal(string: usdcPrice)!, change: [.h24: -0.02], source: "CoinGecko", timestamp: Date().addingTimeInterval(-usdcQuoteAge)),
        ]
        s.recompute()
        return s
    }

    @Test func totalsUseThePegAndMenuBarAgrees() {
        let s = store(usdcQuoteAge: 30)
        #expect(s.summary.totalValue == 70000)
        #expect(s.summary.positions.first { $0.asset.id == usdc.id }?.price == 1)
        #expect(s.quotes[usdc.id]?.price == Decimal(string: "0.9998"), "raw market quote kept for the peg panel")
        #expect(s.pegCheck(usdc.id)?.status == .normal)
        #expect(s.trayText().contains("70"), "menu bar total reads the same summary")
    }

    @Test func freshPegCheckSkipsTheRefreshAndDoesNotMakeThePortfolioStale() {
        let s = store(usdcQuoteAge: 60)
        #expect(!s.trackedAssets.contains { $0.id == usdc.id }, "checked a minute ago: not re-polled")
        #expect(s.trackedAssets.contains { $0.id == btc.id })
        #expect(s.marketDrivenHeld == [btc.id])
    }

    @Test func pegIsRecheckedAfterTheInterval() {
        let s = store(usdcQuoteAge: Stablecoins.checkInterval + 1)
        #expect(s.trackedAssets.contains { $0.id == usdc.id })
    }

    @Test func depegIsPolledAndCountsAsMarketDriven() {
        let s = store(usdcQuoteAge: 60, usdcPrice: "0.97")
        #expect(s.summary.totalValue == 69700)
        #expect(s.trackedAssets.contains { $0.id == usdc.id })
        #expect(s.marketDrivenHeld.contains(usdc.id))
        #expect(s.pegCheck(usdc.id)?.status == .depeg)
    }
}
