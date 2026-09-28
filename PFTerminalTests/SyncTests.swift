import PFCore
import PFCoreTestSupport
import Foundation
import Testing
@testable import PFTerminal

private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private func buy(_ pf: UUID, _ q: Decimal, id: UUID = UUID()) -> Transaction {
    Transaction(id: id, portfolioID: pf, assetID: btc.id, type: .buy, quantity: q, price: 100, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
}
private func seeded(_ n: Int = 2) -> PortfolioDocument {
    var d = PortfolioDocument.fresh()
    d.assets = [btc]
    d.transactions = (0..<n).map { _ in buy(d.portfolios[0].id, 1) }
    return d
}

@MainActor
struct SyncTests {
    @Test func offByDefault() {
        let s = SyncState()
        #expect(s.mode == .localOnly)
        #expect(!s.hasSynced)
        // A device that never enabled sync never contacts the store.
        let a = Device("A", seeded())
        #expect(a.syncState.mode == .localOnly)
    }

    @Test func inspectPlans() async throws {
        let r = MockRemote()
        let a = Device("A", seeded())
        #expect(try await SyncEngine.inspect(a, remote: r).plan == .upload)
        try await a.enable(r, .upload)
        let empty = Device("B")
        #expect(try await SyncEngine.inspect(empty, remote: r).plan == .useCloud)
        let other = Device("C", seeded(1))
        let i = try await SyncEngine.inspect(other, remote: r)
        #expect(i.plan == .choose)
        #expect(i.cloudTransactions == 2 && i.cloudDevices == ["A"])
        // Inspecting changes nothing on either side.
        #expect(other.syncState.mode == .localOnly && other.doc.transactions.count == 1)
        #expect(await r.liveCount.transactions == 2)
        #expect(try await SyncEngine.inspect(a, remote: r).plan == .resume)
    }

    @Test func uploadThenUseCloudOnSecondDevice() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(3))
        try await a.enable(r, .upload)
        #expect(await r.liveCount == (1, 3))
        #expect(a.syncState.pendingCount == 0 && a.syncState.lastSync != nil)

        let b = Device("B")
        let bMain = b.doc.portfolios[0].id
        try await b.enable(r, .useCloud)
        #expect(b.doc.transactions.count == 3)
        #expect(b.doc.portfolios.map(\.id) == a.doc.portfolios.map(\.id))
        #expect(!b.doc.portfolios.contains { $0.id == bMain })   // replaced, not merged
        #expect(await r.liveCount == (1, 3))
    }

    @Test func createEditDeletePropagate() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1)), b = Device("B")
        try await a.enable(r, .upload)
        try await b.enable(r, .useCloud)
        let pf = a.doc.portfolios[0].id

        // create
        let t = buy(pf, 5)
        a.doc.transactions.append(t); a.tick()
        try await a.sync(r); try await b.sync(r)
        #expect(b.doc.transactions.contains(t))
        // edit
        a.doc.transactions[a.doc.transactions.firstIndex { $0.id == t.id }!].quantity = 7; a.tick()
        try await a.sync(r); try await b.sync(r)
        #expect(b.doc.transactions.first { $0.id == t.id }?.quantity == 7)
        // portfolio rename + new portfolio
        try a.doc.renamePortfolio(pf, to: "long term")
        let p2 = try a.doc.createPortfolio(name: "swing", glyph: "λ"); a.tick()
        try await a.sync(r); try await b.sync(r)
        #expect(b.doc.portfolio(pf)?.name == "LONG TERM" && b.doc.portfolio(p2.id)?.glyph == "λ")
        // delete → tombstone, not a missing record
        b.doc.transactions.removeAll { $0.id == t.id }; b.tick()
        try await b.sync(r); try await a.sync(r)
        #expect(!a.doc.transactions.contains { $0.id == t.id })
        #expect(await r.records[SyncRecord.key(.transaction, t.id.uuidString)]?.isTombstone == true)
        // delete portfolio cascades via per-transaction tombstones
        a.doc.transactions.append(buy(p2.id, 1))
        try await a.sync(r); try await b.sync(r)
        try b.doc.deletePortfolio(p2.id); b.tick()
        try await b.sync(r); try await a.sync(r)
        #expect(a.doc.portfolio(p2.id) == nil && !a.doc.transactions.contains { $0.portfolioID == p2.id })
        #expect(Set(a.doc.transactions) == Set(b.doc.transactions) && Set(a.doc.portfolios) == Set(b.doc.portfolios))
    }

    @Test func offlineQueueRetries() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1)), b = Device("B")
        try await a.enable(r, .upload)
        try await b.enable(r, .useCloud)
        await r.setOffline(true)
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 2)); a.tick()
        await #expect(throws: SyncStoreError.offline) { try await a.sync(r) }
        // Edits made offline are not lost: detected and queued on the next attempt.
        SyncEngine.detectLocalChanges(a.doc, &a.syncState, now: a.clock)
        #expect(a.syncState.pendingCount == 1)
        await r.setOffline(false)
        try await a.sync(r); try await b.sync(r)
        #expect(a.syncState.pendingCount == 0 && b.doc.transactions.count == 2)
    }

    @Test func concurrentEditsNewerWinsOtherKeptForReview() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1)), b = Device("B")
        try await a.enable(r, .upload)
        try await b.enable(r, .useCloud)
        let id = a.doc.transactions[0].id
        a.doc.transactions[0].quantity = 2; a.tick(10)
        b.doc.transactions[0].quantity = 3; b.tick(20)   // later
        try await a.sync(r)
        try await b.sync(r)                              // server conflict: B newer → B's wins
        try await a.sync(r)
        #expect(a.doc.transactions.first { $0.id == id }?.quantity == 3)
        #expect(b.doc.transactions.first { $0.id == id }?.quantity == 3)
        let c = try #require(b.syncState.conflicts.first)
        #expect(c.kind == .transaction && c.reason.contains("kept the local"))
        // The losing version can be restored, and that restore syncs like any edit.
        SyncEngine.restore(c, &b.doc, &b.syncState); b.tick()
        try await b.sync(r); try await a.sync(r)
        #expect(a.doc.transactions.first { $0.id == id }?.quantity == 2)
        #expect(b.syncState.conflicts.isEmpty)
    }

    @Test func editBeatsDelete() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1)), b = Device("B")
        try await a.enable(r, .upload)
        try await b.enable(r, .useCloud)
        let id = a.doc.transactions[0].id
        a.doc.transactions.removeAll(); a.tick(10)
        b.doc.transactions[0].note = "keep me"; b.tick(5)
        try await a.sync(r)
        try await b.sync(r)
        try await a.sync(r)
        #expect(a.doc.transactions.first { $0.id == id }?.note == "keep me")
        #expect(b.doc.transactions.first { $0.id == id }?.note == "keep me")
        #expect(b.syncState.conflicts.first?.reason.contains("deleted on A") == true)
    }

    @Test func mergeUnionsByIDWithoutDuplicates() async throws {
        let r = MockRemote()
        let base = seeded(2)
        let a = Device("A", base)
        try await a.enable(r, .upload)
        // B restored the same backup, then added one of its own.
        var bd = base
        bd.transactions.append(buy(bd.portfolios[0].id, 9))
        let b = Device("B", bd)
        #expect(try await SyncEngine.inspect(b, remote: r).plan == .choose)
        try await b.enable(r, .merge)
        try await a.sync(r)
        #expect(b.doc.transactions.count == 3 && a.doc.transactions.count == 3)
        #expect(await r.liveCount == (1, 3))
        #expect(b.syncState.conflicts.isEmpty)
    }

    @Test func mergeRenamesDuplicatePortfolioNames() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1)), b = Device("B", seeded(1))   // two different MAINs
        try await a.enable(r, .upload)
        try await b.enable(r, .merge)
        try await a.sync(r)
        #expect(Set(a.doc.portfolios.map(\.name)) == ["MAIN", "MAIN 2"])
        #expect(a.doc.portfolios.sorted { $0.id.uuidString < $1.id.uuidString } == b.doc.portfolios.sorted { $0.id.uuidString < $1.id.uuidString })
        #expect(a.doc.validationErrors().isEmpty)
    }

    @Test func importWhileSyncingDoesNotDuplicate() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(2))
        try await a.enable(r, .upload)
        let backup = try PortfolioDocument.load(a.doc.encoded())   // export → import round trip
        a.doc = backup; a.tick()
        try await a.sync(r)
        #expect(await r.liveCount == (1, 2))
        #expect(a.syncState.pendingCount == 0)
    }

    @Test func newerSchemaRecordsAreNotAppliedOrOverwritten() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1))
        try await a.enable(r, .upload)
        let pf = a.doc.portfolios[0].id
        let future = SyncRecord(kind: .transaction, id: UUID().uuidString, schemaVersion: SyncRecord.currentSchema + 1,
                                modifiedAt: a.clock, deviceID: "x", payload: Data("{\"new\":true}".utf8), portfolioID: pf.uuidString)
        await r.inject(future)
        try await a.sync(r)
        #expect(a.doc.transactions.count == 1)
        #expect(a.syncState.blocked.contains(future.key))
        #expect(await r.records[future.key]?.schemaVersion == SyncRecord.currentSchema + 1)
    }

    @Test func accountChangeStopsSync() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(1))
        try await a.enable(r, .upload)
        await r.setUser("someone-else")
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 1))
        await #expect(throws: SyncStoreError.accountChanged) { try await a.sync(r) }
        #expect(await r.liveCount.transactions == 1)   // nothing pushed to the other account
        await r.setAccount(.noAccount)
        await #expect(throws: SyncStoreError.notAuthenticated) { try await a.sync(r) }
    }

    @Test func disableKeepsLocalAndCloudData() async throws {
        let r = MockRemote()
        let a = Device("A", seeded(2))
        try await a.enable(r, .upload)
        let before = a.doc
        SyncEngine.disable(a)
        #expect(a.doc == before)
        #expect(a.syncState.mode == .localOnly && a.syncState.known.isEmpty)
        #expect(await r.liveCount == (1, 2))
    }

    @Test func onlyDomainRecordsAreSynced() async throws {
        let r = MockRemote()
        var d = seeded(1)
        d.settings = AppSettings()
        let a = Device("A", d)
        try await a.enable(r, .upload)
        let kinds = Set(await r.records.values.map(\.kind))
        #expect(kinds == [.portfolio, .transaction, .asset])
        let payloads = await r.records.values.compactMap(\.payload).map { String(decoding: $0, as: UTF8.self) }
        #expect(!payloads.contains { $0.contains("refreshSeconds") || $0.contains("currency\":\"USD\",\"density") })   // no settings
    }

    @Test func oversoldAfterSyncStillLoadsLocally() throws {
        var d = seeded(1)
        d.transactions.append(Transaction(portfolioID: d.portfolios[0].id, assetID: btc.id, type: .sell, quantity: 5, price: 1, timestamp: Date(timeIntervalSince1970: 1_750_000_000)))
        let data = try d.encoded()
        #expect(throws: (any Error).self) { try PortfolioDocument.load(data) }   // imports stay strict
        #expect(try PortfolioDocument.load(data, ledgerChecks: false).transactions.count == 2)
    }
}
