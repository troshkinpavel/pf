import Foundation
import Testing
import PFCore

private let btc = Asset(id: "cg:bitcoin", symbol: "BTC", name: "Bitcoin", coingeckoID: "bitcoin")
private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!
private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
private func doc(_ n: Int = 3) -> PortfolioDocument {
    var d = PortfolioDocument.fresh(now: t0)
    d.assets = [btc]
    d.transactions = (0..<n).map { Transaction(portfolioID: d.portfolios[0].id, assetID: btc.id, type: .buy, quantity: Decimal($0 + 1), price: 100, timestamp: t0.addingTimeInterval(Double($0) * 3600)) }
    d.settings = AppSettings()
    return d
}
private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pf-snap-\(UUID().uuidString)") }

struct SnapshotStoreTests {
    @Test func createVerifiesAndExcludesSettings() throws {
        let s = SnapshotStore(directory: tmp())
        let d = doc()
        let info = try s.create(d, reason: .beforeImport, now: t0)
        #expect(info.isSafety && info.transactions == 3 && info.portfolios == 1)
        let back = try s.load(info)
        #expect(back.transactions == d.transactions && back.settings == nil, "settings never go into a snapshot")
        let raw = try String(contentsOf: info.url, encoding: .utf8)
        #expect(raw.contains("\"format\":\"pf-ledger-snapshot\"") && raw.contains("\"version\":1"))
        #expect(!raw.contains("refreshSeconds"))
    }

    @Test func rollingSnapshotSkipsUnchangedLedger() throws {
        let s = SnapshotStore(directory: tmp())
        var d = doc()
        #expect(try s.snapshotIfChanged(d, now: t0) != nil)
        #expect(try s.snapshotIfChanged(d, now: t0.addingTimeInterval(60)) == nil, "same ledger: no new file")
        d.transactions[0].note = "edited"
        #expect(try s.snapshotIfChanged(d, now: t0.addingTimeInterval(120)) != nil)
        #expect(try s.snapshotIfChanged(.fresh(), now: t0.addingTimeInterval(180)) == nil, "an empty ledger isn't worth a snapshot")
    }

    @Test func retentionIsBounded() throws {
        let s = SnapshotStore(directory: tmp(), policy: .init(recent: 3, days: 5, safety: 2))
        var d = doc()
        for i in 0..<40 {   // 40 edits over 20 days, two a day
            d.transactions[0].note = "\(i)"
            try s.create(d, reason: i % 10 == 0 ? .beforeRestore : .auto, now: t0.addingTimeInterval(Double(i) * 43200))
        }
        let all = s.list()
        #expect(all.filter(\.isSafety).count == 2)
        #expect(all.filter { !$0.isSafety }.count <= 3 + 5)
        #expect(all.first?.createdAt == t0.addingTimeInterval(39 * 43200), "newest kept")
    }

    @Test func refusesUnknownOrNewerFormats() throws {
        let dir = tmp(), s = SnapshotStore(directory: dir)
        try s.create(doc(), reason: .auto, now: t0)
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data(#"{"format":"pf-ledger-snapshot","version":99}"#.utf8).write(to: s.directory.appendingPathComponent("pf-99999999-000000-auto.json"))
        try Data("garbage".utf8).write(to: s.directory.appendingPathComponent("pf-00000000-000000-auto.json"))
        #expect(s.list().count == 1, "unreadable and newer files are not offered")
    }
}

struct ImportPlannerTests {
    @Test func classifiesReadyDuplicateReviewInvalid() {
        let d = doc(2)
        let pid = d.portfolios[0].id
        let existing = d.transactions[0]
        var copy = existing; copy.id = UUID()                                   // identical trade, new id → duplicate
        var sameRecord = d.transactions[1]                                      // same id → duplicate (same record)
        sameRecord.note = nil
        var nearly = existing; nearly.id = UUID(); nearly.price = 101           // same day/amount, other price → review
        var fresh = existing; fresh.id = UUID(); fresh.timestamp = t0.addingTimeInterval(9 * 86400); fresh.quantity = 7
        var twice = fresh; twice.id = UUID()                                    // repeated within the file → review
        var bad = fresh; bad.id = UUID(); bad.quantity = 0
        var unknown = fresh; unknown.id = UUID(); unknown.assetID = "cg:nope"
        var oversell = fresh; oversell.id = UUID(); oversell.type = .sell; oversell.quantity = 1000; oversell.timestamp = t0.addingTimeInterval(20 * 86400)
        let plan = ImportPlanner.plan([copy, sameRecord, nearly, fresh, twice, bad, unknown, oversell], into: pid, doc: d, knownAssets: [btc.id])
        let st = plan.items.map(\.status)
        #expect(st == [.duplicate, .duplicate, .review, .ready, .review, .invalid, .invalid, .invalid])
        #expect(plan.count(.ready) == 1 && plan.count(.duplicate) == 2 && plan.count(.review) == 2 && plan.count(.invalid) == 3)
        #expect(plan.items.allSatisfy { $0.tx.portfolioID == pid })
    }

    @Test func identicalTradeInAnotherPortfolioNeedsReview() throws {
        var d = doc(1)
        let other = try d.createPortfolio(name: "two", glyph: "◇").id
        var t = d.transactions[0]; t.id = UUID()
        let plan = ImportPlanner.plan([t], into: other, doc: d, knownAssets: [btc.id])
        #expect(plan.items[0].status == .review && plan.items[0].reason.contains("MAIN"))
    }

    @Test func differentNotesAreReviewedNotDropped() {
        var d = doc(1); d.transactions[0].note = "kraken"
        var t = d.transactions[0]; t.id = UUID(); t.note = "binance"
        #expect(ImportPlanner.plan([t], into: d.portfolios[0].id, doc: d, knownAssets: [btc.id]).items[0].status == .review)
    }

    @Test func likelyDuplicatesInLedger() {
        var d = doc(2)
        var c = d.transactions[1]; c.id = UUID()
        d.transactions.append(c)
        #expect(ImportPlanner.likelyDuplicates(in: d).map(\.count) == [2])
    }
}

struct DepegAndHealthTests {
    private func check(_ price: String) -> PegCheck { Stablecoins.check(usdc.id, quote: Quote(price: Decimal(string: price)!, source: "t", timestamp: t0), currency: "USD")! }

    @Test func depegNotifiesOncePerEventWithHysteresis() {
        var alerted = Set<AssetID>()
        #expect(Stablecoins.depegTransitions([usdc.id: check("0.999")], alerted: &alerted).isEmpty)
        #expect(Stablecoins.depegTransitions([usdc.id: check("0.990")], alerted: &alerted) == [usdc.id])
        #expect(Stablecoins.depegTransitions([usdc.id: check("0.985")], alerted: &alerted).isEmpty, "still depegged: no repeat")
        #expect(Stablecoins.depegTransitions([usdc.id: check("0.996")], alerted: &alerted).isEmpty, "back inside the band but near the edge: stays armed off")
        #expect(Stablecoins.depegTransitions([usdc.id: check("0.990")], alerted: &alerted).isEmpty, "flapping at the edge doesn't spam")
        #expect(Stablecoins.depegTransitions([usdc.id: check("0.9995")], alerted: &alerted).isEmpty)
        #expect(alerted.isEmpty, "recovered: re-armed")
        #expect(Stablecoins.depegTransitions([usdc.id: check("1.02")], alerted: &alerted) == [usdc.id], "a new event notifies again")
        #expect(Stablecoins.depegTransitions([:], alerted: &alerted).isEmpty && alerted.isEmpty, "no longer held: forgotten")
    }

    @Test func healthFindsProblemsWithoutChangingData() {
        var d = doc(2)
        var c = d.transactions[1]; c.id = UUID(); d.transactions.append(c)
        let before = d
        var st = SyncState(); st.mode = .iCloud; st.lastSync = t0
        let f = DataHealth.check(.init(doc: d, quotes: [:], marketDriven: [btc.id], now: t0.addingTimeInterval(3600), sync: st, latestSnapshot: nil))
        #expect(d == before)
        #expect(f.contains { $0.area == .duplicates && $0.asset == btc.id })
        #expect(f.contains { $0.area == .prices && $0.text.contains("no price · BTC") })
        #expect(f.contains { $0.area == .recovery && $0.level == .warning })
        #expect(f.contains { $0.area == .ledger && $0.level == .ok })
        #expect(f.contains { $0.area == .sync && $0.text == "sync healthy" })
        let ok = DataHealth.check(.init(doc: doc(1), quotes: [btc.id: Quote(price: 1, source: "t", timestamp: t0)], marketDriven: [btc.id], now: t0, latestSnapshot: t0))
        #expect(ok.allSatisfy { $0.level == .ok })
    }

    @Test func errorKindsCarryNoMessages() {
        #expect(DiagnosticLog.kind(SyncStoreError.unavailable("/Users/someone/secret portfolio")) == "unavailable")
        #expect(DiagnosticLog.kind(MarketError.rateLimited(retryAfter: 30)) == "rateLimited")
        #expect(DiagnosticLog.kind(PortfolioDocument.ImportError.invalid(["tx 1234: MY NOTE"])) == "invalid")
        struct Custom: Error { let path = "/Users/x" }
        #expect(DiagnosticLog.kind(Custom()) == "Custom")
    }
}
