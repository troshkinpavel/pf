import Foundation
import Testing
import PFCore
import PFCoreTestSupport

// Data-integrity rules of record-level sync, against the in-memory store only (never iCloud).

private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private func buy(_ pf: UUID, _ q: Decimal) -> Transaction {
    Transaction(portfolioID: pf, assetID: btc.id, type: .buy, quantity: q, price: 100, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
}
private func seeded(_ n: Int) -> PortfolioDocument {
    var d = PortfolioDocument.fresh()
    d.assets = [btc]
    d.transactions = (0..<n).map { i in buy(d.portfolios[0].id, Decimal(i + 1)) }
    return d
}
/// A uploads `n` transactions, B downloads them.
@MainActor private func pair(_ n: Int = 2) async throws -> (MockRemote, Device, Device) {
    let r = MockRemote(), a = Device("A", seeded(n)), b = Device("B")
    try await a.enable(r, .upload)
    try await b.enable(r, .useCloud)
    return (r, a, b)
}
private func qty(_ d: Device, _ id: UUID) -> Decimal? { MainActor.assumeIsolated { d.doc.transactions.first { $0.id == id }?.quantity } }

@MainActor
struct SyncHardeningTests {
    @Test func newerRemoteReplacesUnchangedLocal() async throws {
        let (r, a, b) = try await pair()
        let id = a.doc.transactions[0].id
        a.doc.transactions[0].quantity = 42; a.tick()
        try await a.sync(r); try await b.sync(r)
        #expect(qty(b, id) == 42 && b.syncState.conflicts.isEmpty)
    }

    @Test func staleRemoteDoesNotOverwriteNewerLocal() async throws {
        let (r, a, b) = try await pair()
        let t = a.doc.transactions[0]
        a.doc.transactions[0].quantity = 42; a.tick(100)
        try await a.sync(r)
        // An older copy (e.g. from a 0.5 client with an old clock) lands in iCloud afterwards.
        var stale = try #require(await r.records[SyncRecord.key(.transaction, t.id.uuidString)])
        stale.payload = try SyncEngine.encoder.encode(t); stale.modifiedAt = a.clock.addingTimeInterval(-500)
        await r.inject(stale)
        try await a.sync(r)
        #expect(qty(a, t.id) == 42, "newer local kept")
        #expect(a.syncState.conflicts.first?.reason.contains("older version") == true)
        try await b.sync(r)
        #expect(qty(b, t.id) == 42, "the newer version was sent again and won everywhere")
    }

    @Test func staleTombstoneDoesNotDeleteNewerRecord() async throws {
        let (r, a, _) = try await pair()
        let t = a.doc.transactions[0]
        a.doc.transactions[0].note = "edited later"; a.tick(100)
        try await a.sync(r)
        await r.inject(SyncRecord(kind: .transaction, id: t.id.uuidString, modifiedAt: a.clock.addingTimeInterval(-500),
                                  deletedAt: a.clock.addingTimeInterval(-500), deviceID: "old"))
        try await a.sync(r)
        #expect(a.doc.transactions.contains { $0.id == t.id && $0.note == "edited later" })
        #expect(await r.records[SyncRecord.key(.transaction, t.id.uuidString)]?.isTombstone == false)
    }

    @Test func oldLocalCopyDoesNotResurrectDeletedRecord() async throws {
        let (r, a, _) = try await pair()
        let backup = a.doc                                  // an old copy, e.g. a Mac that turned sync off
        a.doc.transactions.removeFirst(); a.tick()
        try await a.sync(r)
        let old = Device("old", backup)
        try await old.enable(r, .merge)
        #expect(old.doc.transactions.count == 1, "the deleted transaction stays deleted")
        #expect(old.syncState.conflicts.first?.reason.contains("kept the delete") == true, "local copy kept for review")
        #expect(await r.liveCount.transactions == 1)
    }

    @Test func oldLocalCopyDoesNotRevertNewerRemoteEdit() async throws {
        let (r, a, _) = try await pair()
        let id = a.doc.transactions[0].id
        let backup = a.doc
        a.doc.transactions[0].quantity = 42; a.tick()
        try await a.sync(r)
        let old = Device("old", backup, clock: a.clock.addingTimeInterval(3600))   // later clock, older data
        try await old.enable(r, .merge)
        try await a.sync(r)
        #expect(qty(old, id) == 42 && qty(a, id) == 42)
    }

    @Test func offlineEditsUploadLater() async throws {
        let (r, a, b) = try await pair()
        await r.setOffline(true)
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 9)); a.doc.transactions[0].note = "x"; a.tick()
        await #expect(throws: SyncStoreError.offline) { try await a.sync(r) }
        #expect(a.doc.transactions.count == 3, "local data untouched by the failure")
        await r.setOffline(false)
        try await a.sync(r); try await b.sync(r)
        #expect(b.doc.transactions.count == 3 && b.doc.transactions.contains { $0.note == "x" })
    }

    @Test func simultaneousEditsToDifferentRecordsBothSurvive() async throws {
        let (r, a, b) = try await pair()
        let (x, y) = (a.doc.transactions[0].id, a.doc.transactions[1].id)
        a.doc.transactions[0].quantity = 10; a.tick()
        b.doc.transactions[b.doc.transactions.firstIndex { $0.id == y }!].quantity = 20; b.tick()
        try await a.sync(r); try await b.sync(r); try await a.sync(r)
        for d in [a, b] { #expect(qty(d, x) == 10 && qty(d, y) == 20) }
        #expect(a.syncState.conflicts.isEmpty && b.syncState.conflicts.isEmpty)
    }

    @Test func sameRecordConflictKeepsNewerAndPreservesOther() async throws {
        let (r, a, b) = try await pair()
        let id = a.doc.transactions[0].id
        a.doc.transactions[0].quantity = 10; a.tick(10)
        b.doc.transactions[b.doc.transactions.firstIndex { $0.id == id }!].quantity = 20; b.tick(30)
        try await a.sync(r); try await b.sync(r); try await a.sync(r)
        #expect(qty(a, id) == 20 && qty(b, id) == 20)
        let c = try #require(b.syncState.conflicts.first)
        #expect(c.other.payload.flatMap { try? PortfolioDocument.decoder.decode(Transaction.self, from: $0) }?.quantity == 10)
    }

    @Test func deleteBasedOnLatestVersionWinsDespiteSlowClock() async throws {
        let (r, a, b) = try await pair()
        let id = a.doc.transactions[0].id
        a.doc.transactions[0].quantity = 5; a.tick(1000)
        try await a.sync(r); try await b.sync(r)
        b.doc.transactions.removeAll { $0.id == id }                    // B's clock is far behind A's
        try await b.sync(r); try await a.sync(r)
        #expect(!a.doc.transactions.contains { $0.id == id } && a.syncState.conflicts.isEmpty)
    }

    @Test func replacedLocalDocumentIsRecoveredNotTombstoned() async throws {
        let (r, a, b) = try await pair(3)
        // portfolio.json unreadable → set aside → a fresh empty MAIN with a new id.
        b.doc = .fresh(); b.tick()
        try await b.sync(r)
        #expect(await r.liveCount == (1, 3), "nothing deleted in iCloud")
        #expect(b.doc.transactions.count == 3 && b.doc.portfolios.map(\.id) == a.doc.portfolios.map(\.id), "restored, no stray empty MAIN")
        #expect(b.syncState.recovering == nil && b.syncState.pendingCount == 0)
        try await a.sync(r)
        #expect(a.doc.transactions.count == 3 && a.doc.portfolios.count == 1)
    }

    @Test func unrelatedImportMergesInsteadOfWipingICloud() async throws {
        let (r, _, b) = try await pair(2)
        b.doc = seeded(1); b.tick()                                       // import replace with an unrelated backup
        try await b.sync(r)
        #expect(await r.liveCount == (2, 3))
        #expect(b.doc.transactions.count == 3 && b.doc.portfolios.count == 2)
    }

    @Test func freshInstallWithExistingCloudData() async throws {
        let (r, a, _) = try await pair(3)
        let c = Device("C")
        #expect(try await SyncEngine.inspect(c, remote: r).plan == .useCloud)
        try await c.enable(r, .useCloud)
        #expect(c.doc.transactions.count == 3 && c.doc.portfolios.map(\.id) == a.doc.portfolios.map(\.id))
        #expect(await r.liveCount == (1, 3))
    }

    @Test func emptyRemoteResultNeverRemovesLocalData() async throws {
        let r = MockRemote(), a = Device("A", seeded(2))
        try await a.enable(r, .upload)
        let before = a.doc
        a.syncState.token = nil                                           // e.g. change token expired → full fetch
        try await a.sync(r)
        let empty = MockRemote()                                          // a store that returns nothing at all
        await empty.setUser("user-1")
        try await SyncEngine.cycle(a, remote: EmptyFetch(empty), now: { a.clock })
        #expect(a.doc == before)
    }

    @Test func networkFailureKeepsLocalDataAndState() async throws {
        let (r, a, _) = try await pair()
        let doc = a.doc, known = a.syncState.known
        await r.setOffline(true)
        await #expect(throws: SyncStoreError.offline) { try await a.sync(r) }
        #expect(a.doc == doc && a.syncState.known == known)
    }

    @Test func interruptedPushIsResumedWithoutDuplicates() async throws {
        let (r, a, b) = try await pair()
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 7)); a.doc.transactions[0].quantity = 99; a.tick()
        await r.setLoseSaveReplies(true)
        await #expect(throws: SyncStoreError.offline) { try await a.sync(r) }   // saved in iCloud, reply lost
        await r.setLoseSaveReplies(false)
        try await a.sync(r); try await b.sync(r)
        #expect(a.syncState.pendingCount == 0 && a.syncState.conflicts.isEmpty)
        #expect(await r.liveCount == (1, 3) && b.doc.transactions.count == 3)
    }

    @Test func overlappingPassesAreSerialized() async throws {
        let (r, a, _) = try await pair()
        await r.setFetchDelay(50_000_000)
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 7))
        async let x: Void = a.sync(r)
        async let y: Void = a.sync(r)
        _ = try await (x, y)
        #expect(await r.maxConcurrentFetches == 1)
        #expect(await r.liveCount.transactions == 3 && a.syncState.pendingCount == 0)
    }

    @Test func turningSyncOffMidPassWritesNothing() async throws {
        let (r, a, _) = try await pair()
        await r.setFetchDelay(50_000_000)
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 7))
        let pass = Task { try await a.sync(r) }
        try await Task.sleep(nanoseconds: 10_000_000)
        SyncEngine.disable(a)
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(a.syncState.mode == .localOnly && a.syncState.known.isEmpty)
        #expect(await r.liveCount.transactions == 2)
    }

    @Test func repeatedSyncIsIdempotent() async throws {
        let (r, a, b) = try await pair()
        let saves = await r.saveCalls
        for _ in 0..<3 { try await a.sync(r); try await b.sync(r) }
        #expect(await r.saveCalls == saves, "nothing re-uploaded")
        #expect(a.doc == b.doc || (Set(a.doc.transactions) == Set(b.doc.transactions)))
        #expect(a.syncState.conflicts.isEmpty && b.syncState.conflicts.isEmpty)
    }
}

/// Same account, but every fetch comes back empty (partial/empty server answer).
private struct EmptyFetch: SyncRemoteStore {
    let base: MockRemote
    init(_ b: MockRemote) { base = b }
    func accountStatus() async -> SyncAccountStatus { .available }
    func accountID() async throws -> String? { "user-1" }
    func fetchChanges(since token: Data?) async throws -> SyncFetchResult { SyncFetchResult(records: [], token: token) }
    func save(_ records: [SyncRecord]) async throws -> [SyncSaveOutcome] { try await base.save(records) }
}
