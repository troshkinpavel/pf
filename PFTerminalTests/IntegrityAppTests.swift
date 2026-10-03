import PFCore
import Foundation
import Testing
@testable import PFTerminal

/// 0.6 "a ledger you can trust", through the real AppStore with throwaway storage.
@MainActor
struct IntegrityAppTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
    private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!

    private func store(_ dir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("pf-int-\(UUID().uuidString)")) -> AppStore {
        var o = AppStore.Options()
        o.directory = dir; o.inMemory = true; o.mockMarket = true; o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf-int-\(UUID().uuidString)")!
        let s = AppStore(o)
        s.createEmpty()
        return s
    }
    private func seed(_ s: AppStore, _ n: Int = 3, note: String? = nil) {
        let pf = s.doc.portfolios[0].id
        s.doc.assets = [btc]
        s.doc.transactions = (0..<n).map { Transaction(portfolioID: pf, assetID: btc.id, type: .buy, quantity: Decimal($0 + 1), price: 100,
                                                       timestamp: Date().addingTimeInterval(-Double(n - $0) * 86400), note: note) }
        s.save(); s.recompute()
    }

    // MARK: safety snapshots

    @Test func replaceImportTakesAVerifiedSnapshotFirst() throws {
        let s = store(); seed(s)
        let before = s.doc.transactions
        s.pendingImport = .fresh()
        s.applyImport()
        #expect(s.doc.transactions.isEmpty)
        let snap = try #require(s.snapshotList.first { $0.reason == "before-import" })
        #expect(try s.snapshots.load(snap).transactions.map(\.id) == before.map(\.id), "the replaced ledger is recoverable")
    }

    @Test func failedSnapshotAbortsTheDestructiveOperation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-int-\(UUID().uuidString)")
        let s = store(dir); seed(s)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("backups"))
        try Data("not a directory".utf8).write(to: dir.appendingPathComponent("backups"))   // snapshots can't be written
        let before = s.doc
        s.pendingImport = .fresh()
        s.applyImport()
        #expect(s.doc == before, "nothing replaced without a snapshot")
        #expect(s.message.contains("could not save a safety snapshot"))
        s.requestRemovePosition(btc.id)
        s.removePosition(btc.id, from: s.doc.portfolios[0].id)
        #expect(s.doc == before)
    }

    @Test func restoreRoundTripIsVerifiedAndUndoable() throws {
        let s = store(); seed(s, 2)
        s.rollingSnapshotNow()
        let good = s.doc.transactions
        s.doc.transactions.removeLast(); s.save(); s.recompute()       // a change worth undoing
        s.openRestore()
        let r = try #require(s.restore?.doc)
        #expect(s.restoreDiff(r).added == 1)
        s.confirmRestore()
        #expect(s.doc.transactions.map(\.id) == good.map(\.id) && s.message.contains("verified"))
        #expect(s.snapshotList.contains { $0.reason == "before-restore" }, "the state before the restore is kept too")
        #expect(try s.files.load()?.transactions == s.doc.transactions)
    }

    // MARK: import preview

    @Test func importIntoPortfolioSkipsDuplicatesAndAsksAboutReview() throws {
        let s = store(); seed(s, 2)
        let pf = s.doc.portfolios[0].id
        var src = PortfolioDocument.fresh()
        src.assets = [btc]
        var near = s.doc.transactions[0]; near.id = UUID(); near.price = 101
        var new = s.doc.transactions[0]; new.id = UUID(); new.timestamp = Date().addingTimeInterval(-3600); new.quantity = 9
        src.transactions = s.doc.transactions.map { var t = $0; t.id = UUID(); return t } + [near, new]
        s.previewImport(src, into: pf)
        let plan = try #require(s.importPreview?.plan)
        #expect(plan.count(.duplicate) == 2 && plan.count(.review) == 1 && plan.count(.ready) == 1)
        s.applyImportPreview(includeReview: false)
        #expect(s.doc.transactions.count == 3, "only the ready row was added")
        #expect(s.message.contains("3 skipped"))
    }

    // MARK: remove position

    @Test func removePositionIsALedgerOperationInOnePortfolio() throws {
        let s = store(); seed(s)
        let other = try s.doc.createPortfolio(name: "two", glyph: "◇").id
        s.doc.transactions.append(Transaction(portfolioID: other, assetID: btc.id, type: .buy, quantity: 1, price: 1, timestamp: Date().addingTimeInterval(-60)))
        s.save()
        s.setContext(.all)
        s.requestRemovePosition(btc.id)
        #expect(s.pendingRemovePosition == nil, "not from ALL")
        s.setContext(.portfolio(s.doc.portfolios[0].id))
        s.requestRemovePosition(btc.id)
        let r = try #require(s.pendingRemovePosition)
        s.removePosition(r.asset, from: r.portfolio)
        #expect(!s.doc.transactions.contains { $0.portfolioID == r.portfolio })
        #expect(s.doc.transactions.count == 1 && s.doc.assets.contains(btc), "the other portfolio keeps its BTC")
        #expect(s.snapshotList.contains { $0.reason == "before-remove-position" })
    }

    // MARK: privacy

    @Test func lockedMenuBarShowsNoAmounts() {
        let s = store(); seed(s)
        s.quotes = [btc.id: Quote(price: 123_456, source: "t", timestamp: Date())]; s.recompute()
        #expect(s.trayText().contains("PF  ") && s.trayText() != "PF  🔒")
        s.locked = true
        for f in MenuBarFormat.allCases { #expect(s.trayText(f) == "PF  🔒") }
    }

    @Test func lockLifecycleAndNoSilentEnable() {
        let s = store(); seed(s)
        s.lockIfEnabled("sleep")
        #expect(!s.locked, "lock off: nothing happens")
        s.settings.appLock = true
        // Either the Mac can authenticate (locks at once) or the toggle refuses: never "on" and open.
        #expect(s.settings.appLock ? s.locked : !s.locked)
        if s.settings.appLock {
            s.locked = false
            s.lockIfEnabled("sleep")
            #expect(s.locked)
        }
    }

    // MARK: diagnostics

    @Test func diagnosticReportCarriesNoPortfolioData() throws {
        let s = store()
        let secret = Asset(id: "cg:zqxsecret", symbol: "ZQXSECRET", name: "Secret Coin", coingeckoID: "zqxsecret")
        try s.doc.renamePortfolio(s.doc.portfolios[0].id, to: "MYSECRETPORTFOLIO")
        s.doc.assets = [secret]
        s.doc.transactions = [Transaction(portfolioID: s.doc.portfolios[0].id, assetID: secret.id, type: .buy, quantity: Decimal(string: "98765.4321")!,
                                          price: Decimal(string: "4242.17")!, timestamp: Date().addingTimeInterval(-86400), note: "MYPRIVATENOTE")]
        s.save()
        s.quotes = [secret.id: Quote(price: Decimal(string: "7777.31")!, source: "t", timestamp: Date())]; s.recompute()
        s.syncState.accountID = "_ACCOUNTID123"; s.syncState.deviceName = "Jane Doe's MacBook"
        s.syncState.lastRemoteChange = SyncDeviceStamp(device: "Jane Doe's iPhone", at: Date())
        s.syncStatus = .error("/Users/jane/Library/secret path")
        s.lastError = .unavailable(451)
        s.diagnostics.record(.sync, .error, "pass-failed", error: SyncStoreError.unavailable("/Users/jane/MYSECRETPORTFOLIO.json"))
        s.diagnostics.record(.ledger, .error, "save-failed", error: CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/jane/x"]))
        s.rollingSnapshotNow()
        let r = s.diagnosticReport()
        for leak in ["MYSECRETPORTFOLIO", "ZQXSECRET", "Secret Coin", "MYPRIVATENOTE", "98765", "98,765", "4242", "7777", "_ACCOUNTID123",
                     "Jane", "/Users", NSHomeDirectory(), s.files.directory.path, "zqxsecret"] {
            #expect(!r.contains(leak), "report leaks \(leak)")
        }
        let total = Fmt.current.money(s.summary.totalValue, 0)
        #expect(!r.contains(total.dropFirst()), "no portfolio value")
        #expect(r.contains("pass-failed · unavailable") && r.contains("RECOVERY") && r.contains("1–99"))
    }

    // MARK: stablecoins

    @Test func depegNotifiesOnceAndRearmsAfterRecovery() {
        let s = store()
        let pf = s.doc.portfolios[0].id
        s.doc.assets = [usdc]
        s.doc.transactions = [Transaction(portfolioID: pf, assetID: usdc.id, type: .buy, quantity: 100, price: 1, timestamp: Date().addingTimeInterval(-86400))]
        s.save(); s.recompute()
        s.settings.depegAlerts = true
        func price(_ p: String) { s.quotes[usdc.id] = Quote(price: Decimal(string: p)!, source: "t", timestamp: Date()); s.checkDepeg() }
        let alerted = { Set(s.defaults.stringArray(forKey: AppStore.depegKey) ?? []) }
        price("0.97"); #expect(alerted() == [usdc.id])
        let events = s.diagnostics.events.filter { $0.code == "depeg-notified" }.count
        price("0.96"); #expect(s.diagnostics.events.filter { $0.code == "depeg-notified" }.count == events, "no repeat while depegged")
        price("1.0001"); #expect(alerted().isEmpty, "re-armed after recovery")
    }

    // MARK: performance

    @Test func liveTicksAreCoalesced() async throws {
        let s = store(); seed(s)
        s.quotes = [btc.id: Quote(price: 100, source: "Binance", timestamp: Date())]; s.recompute()
        let v0 = s.summary.totalValue
        for p in [200, 300, 400] as [Decimal] { s.quotes[btc.id]?.price = p; s.scheduleTickRecompute() }   // what applyTick does per tick
        #expect(s.summary.totalValue == v0, "not recomputed per tick")
        try await Task.sleep(nanoseconds: UInt64((AppStore.tickRecomputeInterval + 0.2) * 1e9))
        #expect(s.summary.totalValue.double == 2400, "one recompute with the latest price")
    }

    // MARK: transactions

    @Test func backdatedDraftUsesCachedHistoryAndSaysSo() throws {
        let s = store(); seed(s)
        let day = Date().addingTimeInterval(-20 * 86400)
        s.series[s.seriesKey(btc.id, .y1)] = PriceSeries((0..<60).map { PricePoint(time: Date().addingTimeInterval(-Double($0) * 86400), price: 41_000) })
        s.openTx(TxDraft(portfolioID: s.doc.portfolios[0].id, type: .buy, asset: "BTC", amount: "1", date: DateFmt.ymd(day)))
        s.loadDraftHistoricalPrice()
        let p = s.preview(try #require(s.tx))
        #expect(p.ok && p.tx?.price == 41_000)
        #expect(p.rows.contains { $0.v.contains("auto · close") })
    }

    // MARK: health

    @Test func dataHealthReflectsRecoveryAndNeverChangesData() {
        let s = store(); seed(s)
        let before = s.doc
        #expect(s.dataHealth.contains { $0.area == .recovery && $0.level == .warning })
        s.rollingSnapshotNow()
        #expect(s.dataHealth.contains { $0.area == .recovery && $0.level == .ok })
        #expect(s.doc == before)
    }
}
