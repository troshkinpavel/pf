import PFCore
import PFCoreTestSupport
import Foundation
import Testing
@testable import PFTerminal

/// Locked Mac: the ledger keeps "complete" file protection, so it can be neither read nor written
/// until unlock. These tests simulate that with the same error macOS returns (`ledgerFault`) on
/// real files in a throwaway folder, with the in-memory CloudKit stand-in.
@MainActor
struct ProtectedDataTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
    private final class Lock { var on = false }

    private func store(_ dir: URL, _ lock: Lock, _ r: MockRemote? = nil) -> AppStore {
        var o = AppStore.Options()
        o.directory = dir
        o.inMemory = true; o.mockMarket = true; o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf.locked.\(UUID().uuidString)")!
        o.syncRemote = r
        o.ledgerFault = { lock.on ? ProtectedData.lockedError : nil }
        return AppStore(o)
    }
    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pf-locked-\(UUID().uuidString)") }
    private func buy(_ s: AppStore, _ q: Decimal) {
        s.doc.upsert(Transaction(portfolioID: s.doc.portfolios[0].id, assetID: btc.id, type: .buy, quantity: q, price: 60000,
                                 timestamp: PortfolioInfo.stamp(Date().addingTimeInterval(-3600))), asset: btc)
        s.save()
    }
    private func files(_ dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }

    @Test func classifiesTheLockedErrorOnly() {
        #expect(ProtectedData.isUnavailable(ProtectedData.lockedError))
        #expect(ProtectedData.isUnavailable(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        #expect(!ProtectedData.isUnavailable(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)))
        #expect(!ProtectedData.isUnavailable(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))))
    }

    @Test func lockedLaunchNeverQuarantinesReplacesOrOverwrites() throws {
        let dir = tempDir(), lock = Lock()
        let a = store(dir, lock)
        a.createEmpty(); buy(a, 1)
        let onDisk = try Data(contentsOf: a.files.fileURL)

        lock.on = true
        let b = store(dir, lock)
        #expect(b.ledgerLoadDeferred && b.protectedDataWaiting && !b.hasPortfolio)
        #expect(!files(dir).contains { $0.hasPrefix("portfolio.unreadable") }, "never set aside")
        b.createEmpty(); b.loadDemo(); b.save()
        #expect(try Data(contentsOf: b.files.fileURL) == onDisk, "nothing creates or writes a replacement ledger")
        #expect(b.health.text == "waiting for unlock" && b.messageSlot.text.contains("waiting for unlock"))

        lock.on = false
        b.resumeProtectedData()
        #expect(!b.protectedDataWaiting && b.hasPortfolio && b.doc.transactions.count == 1, "unlock loads the real ledger")
        #expect(try Data(contentsOf: b.files.fileURL) == onDisk)
    }

    @Test func lockedLaunchNeverPropagatesDeletions() async throws {
        let dir = tempDir(), lock = Lock(), r = MockRemote()
        let a = store(dir, lock, r)
        a.createEmpty(); buy(a, 1); buy(a, 2)
        try await SyncEngine.enable(a, remote: r, choice: .upload, deviceName: "Mac")
        #expect(await r.liveCount == (1, 2))

        lock.on = true
        let b = store(dir, lock, r)                               // same folder: sync state says iCloud
        #expect(b.syncEnabled && b.doc.transactions.isEmpty && b.ledgerLoadDeferred)
        b.scheduleSync()
        #expect(b.syncState.known.values.allSatisfy { $0.deletedAt == nil }, "an unread ledger is never diffed into deletions")
        await #expect(throws: SyncDeferredError.self) { try await SyncEngine.cycle(b, remote: r) }
        let live = await r.liveCount, saves = await r.saveCalls
        #expect(live == (1, 2) && saves == 1, "nothing uploaded, nothing deleted")

        lock.on = false
        b.resumeProtectedData()
        try await SyncEngine.cycle(b, remote: r)
        let after = await r.liveCount
        #expect(b.doc.transactions.count == 2 && after == (1, 2))
    }

    @Test func tokenNeverAdvancesPastAnUnsavedMerge() async throws {
        let dir = tempDir(), lock = Lock(), r = MockRemote()
        let mac = store(dir, lock, r)
        mac.createEmpty(); buy(mac, 1)
        try await SyncEngine.enable(mac, remote: r, choice: .upload, deviceName: "Mac")
        let token = mac.syncState.token
        let main = mac.doc.portfolios[0].id

        // Another device adds a transaction.
        let phone = Device("iPhone", PortfolioDocument(portfolios: []), clock: PortfolioInfo.stamp(Date()))
        try await phone.enable(r, .useCloud)
        phone.tick()
        let t = Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 3, price: 70000, timestamp: phone.clock)
        phone.doc.transactions.append(t)
        try await phone.sync(r)

        // The Mac locks; the next pass can't write the merge.
        lock.on = true
        await #expect(throws: SyncDeferredError.self) { try await SyncEngine.cycle(mac, remote: r) }
        #expect(mac.syncState.token == token, "token unchanged in memory")
        #expect(SyncStateFile.load(from: dir)?.token == token, "and on disk")
        #expect(!mac.doc.transactions.contains { $0.id == t.id }, "the unsaved merge is not kept as if it were on disk")
        #expect(mac.protectedDataWaiting || mac.pendingLedgerSave)

        // Unlock: the same change is fetched again and lands on disk before the token moves.
        lock.on = false
        mac.resumeProtectedData()
        try await SyncEngine.cycle(mac, remote: r)
        #expect(mac.doc.transactions.contains(t) && mac.syncState.token != token)
        let disk = try #require(try mac.files.load())
        #expect(disk.transactions.contains(t), "persisted locally")
        #expect(mac.syncState.conflicts.isEmpty, "no spurious conflicts from the deferred pass")
    }

    @Test func pendingSaveIsWrittenOnUnlockAndLoggedOnce() throws {
        let dir = tempDir(), lock = Lock()
        let s = store(dir, lock)
        s.createEmpty(); buy(s, 1)
        let before = try Data(contentsOf: s.files.fileURL)
        lock.on = true
        let events0 = s.diagnostics.events.count
        buy(s, 2); buy(s, 3); s.save()
        #expect(s.pendingLedgerSave && s.protectedDataWaiting)
        #expect(try Data(contentsOf: s.files.fileURL) == before)
        #expect(s.diagnostics.events.count == events0 + 1, "one event per episode, not per attempt")
        s.rollingSnapshotNow()
        #expect(s.snapshotList.isEmpty || s.snapshotList.allSatisfy { $0.transactions <= 1 }, "no snapshot while waiting")
        lock.on = false
        s.resumeProtectedData()
        #expect(!s.pendingLedgerSave && !s.protectedDataWaiting)
        #expect(try #require(try s.files.load()).transactions.count == 3)
    }

    @Test func unlockedBehaviourUnchanged() throws {
        let dir = tempDir(), lock = Lock()
        let s = store(dir, lock)
        s.createEmpty(); buy(s, 1)
        #expect(!s.protectedDataWaiting && !s.pendingLedgerSave && s.syncCanPersist)
        // A genuinely corrupt file is still set aside (0.6 behaviour).
        try Data("{not json".utf8).write(to: s.files.fileURL)
        let b = store(dir, lock)
        #expect(!b.ledgerLoadDeferred && !b.protectedDataWaiting)
        #expect(files(dir).contains { $0.hasPrefix("portfolio.unreadable") })
    }

    /// intel.json (watchlist, scenarios) locked, alerts.json readable: rules keep evaluating,
    /// the private part is never overwritten with placeholders, unlock merges it back.
    @Test func lockedIntelPrivatePartWaitsAndMerges() throws {
        let dir = tempDir(), lock = Lock(), fm = FileManager.default
        let a = store(dir, lock)
        a.createEmpty(); buy(a, 1)
        a.quotes[btc.id] = Quote(price: 90000, source: "test", timestamp: Date())
        a.watchDraft = WatchDraft(asset: "SOL", entry: "135", note: "private thesis"); a.saveWatch()
        a.alertSetup = AlertSetup(line: "alert btc above 95000"); a.advanceAlertSetup(); a.advanceAlertSetup()
        #expect(a.intel.watchlist.count == 1 && a.intel.alerts.count == 1)

        let stash = dir.appendingPathComponent("stash.json")
        try fm.moveItem(at: a.intelStore.url, to: stash)
        try fm.createDirectory(at: a.intelStore.url, withIntermediateDirectories: true)   // exists, unreadable
        let b = store(dir, lock)
        #expect(b.intelPrivateDeferred && b.intel.alerts.count == 1 && b.intel.watchlist.isEmpty && b.protectedDataWaiting)
        #expect(!b.updateIntel { Watchlist.add(AssetCatalog.known.first { $0.symbol == "ETH" }!, price: 3000, to: &$0, now: Date()) },
                "no edits to placeholders")
        b.quotes[btc.id] = Quote(price: 96000, source: "test", timestamp: Date())
        b.evaluateAlerts()
        #expect(b.intel.alertLog.count == 1, "rules still evaluate and persist while the private part is locked")
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: b.intelStore.url.path, isDirectory: &isDir) && isDir.boolValue, "intel.json untouched")

        try fm.removeItem(at: b.intelStore.url); try fm.moveItem(at: stash, to: b.intelStore.url)
        b.resumeProtectedData()
        #expect(!b.intelPrivateDeferred && !b.protectedDataWaiting)
        #expect(b.intel.watchlist.first?.note == "private thesis" && b.intel.alertLog.count == 1, "merged: private part from disk, rules from memory")
    }
}
