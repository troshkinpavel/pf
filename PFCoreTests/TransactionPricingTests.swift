import Foundation
import Testing
import PFCore

// Blank prices are filled only from a price for the right moment, and the preview says so.

private let btc = Asset(id: "cg:bitcoin", symbol: "BTC", name: "Bitcoin", coingeckoID: "bitcoin")
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let today = DateFmt.ymd(now)
private let past = DateFmt.ymd(now.addingTimeInterval(-40 * 86400))

private func setup() -> (PortfolioDocument, UUID, UUID) {
    var d = PortfolioDocument.fresh(now: now.addingTimeInterval(-400 * 86400))
    let a = d.portfolios[0].id
    let b = try! d.createPortfolio(name: "cold", glyph: "◇").id
    d.assets = [btc]
    d.transactions = [Transaction(portfolioID: a, assetID: btc.id, type: .buy, quantity: 2, price: 100, timestamp: now.addingTimeInterval(-300 * 86400))]
    return (d, a, b)
}
private func preview(_ d: TxDraft, _ doc: PortfolioDocument) -> TxPreview {
    TransactionPlanner.preview(d, doc: doc, quotes: [btc.id: Quote(price: 60_000, source: "t", timestamp: now)], currency: "USD",
                               resolve: { s, _ in s == "BTC" ? btc : nil }, now: now, fmt: Fmt(style: .comma, currency: "USD"))
}

struct TransactionPricingTests {
    @Test func todayBlankUsesMarketAndSaysSo() {
        let (doc, a, _) = setup()
        let p = preview(TxDraft(portfolioID: a, type: .buy, asset: "BTC", amount: "1", date: today), doc)
        #expect(p.ok && p.tx?.price == 60_000)
        #expect(p.rows.contains { $0.v.contains("auto · market now") })
    }

    @Test func backdatedBlankNeverUsesTodaysPrice() {
        let (doc, a, _) = setup()
        var d = TxDraft(portfolioID: a, type: .buy, asset: "BTC", amount: "1", date: past)
        #expect(!preview(d, doc).ok && preview(d, doc).error?.contains("no price found") == true)
        d.loadingHistorical = true
        #expect(preview(d, doc).error?.contains("loading") == true)
        d.loadingHistorical = false
        d.historicalPrice = 41_000; d.historicalKey = TxDraft.historicalKey(btc.id, past)
        let p = preview(d, doc)
        #expect(p.ok && p.tx?.price == 41_000)
        #expect(p.rows.contains { $0.v.contains("auto · close \(past)") })
        d.date = DateFmt.ymd(now.addingTimeInterval(-41 * 86400))       // date changed: old lookup no longer applies
        #expect(!preview(d, doc).ok)
        d.price = "39000"
        #expect(preview(d, doc).tx?.price == 39_000, "an entered price always wins")
    }

    @Test func backdatedSellNeedsAHistoricalPriceToo() {
        let (doc, a, _) = setup()
        #expect(!preview(TxDraft(portfolioID: a, type: .sell, asset: "BTC", amount: "1", date: past), doc).ok)
    }

    @Test func transferInWithoutCostBasisIsNotInvented() {
        let (doc, _, b) = setup()
        let blank = preview(TxDraft(portfolioID: b, type: .transferIn, asset: "BTC", amount: "1", date: today), doc)
        #expect(!blank.ok && blank.error?.contains("cost per unit") == true)
        let zero = preview(TxDraft(portfolioID: b, type: .transferIn, asset: "BTC", amount: "1", price: "0", date: today), doc)
        #expect(zero.ok && zero.tx?.price == 0, "an explicit 0 is a confirmed choice")
        let given = preview(TxDraft(portfolioID: b, type: .transferIn, asset: "BTC", amount: "1", price: "250", date: today), doc)
        #expect(given.tx?.price == 250)
    }

    @Test func transferInLinksToTheMatchingTransferOut() {
        var (doc, a, b) = setup()
        doc.transactions.append(Transaction(portfolioID: a, assetID: btc.id, type: .transferOut, quantity: 1, price: 0, timestamp: now.addingTimeInterval(-3600)))
        let p = preview(TxDraft(portfolioID: b, type: .transferIn, asset: "BTC", amount: "1", date: today), doc)
        #expect(p.ok && p.tx?.price == 100, "the source's average entry, not today's 60,000")
        #expect(p.rows.contains { $0.k == "linked" })
        // A different amount is not the same move.
        #expect(!preview(TxDraft(portfolioID: b, type: .transferIn, asset: "BTC", amount: "0.5", date: today), doc).ok)
    }

    @Test func transferOutBlankStoresNoInventedPrice() {
        let (doc, a, _) = setup()
        let p = preview(TxDraft(portfolioID: a, type: .transferOut, asset: "BTC", amount: "1", date: past), doc)
        #expect(p.ok && p.tx?.price == 0)
    }
}
