import Foundation
import Testing
import PFCore
import PFCoreTestSupport

// 0.8.4 audit: edge cases around deletes iCloud no longer has and assets sent with transactions.

private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private let eth = AssetCatalog.known.first { $0.symbol == "ETH" }!
private func buy(_ pf: UUID, _ q: Decimal, _ a: Asset = btc) -> Transaction {
    Transaction(portfolioID: pf, assetID: a.id, type: .buy, quantity: q, price: 100, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
}
@MainActor private func pair(_ n: Int) async throws -> (MockRemote, Device, Device) {
    var d = PortfolioDocument.fresh()
    d.assets = [btc]
    d.transactions = (0..<n).map { i in buy(d.portfolios[0].id, Decimal(i + 1)) }
    let r = MockRemote(), a = Device("A", d), b = Device("B")
    try await a.enable(r, .upload)
    try await b.enable(r, .useCloud)
    return (r, a, b)
}

@MainActor
struct StuckDeleteAuditTests {
    @Test func clearsOnlyTheIntendedDeleteAndLeavesTheLedgerAlone() async throws {
        let (r, a, b) = try await pair(3)
        let key = SyncRecord.key(.transaction, a.doc.transactions[0].id.uuidString)
        await r.vanish(key)
        let others = await r.records.filter { $0.key != key }.mapValues(\.remoteVersion)
        a.doc.transactions.removeFirst(); a.tick()
        let ledger = a.doc
        try await a.sync(r)
        #expect(a.doc == ledger, "reconciliation never edits the ledger")
        #expect(await r.records.filter { $0.key != key }.mapValues(\.remoteVersion) == others, "no other record rewritten")
        #expect(a.syncState.pendingCount == 0)
        try await b.sync(r)
        #expect(Set(b.doc.transactions) == Set(a.doc.transactions))
    }

    @Test func untaggedStaleDeleteLosesToANewerRecreatedTransaction() async throws {
        let (r, a, _) = try await pair(2)
        let t = a.doc.transactions[0], key = SyncRecord.key(.transaction, t.id.uuidString)
        a.doc.transactions.removeFirst(); a.tick()
        SyncEngine.detectLocalChanges(a.doc, &a.syncState, now: a.clock)
        // As after a `.missing` round: the delete goes out untagged next.
        a.syncState.known[key]?.tag = nil; a.syncState.known[key]?.version = nil
        // Meanwhile another device recreated it, later; A has already fetched past that change.
        var live = try #require(await r.records[key])
        live.modifiedAt = a.clock.addingTimeInterval(500); live.deviceName = "C"
        await r.inject(live)
        a.syncState.token = try await r.fetchChanges(since: a.syncState.token).token
        try await a.sync(r)
        #expect(await r.records[key]?.isTombstone == false, "the newer transaction stays in iCloud")
        #expect(a.doc.transactions.contains { $0.id == t.id }, "the newer transaction comes back")
        #expect(!a.syncState.conflicts.isEmpty, "and the lost delete is listed for review")
    }

    @Test func deleteMissingFromZoneAndAnEditElsewhereNeverLosesTheEdit() async throws {
        let (r, a, b) = try await pair(2)
        let t = a.doc.transactions[0], key = SyncRecord.key(.transaction, t.id.uuidString)
        a.doc.transactions.removeFirst(); a.tick()           // A deletes, not yet synced
        await r.vanish(key)
        b.clock = a.clock.addingTimeInterval(1000)           // B edits it later
        let i = try #require(b.doc.transactions.firstIndex { $0.id == t.id })
        b.doc.transactions[i].quantity = 9
        try await b.sync(r)
        try await a.sync(r)
        try await b.sync(r)
        try await a.sync(r)
        let bKept = b.doc.transactions.first { $0.id == t.id }?.quantity == 9
        #expect(bKept, "B keeps its newer edit")
        #expect(!b.syncState.conflicts.isEmpty, "the other device's delete is listed for review")
        #expect(a.doc.transactions.first { $0.id == t.id }?.quantity == 9, "A gets the edit back")
        #expect(b.syncState.pendingCount == 0 && a.syncState.pendingCount == 0, "nothing stuck")
        #expect(await r.records[key]?.isTombstone == false)
    }

    @Test func stuckDeleteSurvivesOfflineAndRelaunch() async throws {
        let (r, a, b) = try await pair(3)
        let key = SyncRecord.key(.transaction, a.doc.transactions[0].id.uuidString)
        await r.vanish(key)
        a.doc.transactions.removeFirst(); a.tick()
        await r.setOffline(true)
        await #expect(throws: (any Error).self) { try await a.sync(r) }
        #expect(a.syncState.known[key]?.pending == true)
        // One round reaches iCloud, then PF quits before the next.
        await r.setOffline(false)
        let sent = SyncEngine.pendingRecords(a.doc, a.syncState)
        let out = try await r.save(sent)
        var d = a.doc, s = a.syncState
        SyncEngine.applySaveOutcomes(sent: sent, out, &d, &s, now: a.clock)
        #expect(s.known[key]?.pending == true && s.known[key]?.tag == nil)
        // Relaunch from the files' encodings.
        let st = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(s))
        let doc = try PortfolioDocument.load(d.encoded())
        let a2 = Device("A", doc, clock: a.clock.addingTimeInterval(60)); a2.syncState = st
        try await a2.sync(r)
        #expect(a2.syncState.pendingCount == 0 && a2.doc == doc)
        try await b.sync(r)
        #expect(b.doc.transactions.count == 2)
    }

    @Test func transactionsAndAssetsGoOnceAndArriveTogether() async throws {
        let (r, a, b) = try await pair(1)
        let pf = a.doc.portfolios[0].id
        a.doc.upsert(buy(pf, 2, eth), asset: eth)
        a.doc.transactions.append(buy(pf, 3)); a.tick()
        SyncEngine.detectLocalChanges(a.doc, &a.syncState, now: a.clock)
        let keys = SyncEngine.pendingRecords(a.doc, a.syncState).map(\.key)
        #expect(keys.count == Set(keys).count, "no record twice in one save")
        #expect(keys.contains(SyncRecord.key(.asset, eth.id)) && keys.contains(SyncRecord.key(.asset, btc.id)))
        try await a.sync(r); try await b.sync(r)
        #expect(b.doc.validationErrors().isEmpty)
        #expect(Set(b.doc.assets.map(\.id)).count == b.doc.assets.count)
        #expect(Set(b.doc.transactions) == Set(a.doc.transactions))
        let saves = await r.saveCalls
        try await a.sync(r); try await b.sync(r)
        #expect(await r.saveCalls == saves, "nothing re-sent once synced")
    }

    @Test func sendingAssetsAlongNeverBringsBackADeletedTransaction() async throws {
        let (r, a, b) = try await pair(2)
        let gone = a.doc.transactions[0].id
        a.doc.transactions.removeFirst()
        a.doc.transactions.append(buy(a.doc.portfolios[0].id, 9)); a.tick()
        try await a.sync(r); try await b.sync(r); try await a.sync(r)
        #expect(!a.doc.transactions.contains { $0.id == gone } && !b.doc.transactions.contains { $0.id == gone })
        #expect(await r.records[SyncRecord.key(.transaction, gone.uuidString)]?.isTombstone == true)
    }

    @Test func aStuckEditCostsAtMostThreeSavesPerPass() async throws {
        let (r, a, _) = try await pair(1)
        await r.vanish(SyncRecord.key(.transaction, a.doc.transactions[0].id.uuidString))
        a.doc.transactions[0].quantity = 5; a.tick()
        let s0 = await r.saveCalls
        try await a.sync(r)
        #expect(await r.saveCalls - s0 <= 3)
    }

    @Test func intelDeleteMissingFromZoneClearsToo() async throws {
        let sol = AssetCatalog.known.first { $0.symbol == "SOL" }!
        var d = IntelDocument()
        d.watchlist = [WatchItem(asset: sol, addedAt: Date(timeIntervalSince1970: 1_800_000_000), priceAtAdd: 150)]
        d.scenarios = [PortfolioScenario(name: "BASE", key: "b", editedAt: Date(timeIntervalSince1970: 1_800_000_000), targets: [btc.id: ScenarioTarget(price: 150_000)])]
        let r = MockRemote(), a = IntelDevice("A", d), b = IntelDevice("B")
        try await a.sync(r); try await b.sync(r)
        let key = SyncRecord.key(.scenario, a.doc.scenarios[0].id.uuidString)
        await r.vanish(key)
        a.doc.scenarios = []; a.tick()
        try await a.sync(r)
        #expect(a.intelSyncState.pendingCount == 0, "the delete is done, not queued forever")
        #expect(await r.records[key]?.isTombstone == true)
        try await b.sync(r)
        #expect(b.doc.scenarios.isEmpty && b.doc.watchlist.count == 1, "only the scenario goes")
    }
}
