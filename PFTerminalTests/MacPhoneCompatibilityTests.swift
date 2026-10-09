import PFCore
import PFCoreTestSupport
import Foundation
import Testing
@testable import PFTerminal

/// The Mac half of the Mac ↔ iPhone check (the iOS test target runs the real iPhone store).
/// Client A is the real macOS `AppStore`; client B is an iPhone-shaped SyncHost using the same
/// PFCore engine. Throwaway storage and the in-memory CloudKit stand-in only.
@MainActor
struct MacPhoneCompatibilityTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!

    private func macStore(_ r: MockRemote) -> AppStore {
        var o = AppStore.Options()
        o.directory = FileManager.default.temporaryDirectory.appendingPathComponent("pf-mac-\(UUID().uuidString)")
        o.inMemory = true
        o.mockMarket = true
        o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf.mac.test.\(UUID().uuidString)")!
        o.syncRemote = r
        return AppStore(o)
    }

    @Test func macLedgerReachesPhoneAndPhoneEditsReachMac() async throws {
        let r = MockRemote()
        let mac = macStore(r)
        mac.createEmpty()
        let main = mac.doc.portfolios[0].id
        mac.doc.upsert(Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 1, price: 60000, timestamp: PortfolioInfo.stamp(Date().addingTimeInterval(-86400))), asset: btc)
        mac.save()
        try await SyncEngine.enable(mac, remote: r, choice: .upload, deviceName: "MacBook Pro")

        let phone = Device("iPhone", PortfolioDocument(portfolios: []), clock: PortfolioInfo.stamp(Date()))   // whole seconds, as stored
        try await phone.enable(r, .useCloud)
        #expect(phone.doc.portfolios.map(\.id) == [main])
        #expect(Set(phone.doc.transactions) == Set(mac.doc.transactions), "identical records, identical ids")

        // The iPhone adds a transaction; the Mac's next cycle applies it without duplicates.
        phone.tick()
        let t = Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 1, price: 70000, timestamp: phone.clock)
        phone.doc.transactions.append(t)
        try await phone.sync(r)
        try await SyncEngine.cycle(mac, remote: r)
        #expect(mac.doc.transactions.first { $0.id == t.id } == t)
        #expect(mac.doc.transactions.count == 2)
        #expect(await r.liveCount == (1, 2))

        // The Mac deletes it again: the tombstone reaches the iPhone.
        mac.deleteTx(t)
        try await SyncEngine.cycle(mac, remote: r)
        try await phone.sync(r)
        #expect(!phone.doc.transactions.contains { $0.id == t.id })
    }

    /// The Mac's ledger gets reset while sync is on (unreadable portfolio.json set aside, then
    /// "1 empty" in onboarding): iCloud keeps everything and the Mac gets its portfolios back.
    @Test func resetMacDocumentRecoversFromICloudInsteadOfWipingIt() async throws {
        let r = MockRemote()
        let mac = macStore(r)
        mac.createEmpty()
        let main = mac.doc.portfolios[0].id
        mac.doc.upsert(Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 1, price: 60000, timestamp: PortfolioInfo.stamp(Date())), asset: btc)
        mac.save()
        try await SyncEngine.enable(mac, remote: r, choice: .upload, deviceName: "Mac")
        #expect(await r.liveCount == (1, 1))

        mac.createEmpty()                        // save() queues changes right away (scheduleSync)
        #expect(mac.syncState.known.values.allSatisfy { $0.deletedAt == nil }, "no tombstones queued")
        try await SyncEngine.cycle(mac, remote: r)
        #expect(await r.liveCount == (1, 1))
        #expect(mac.doc.portfolios.map(\.id) == [main] && mac.doc.transactions.count == 1)
    }
}

/// 0.9: watchlist / alerts / scenarios between two Macs through the real AppStore wiring
/// (in-memory stand-ins for both CloudKit zones).
@MainActor
struct IntelSyncAppTests {
    private let sol = AssetCatalog.known.first { $0.symbol == "SOL" }!

    private func mac(_ ledger: MockRemote, _ intel: MockRemote, dir: URL? = nil, defaults: UserDefaults? = nil) -> AppStore {
        var o = AppStore.Options()
        o.directory = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("pf-intel-\(UUID().uuidString)")
        o.inMemory = true; o.mockMarket = true; o.publishWidgets = false
        o.defaults = defaults ?? UserDefaults(suiteName: "pf.intel.test.\(UUID().uuidString)")!
        o.syncRemote = ledger; o.intelSyncRemote = intel
        let s = AppStore(o)
        if dir == nil { s.createEmpty() }
        return s
    }

    /// A Mac with sync on and one watch, alert and scenario in iCloud. Returns what a relaunch needs.
    private func synced(_ r: MockRemote, _ ri: MockRemote) async throws -> (AppStore, URL, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-intel-\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "pf.intel.test.\(UUID().uuidString)")!
        let a = mac(r, ri, dir: dir, defaults: d)
        a.createEmpty()
        a.updateIntel {
            $0.watchlist = [WatchItem(asset: sol, addedAt: Date(), priceAtAdd: 150)]
            $0.alerts = [AlertRule(number: 1, kind: .priceAbove, subject: .asset(sol.id), threshold: 200, createdAt: Date())]
            $0.scenarios = [PortfolioScenario(name: "BASE", key: "b", editedAt: Date())]
        }
        try await SyncEngine.enable(a, remote: r, choice: .upload, deviceName: "Mac A")
        await intelPass(a)
        #expect(await liveIntel(ri) == 3)
        return (a, dir, d)
    }

    private func liveIntel(_ r: MockRemote) async -> Int { await r.records.values.filter { !$0.isTombstone }.count }

    @Test func deleteAllInPFPropagatesAndStaysDeleted() async throws {
        let r = MockRemote(), ri = MockRemote()
        let (a, dir, d) = try await synced(r, ri)
        a.updateIntel { $0.watchlist = []; $0.alerts = []; $0.scenarios = [] }
        await intelPass(a)
        #expect(await liveIntel(ri) == 0)
        // Relaunch: the empty files are real, nothing comes back.
        let again = mac(r, ri, dir: dir, defaults: d)
        await intelPass(again)
        #expect(again.intel.watchlist.isEmpty && again.intel.alerts.isEmpty && again.intel.scenarios.isEmpty)
        #expect(await liveIntel(ri) == 0)
    }

    @Test func unreadableIntelFilesAreRefetchedNotDeleted() async throws {
        let r = MockRemote(), ri = MockRemote()
        let (_, dir, d) = try await synced(r, ri)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("intel.json"))
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("alerts.json"))
        let again = mac(r, ri, dir: dir, defaults: d)
        #expect(again.intel.watchlist.isEmpty, "set aside")
        await intelPass(again)
        let recs = await ri.records
        #expect(recs.count == 3 && recs.values.allSatisfy { !$0.isTombstone })
        #expect(again.intel.watchlist.count == 1 && again.intel.alerts.count == 1 && again.intel.scenarios.count == 1)
    }

    @Test func missingIntelFileIsRefetchedNotDeleted() async throws {
        let r = MockRemote(), ri = MockRemote()
        let (_, dir, d) = try await synced(r, ri)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("intel.json"))
        let again = mac(r, ri, dir: dir, defaults: d)
        await intelPass(again)
        #expect(await liveIntel(ri) == 3)
        #expect(again.intel.watchlist.count == 1 && again.intel.scenarios.count == 1 && again.intel.alerts.count == 1)
    }

    @Test func protectedWatchlistNeverReadsAsDeleteAll() async throws {
        let r = MockRemote(), ri = MockRemote()
        let (a, _, _) = try await synced(r, ri)
        // Locked at launch: watchlist / scenarios are empty placeholders.
        a.intelPrivateDeferred = true
        a.intel.watchlist = []; a.intel.scenarios = []
        a.scheduleIntelSync()
        await intelPass(a)
        #expect(a.intelSyncState.pendingCount == 0)
        #expect(await liveIntel(ri) == 3)
    }

    /// 0.7 → 0.9 split interrupted (schema 1 intel.json still holds the alerts, alerts.json missing):
    /// the alerts load from it and nothing is deleted or rebased.
    @Test func interruptedSplitKeepsAlertsSynced() async throws {
        let r = MockRemote(), ri = MockRemote()
        let (a, dir, d) = try await synced(r, ri)
        var legacy = a.intel
        legacy.schemaVersion = 1
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(legacy).write(to: dir.appendingPathComponent("intel.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("alerts.json"))
        let again = mac(r, ri, dir: dir, defaults: d)
        #expect(again.intelLoadUnverified.isEmpty && again.intel.alerts.count == 1)
        await intelPass(again)
        #expect(await liveIntel(ri) == 3)
        #expect(again.intelSyncState.pendingCount == 0)
    }

    @Test func deleteAllQueuedOfflineThenRelaunchSyncs() async throws {
        let r = MockRemote(), ri = MockRemote()
        let (a, dir, d) = try await synced(r, ri)
        await ri.setOffline(true)
        a.updateIntel { $0.watchlist = []; $0.alerts = [] }
        await intelPass(a)
        #expect(a.intelSyncState.pendingCount == 2)
        await ri.setOffline(false)
        let again = mac(r, ri, dir: dir, defaults: d)
        await intelPass(again)
        #expect(again.intel.watchlist.isEmpty && again.intel.alerts.isEmpty && again.intel.scenarios.count == 1)
        #expect(await liveIntel(ri) == 1)
    }

    private func intelPass(_ s: AppStore) async { s.intelSyncNow(); await s.intelSyncTask?.value }

    /// 0.8.2 → 0.8.3: a Mac with ledger sync on and a local watchlist, alerts and scenarios (no
    /// intel sync yet). After the upgrade the ledger file and the ledger zone are untouched; the
    /// intel records go to their own zone only.
    @Test func upgradeFrom082LeavesTheLedgerUntouched() async throws {
        let r = MockRemote(), ri = MockRemote()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-083-\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "pf.intel.test.\(UUID().uuidString)")!
        // 0.8.2: the same store with no intel remote (it had no intel sync).
        var o = AppStore.Options()
        o.directory = dir; o.inMemory = true; o.mockMarket = true; o.publishWidgets = false; o.defaults = d; o.syncRemote = r
        let old = AppStore(o)
        old.createEmpty()
        let main = old.doc.portfolios[0].id
        old.doc.upsert(Transaction(portfolioID: main, assetID: sol.id, type: .buy, quantity: 3, price: 140, timestamp: PortfolioInfo.stamp(Date())), asset: sol)
        old.save()
        old.updateIntel {
            $0.watchlist = [WatchItem(asset: AssetCatalog.known.first { $0.symbol == "LINK" }!, addedAt: Date(), priceAtAdd: 13)]
            $0.alerts = [AlertRule(number: 1, kind: .priceAbove, subject: .asset(sol.id), threshold: 200, createdAt: Date())]
            $0.scenarios = [PortfolioScenario(name: "BASE", key: "b", editedAt: Date())]
        }
        try await SyncEngine.enable(old, remote: r, choice: .upload, deviceName: "Mac")
        #expect(old.intelSyncRemote == nil && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(SyncStateFile.intelFile).path))
        let ledgerBytes = try Data(contentsOf: dir.appendingPathComponent("portfolio.json"))
        let ledgerRecords = await r.records, ledgerSaves = await r.saveCalls

        let new = mac(r, ri, dir: dir, defaults: d)          // 0.8.3
        #expect(new.doc.transactions == old.doc.transactions && new.intel.watchlist.count == 1)
        try await SyncEngine.cycle(new, remote: r)
        await intelPass(new)
        #expect(try Data(contentsOf: dir.appendingPathComponent("portfolio.json")) == ledgerBytes, "the ledger file is not rewritten")
        let after = await r.records, saves = await r.saveCalls, intel = await ri.records
        #expect(after == ledgerRecords && saves == ledgerSaves, "the ledger zone is untouched")
        #expect(after.values.allSatisfy { [.portfolio, .transaction, .asset].contains($0.kind) })
        #expect(Set(intel.values.map(\.kind)) == [.watch, .alert, .scenario], "intel goes to its own zone")
        #expect(intel.values.allSatisfy { !$0.isTombstone })
    }

    @Test func intelFollowsLedgerSyncAndHoldsConflicts() async throws {
        let r = MockRemote(), ri = MockRemote()
        let a = mac(r, ri), b = mac(r, ri)
        a.updateIntel { $0.watchlist.append(WatchItem(asset: sol, addedAt: Date(), priceAtAdd: 150)) }
        a.updateIntel { $0.alerts = [AlertRule(number: 1, kind: .priceAbove, subject: .asset(sol.id), threshold: 200, createdAt: Date())] }
        // Sync off: nothing leaves the Mac.
        await intelPass(a)
        #expect(await ri.records.isEmpty && a.intelSyncState.mode == .localOnly)

        try await SyncEngine.enable(a, remote: r, choice: .upload, deviceName: "Mac A")
        await intelPass(a)
        #expect(await ri.records.count == 2 && a.intelSyncStatus == .synced)
        try await SyncEngine.enable(b, remote: r, choice: .useCloud, deviceName: "Mac B")
        await intelPass(b)
        #expect(b.intel.watchlist.map(\.id) == a.intel.watchlist.map(\.id) && b.intel.alerts.map(\.id) == a.intel.alerts.map(\.id))

        // Same rule edited on both before they synced: B holds it and asks.
        a.updateIntel { $0.alerts[0].threshold = 250 }
        try await Task.sleep(nanoseconds: 10_000_000)
        b.updateIntel { $0.alerts[0].threshold = 180 }
        await intelPass(a); await intelPass(b)
        let c = try #require(b.intelConflict)
        #expect(b.intel.alerts[0].threshold == 180 && b.intelSyncIndicator?.text.contains("conflict") == true)
        #expect(b.intelConflictOtherIsNewer(c) == false)
        b.resolveIntelConflict(c, keepOther: true)
        #expect(b.intel.alerts[0].threshold == 250 && b.intelConflict == nil)

        // Sync off: intel stops too; data stays.
        b.confirmDisableSync()
        #expect(b.intelSyncState.mode == .localOnly && b.intel.alerts.count == 1)
    }

    @Test func lockedWatchlistNeverSyncsPlaceholders() async throws {
        let r = MockRemote(), ri = MockRemote()
        let a = mac(r, ri)
        try await SyncEngine.enable(a, remote: r, choice: .upload, deviceName: "Mac A")
        a.intelPrivateDeferred = true
        await intelPass(a)
        #expect(await ri.records.isEmpty)
        #expect(a.intelSyncIndicator?.text.contains("paused") == true)
    }
}
