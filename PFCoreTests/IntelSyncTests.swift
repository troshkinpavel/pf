import Foundation
import Testing
import PFCore
import PFCoreTestSupport

// 0.9 watchlist / alerts / scenarios sync, against the in-memory store only (never iCloud).

private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private let sol = AssetCatalog.known.first { $0.symbol == "SOL" }!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func rule(_ n: Int, _ threshold: Double = 100_000, note: String? = nil, at: Date = t0) -> AlertRule {
    AlertRule(number: n, kind: .priceAbove, subject: .asset(btc.id), threshold: threshold, createdAt: at, note: note)
}

@MainActor
struct IntelSyncTests {
    /// A has a watch, a rule and a scenario; B starts empty and receives them.
    private func pair() async throws -> (MockRemote, IntelDevice, IntelDevice) {
        var d = IntelDocument()
        d.watchlist = [WatchItem(asset: sol, addedAt: t0, priceAtAdd: 150)]
        d.alerts = [rule(1)]
        d.scenarios = [PortfolioScenario(name: "BASE", key: "b", editedAt: t0, targets: [btc.id: ScenarioTarget(price: 150_000)])]
        let r = MockRemote(), a = IntelDevice("A", d), b = IntelDevice("B")
        try await a.sync(r); try await b.sync(r)
        return (r, a, b)
    }

    @Test func recordsTravelAndLogNeverSyncs() async throws {
        let (r, a, b) = try await pair()
        #expect(b.doc.watchlist.map(\.id) == a.doc.watchlist.map(\.id) && b.doc.alerts == a.doc.alerts && b.doc.scenarios == a.doc.scenarios)
        a.doc.alertLog = [AlertEvent(at: t0, rule: a.doc.alerts[0].id, number: 1, message: "BTC above", delivery: "banner")]
        a.tick(); try await a.sync(r); try await b.sync(r)
        #expect(b.doc.alertLog.isEmpty)
        #expect(await r.records.keys.allSatisfy { $0.hasPrefix("watch.") || $0.hasPrefix("alert.") || $0.hasPrefix("scenario.") })
    }

    @Test func alertStateChangesResolveNewerWinsSilently() async throws {
        let (r, a, b) = try await pair()
        a.doc.alerts[0].state = .fired; a.doc.alerts[0].firedAt = t0; a.tick(5)
        b.doc.alerts[0].paused = true; b.tick(20)
        try await a.sync(r); try await b.sync(r); try await a.sync(r)
        #expect(a.intelSyncState.conflicts.isEmpty && b.intelSyncState.conflicts.isEmpty)
        #expect(a.doc.alerts == b.doc.alerts)
    }

    @Test func definitionConflictIsHeldUntilTheUserPicks() async throws {
        let (r, a, b) = try await pair()
        a.doc.alerts[0].threshold = 120_000; a.tick(5)
        b.doc.alerts[0].threshold = 90_000; b.tick(20)
        try await a.sync(r); try await b.sync(r)
        // B keeps (and evaluates) its own version and doesn't send it.
        #expect(b.intelSyncState.conflicts.count == 1 && b.doc.alerts[0].threshold == 90_000)
        try await b.sync(r)
        let remote = try PortfolioDocument.decoder.decode(AlertRule.self, from: await r.records["alert." + a.doc.alerts[0].id.uuidString]!.payload!)
        #expect(remote.threshold == 120_000, "a held version is never pushed")
        // Keep this Mac → sent; A gets it without a conflict.
        var d = b.doc, st = b.intelSyncState
        IntelSyncEngine.resolve(st.conflicts[0], useOther: false, &d, &st)
        b.doc = d; b.intelSyncState = st; b.tick()
        try await b.sync(r); try await a.sync(r)
        #expect(a.doc.alerts[0].threshold == 90_000 && a.intelSyncState.conflicts.isEmpty)
    }

    @Test func keepOtherAppliesItAndSendsNothing() async throws {
        let (r, a, b) = try await pair()
        a.doc.scenarios[0].targets[btc.id] = ScenarioTarget(price: 200_000); a.tick(5)
        b.doc.scenarios[0].targets[btc.id] = ScenarioTarget(price: 50_000); b.tick(20)
        try await a.sync(r); try await b.sync(r)
        var d = b.doc, st = b.intelSyncState
        IntelSyncEngine.resolve(st.conflicts[0], useOther: true, &d, &st)
        b.doc = d; b.intelSyncState = st
        #expect(b.doc.scenarios[0].targets[btc.id]?.price == 200_000 && b.intelSyncState.pendingCount == 0)
    }

    @Test func editBeatsDelete() async throws {
        let (r, a, b) = try await pair()
        a.doc.watchlist.removeAll(); a.tick(5)
        b.doc.watchlist[0].note = "thesis"; b.tick(20)
        try await a.sync(r); try await b.sync(r); try await a.sync(r)
        #expect(a.doc.watchlist.first?.note == "thesis" && b.doc.watchlist.count == 1)
    }

    /// A replaced file (set aside / missing) is rebased by the host: iCloud's copy comes back, nothing is tombstoned.
    @Test func replacedDataIsRefetchedNeverDeleted() async throws {
        let (r, _, b) = try await pair()
        b.doc = IntelDocument(); b.tick()
        IntelSyncEngine.rebase(&b.intelSyncState, kinds: [.watch, .alert, .scenario])
        try await b.sync(r)
        #expect(await r.records.values.allSatisfy { !$0.isTombstone })
        #expect(b.doc.watchlist.count == 1 && b.doc.alerts.count == 1 && b.doc.scenarios.count == 1, "refetched")
    }

    /// Only the replaced domain is rebased: a delete-all in another domain still propagates.
    @Test func rebaseIsPerDomain() async throws {
        let (r, a, b) = try await pair()
        b.doc.watchlist = []; b.doc.alerts = []; b.tick()
        IntelSyncEngine.rebase(&b.intelSyncState, kinds: [.alert])     // alerts.json was unreadable
        try await b.sync(r); try await a.sync(r)
        #expect(b.doc.alerts.count == 1 && b.doc.watchlist.isEmpty)
        #expect(a.doc.watchlist.isEmpty && a.doc.alerts.count == 1)
    }

    // MARK: delete-all

    /// "live/tombstones" per domain in the remote: ["watch": "0/1", …]
    private func remote(_ r: MockRemote) async -> [String: String] {
        let recs = await r.records
        return Dictionary(uniqueKeysWithValues: ["watch", "alert", "scenario"].map { k in
            let m = recs.filter { $0.key.hasPrefix(k + ".") }.values
            return (k, "\(m.filter { !$0.isTombstone }.count)/\(m.filter(\.isTombstone).count)")
        })
    }

    @Test func deletingTheOnlyRecordOfEachDomainPropagates() async throws {
        let (r, a, b) = try await pair()
        a.doc.watchlist = []; a.tick(); try await a.sync(r)
        #expect(await remote(r)["watch"] == "0/1")
        a.doc.alerts = []; a.tick(); try await a.sync(r)
        #expect(await remote(r)["alert"] == "0/1")
        a.doc.scenarios = []; a.tick(); try await a.sync(r)
        #expect(await remote(r)["scenario"] == "0/1")
        try await b.sync(r)
        #expect(b.doc.watchlist.isEmpty && b.doc.alerts.isEmpty && b.doc.scenarios.isEmpty)
        try await a.sync(r)
        #expect(a.doc.watchlist.isEmpty && a.doc.alerts.isEmpty && a.doc.scenarios.isEmpty, "not fetched back")
    }

    @Test func deletingAllOfManyPropagates() async throws {
        let (r, a, b) = try await pair()
        a.doc.watchlist += [WatchItem(asset: btc, addedAt: t0, priceAtAdd: 1)]
        a.doc.alerts += [rule(2), rule(3, 50_000)]
        a.doc.scenarios += [PortfolioScenario(name: "BULL", key: "u", editedAt: t0), PortfolioScenario(name: "MINE", editedAt: t0)]
        a.tick(); try await a.sync(r); try await b.sync(r)
        #expect(b.doc.watchlist.count == 2 && b.doc.alerts.count == 3 && b.doc.scenarios.count == 3)
        a.doc.watchlist = []; a.doc.alerts = []; a.doc.scenarios = []; a.tick()
        try await a.sync(r)
        #expect(await remote(r) == ["watch": "0/2", "alert": "0/3", "scenario": "0/3"])
        try await b.sync(r)
        #expect(b.doc.watchlist.isEmpty && b.doc.alerts.isEmpty && b.doc.scenarios.isEmpty)
    }

    @Test func oldOfflineMacReconnectingAfterDeleteAllDoesNotResurrect() async throws {
        let (r, a, b) = try await pair()
        await r.setOffline(true)
        b.tick(3600)                                     // B is offline for a while, unchanged
        await r.setOffline(false)
        a.doc.watchlist = []; a.doc.alerts = []; a.doc.scenarios = []; a.tick()
        try await a.sync(r)
        b.tick(); try await b.sync(r)                    // B reconnects with its old copy
        #expect(b.doc.watchlist.isEmpty && b.doc.alerts.isEmpty && b.doc.scenarios.isEmpty)
        #expect(await remote(r) == ["watch": "0/1", "alert": "0/1", "scenario": "0/1"])
        #expect(b.intelSyncState.pendingCount == 0 && b.intelSyncState.conflicts.isEmpty)
        try await a.sync(r)
        #expect(a.doc.watchlist.isEmpty && a.doc.alerts.isEmpty)
    }

    @Test func freshMacPullsRemoteRecords() async throws {
        let (r, a, _) = try await pair()
        let c = IntelDevice("C")                         // never synced: no known records, empty doc
        try await c.sync(r)
        #expect(c.doc.watchlist.map(\.id) == a.doc.watchlist.map(\.id) && c.doc.alerts.count == 1 && c.doc.scenarios.count == 1)
        #expect(await r.records.values.allSatisfy { !$0.isTombstone })
    }

    @Test func repeatedSyncAfterDeleteAllIsStable() async throws {
        let (r, a, b) = try await pair()
        a.doc.watchlist = []; a.doc.alerts = []; a.doc.scenarios = []; a.tick()
        try await a.sync(r); try await b.sync(r)
        let saves = await r.saveCalls, keys = await r.records.count
        for _ in 0..<3 { a.tick(); b.tick(); try await a.sync(r); try await b.sync(r) }
        let (saves2, keys2) = (await r.saveCalls, await r.records.count)
        #expect(saves2 == saves && keys2 == keys, "nothing re-sent")
        #expect(a.intelSyncState.pendingCount == 0 && b.intelSyncState.pendingCount == 0)
        #expect(a.doc == b.doc && a.doc.watchlist.isEmpty)
    }

    /// The doc was emptied while offline and the app restarted (state file has the queued
    /// tombstones): they go out on the next pass; nothing comes back.
    @Test func queuedDeleteAllSurvivesOfflineAndSyncs() async throws {
        let (r, a, _) = try await pair()
        a.doc.watchlist = []; a.doc.alerts = []; a.tick()
        await r.setOffline(true)
        await #expect(throws: (any Error).self) { try await a.sync(r) }
        IntelSyncEngine.detectLocalChanges(a.doc, &a.intelSyncState, now: a.clock)
        #expect(a.intelSyncState.pendingCount == 2)
        let relaunched = IntelDevice("A", a.doc, clock: a.clock)
        relaunched.intelSyncState = a.intelSyncState
        await r.setOffline(false)
        try await relaunched.sync(r)
        #expect(relaunched.doc.watchlist.isEmpty && relaunched.doc.alerts.isEmpty)
        #expect(await remote(r) == ["watch": "0/1", "alert": "0/1", "scenario": "1/0"])
    }

    @Test func normalizeMergesTwoMacsFirstSync() async throws {
        var da = IntelDocument(), db = IntelDocument()
        da.scenarios = [PortfolioScenario(name: "BASE", key: "b", editedAt: t0)]
        db.scenarios = [PortfolioScenario(name: "BASE", key: "b", editedAt: t0)]
        da.watchlist = [WatchItem(asset: sol, addedAt: t0, priceAtAdd: 150)]
        db.watchlist = [WatchItem(asset: sol, addedAt: t0.addingTimeInterval(60), priceAtAdd: 150)]
        da.alerts = [rule(1, note: IntelDocument.moveNote), rule(2, 1)]
        db.alerts = [rule(1, note: IntelDocument.moveNote, at: t0.addingTimeInterval(1)), rule(2, 2, at: t0.addingTimeInterval(2))]
        let r = MockRemote(), a = IntelDevice("A", da), b = IntelDevice("B", db)
        try await a.sync(r); try await b.sync(r); try await a.sync(r)
        for d in [a, b] {
            #expect(d.doc.scenarios.filter { $0.key == "b" }.count == 1 && Set(d.doc.scenarios.map(\.name)) == ["BASE", "BASE 2"])
            #expect(d.doc.watchlist.filter(\.isActive).count == 1 && d.doc.watchlist.count == 2)
            #expect(d.doc.alerts.filter { $0.note == IntelDocument.moveNote }.count == 1)
            #expect(Set(d.doc.alerts.map(\.number)).count == d.doc.alerts.count)
        }
        #expect(a.doc.alerts.sorted { $0.id.uuidString < $1.id.uuidString } == b.doc.alerts.sorted { $0.id.uuidString < $1.id.uuidString })
        #expect(a.intelSyncState.conflicts.isEmpty && b.intelSyncState.conflicts.isEmpty)
    }

    @Test func lockedHostDefersWithoutCommitting() async throws {
        let (r, a, _) = try await pair()
        a.intelSyncCanPersist = false
        await #expect(throws: SyncDeferredError.self) { try await a.sync(r) }
    }

    @Test func ledgerEngineIgnoresIntelKinds() {
        var doc = PortfolioDocument.fresh()
        let rec = SyncRecord(kind: .watch, id: UUID().uuidString, modifiedAt: t0, deviceID: "x", payload: Data("{}".utf8))
        #expect(!SyncEngine.apply(rec, &doc))
    }
}
