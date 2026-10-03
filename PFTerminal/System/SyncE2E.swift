#if DEBUG
import PFCore
import PFCoreUI
import AppKit
import CloudKit
import SwiftUI

/// DEBUG only: `--ui-testing --sync-e2e` proves the whole path
///   local ledger → SyncEngine → CloudKit (Development) → another local store → PortfolioEngine
/// with independent AppStore clients (own directory, ledger file, sync-state.json, preferences).
/// CloudKit is their only connection. Actions go through the same AppStore methods the UI calls.
/// Uses a throwaway zone (never PFZone) and deletes it at the end. Prints PASS/FAIL per check.
enum SyncE2E {
    /// CloudKit store with a switch to simulate losing connectivity.
    final class Link: SyncRemoteStore, @unchecked Sendable {
        let inner: CloudKitSyncStore
        var offline = false
        init(_ s: CloudKitSyncStore) { inner = s }
        func accountStatus() async -> SyncAccountStatus { offline ? .temporarilyUnavailable : await inner.accountStatus() }
        func accountID() async throws -> String? { if offline { throw SyncStoreError.offline }; return try await inner.accountID() }
        func fetchChanges(since t: Data?) async throws -> SyncFetchResult { if offline { throw SyncStoreError.offline }; return try await inner.fetchChanges(since: t) }
        func save(_ r: [SyncRecord]) async throws -> [SyncSaveOutcome] { if offline { throw SyncStoreError.offline }; return try await inner.save(r) }
    }

    /// `--render-conflicts`: render the conflict sheet for the running store with one injected
    /// conflict (in-memory store only) and print its height.
    @MainActor
    static func renderConflicts(_ s: AppStore) {
        guard ProcessInfo.processInfo.arguments.contains("--render-conflicts") else { return }
        let t = s.doc.transactions.first ?? Transaction(assetID: "cg:bitcoin", type: .buy, quantity: 1, price: 1, timestamp: Date())
        let rec = SyncRecord(kind: .transaction, id: t.id.uuidString, modifiedAt: Date(), deviceID: "x", deviceName: "other",
                             payload: try? SyncEngine.encoder.encode(t))
        s.syncState.conflicts = [SyncConflict(key: rec.key, kind: .transaction, reason: "edited here and on other · kept the local version", other: rec, detectedAt: Date())]
        s.syncSheet = .conflicts
        print("conflicts in store:", s.syncState.conflicts.count)
        let img = ImageRenderer(content: SyncSheetView().environment(s).background(Theme.bg)).nsImage
        print("rendered height:", img?.size.height ?? 0)
        if let d = img?.tiffRepresentation, let png = NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:]) {
            print("PFPNG render-conflicts \(png.base64EncodedString())")
        }
        exit(0)
    }

    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--sync-e2e") else { return }
        Task { @MainActor in
            let code = await run()
            exit(code)
        }
    }

    @MainActor
    static func run() async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
        func section(_ s: String) { print("\n== \(s)") }

        guard AppStore.hasCloudEntitlement, let cid = AppStore.cloudContainerID else { print("FAIL no CloudKit entitlement"); return 1 }
        let run = UUID().uuidString.prefix(8)
        let zoneName = "PFE2E-\(run)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-e2e-\(run)", isDirectory: true)
        print("container \(cid) · zone \(zoneName) · environment \(AppStore.cloudEnvironment) (from entitlement)")

        func client(_ name: String) -> AppStore {
            var o = AppStore.Options()
            o.directory = root.appendingPathComponent(name, isDirectory: true)
            o.mockMarket = true
            o.publishWidgets = false
            o.defaults = UserDefaults(suiteName: "pf-e2e-\(run)-\(name)")!
            o.syncRemote = Link(CloudKitSyncStore(containerIdentifier: cid, zoneName: zoneName))
            let s = AppStore(o)
            s.settings.onboarded = true
            return s
        }
        func link(_ s: AppStore) -> Link { s.syncRemote as! Link }

        func sync(_ s: AppStore) async {
            s.syncDebounce?.cancel()
            while let t = s.syncTask { await t.value }
            s.syncNow(reason: .manual)
            while let t = s.syncTask { await t.value }
        }
        func enable(_ s: AppStore, expect: SyncEngine.Plan, _ choice: SyncEngine.Choice?) async -> SyncEngine.Inspection? {
            s.beginEnableSync()
            for _ in 0..<600 where s.syncSheet == .checking { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard case let .confirm(i)? = s.syncSheet else { print("   sheet:", String(describing: s.syncSheet)); return nil }
            check(i.plan == expect, "comparison shows plan \(i.plan) (expected \(expect)) · local \(i.localPortfolios)p/\(i.localTransactions)tx · iCloud \(i.cloudPortfolios)p/\(i.cloudTransactions)tx")
            guard let choice else { s.syncSheet = nil; return i }
            s.confirmEnableSync(choice)
            while let t = s.syncTask { await t.value }
            return i
        }
        func add(_ s: AppStore, _ pid: UUID, _ type: TransactionType, _ asset: String, _ amt: String, _ price: String, _ date: String) -> Transaction? {
            s.openTx(TxDraft(portfolioID: pid, type: type, asset: asset, amount: amt, price: price, date: date))
            let before = Set(s.doc.transactions.map(\.id))
            guard let d = s.tx, s.preview(d).ok else { print("   draft rejected:", s.tx.map { s.preview($0).line } ?? "-"); s.tx = nil; return nil }
            s.confirmTx()
            return s.doc.transactions.first { !before.contains($0.id) }
        }
        func newPortfolio(_ s: AppStore, _ name: String) -> UUID? {
            s.openNewPortfolio(name); s.createPortfolio()
            return s.doc.portfolios.first { $0.name == name }?.id
        }
        func holdings(_ s: AppStore, _ pid: UUID) -> [String: String] {
            PortfolioEngine.positions(s.doc.transactions.filter { $0.portfolioID == pid })
                .mapValues { "\($0.quantity)|\($0.costBasis)|\($0.realizedPnL)" }
        }
        func sameLedger(_ a: AppStore, _ b: AppStore) -> Bool {
            Set(a.doc.transactions) == Set(b.doc.transactions) && Set(a.doc.portfolios) == Set(b.doc.portfolios)
        }
        func stateOnDisk(_ s: AppStore) -> SyncState? {
            (try? Data(contentsOf: s.files.directory.appendingPathComponent("sync-state.json"))).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) }
        }
        func cloud(_ s: AppStore) async -> [SyncRecord] {
            (try? await link(s).inner.fetchChanges(since: nil).records) ?? []
        }
        func live(_ r: [SyncRecord], _ k: SyncKind) -> [SyncRecord] { r.filter { $0.kind == k && !$0.isTombstone } }

        var A = client("A-mac"), B = client("B-iphone")

        // ------------------------------------------------------------------
        section("Scenario A · local data + empty iCloud → comparison → confirm → upload")
        A.createEmpty()
        let main = A.doc.portfolios[0].id
        let t1 = add(A, main, .buy, "BTC", "0.5", "42000", "2024-01-05")
        let t2 = add(A, main, .buy, "ETH", "4", "2250.50", "2024-02-10")
        _ = add(A, main, .sell, "BTC", "0.1", "61000", "2024-06-01")
        check(t1 != nil && t2 != nil && A.doc.transactions.count == 3, "client A: MAIN + 3 transactions recorded through the transaction sheet")
        _ = await enable(A, expect: .upload, .upload)
        check(A.syncStatus == .synced && A.syncState.pendingCount == 0, "A uploaded · status \(A.syncStatusLabel)")
        var recs = await cloud(A)
        check(live(recs, .portfolio).count == 1 && live(recs, .transaction).count == 3, "CloudKit holds 1 portfolio + 3 transactions")

        // ------------------------------------------------------------------
        section("Scenario B · empty local + iCloud data → download → validate → activate")
        check(!B.hasPortfolio && B.doc.transactions.isEmpty, "client B starts with an empty local store")
        _ = await enable(B, expect: .useCloud, .useCloud)
        check(B.syncStatus == .synced, "B activated · status \(B.syncStatusLabel)")
        check(B.doc.portfolios.map(\.id) == [main], "same portfolio UUID on B")
        check(Set(B.doc.transactions.map(\.id)) == Set(A.doc.transactions.map(\.id)), "same transaction UUIDs on B")
        check(Set(B.doc.transactions) == Set(A.doc.transactions), "same values and timestamps (Decimal-exact)")
        check(holdings(B, main) == holdings(A, main) && !holdings(B, main).isEmpty, "PortfolioEngine holdings identical: \(holdings(B, main).keys.sorted())")
        check(B.doc.validationErrors().isEmpty, "downloaded ledger validates")
        let Bdisk = try? PortfolioStore(directory: B.files.directory).load()
        check(Bdisk.map { Set($0.transactions) == Set(A.doc.transactions) } ?? false, "B's portfolio.json on disk has the data")

        // ------------------------------------------------------------------
        section("B → CloudKit → A")
        let t4 = add(B, main, .buy, "SOL", "25", "98.4", "2024-07-01")
        await sync(B); await sync(A)
        check(t4 != nil && A.doc.transactions.filter { $0.id == t4!.id }.count == 1, "B's new transaction appears on A exactly once")
        check(sameLedger(A, B) && holdings(A, main) == holdings(B, main), "A and B identical after round trip")

        // ------------------------------------------------------------------
        section("Multiple portfolios")
        let lt = newPortfolio(A, "LONG TERM"), tr = newPortfolio(A, "TRADING")
        if let lt, let tr {
            _ = add(A, lt, .buy, "BTC", "1", "30000", "2023-11-01")
            _ = add(A, lt, .buy, "ETH", "10", "1800", "2023-12-01")
            _ = add(A, tr, .buy, "SOL", "100", "60", "2024-03-01")
            _ = add(A, tr, .sell, "SOL", "40", "150", "2024-04-01")
        }
        await sync(A); await sync(B)
        check(Set(B.doc.portfolios.map(\.id)) == Set(A.doc.portfolios.map(\.id)) && B.doc.portfolios.count == 3, "3 portfolio IDs preserved on B")
        for p in A.doc.portfolios {
            let ta = Set(A.doc.transactions.filter { $0.portfolioID == p.id }), tb = Set(B.doc.transactions.filter { $0.portfolioID == p.id })
            check(ta == tb && holdings(A, p.id) == holdings(B, p.id), "\(p.name): same transactions and holdings on both (\(ta.count) tx)")
        }
        let allA = PortfolioEngine.positions(ledgers: A.doc.ledgers(.all)).mapValues { "\($0.quantity)|\($0.costBasis)" }
        let allB = PortfolioEngine.positions(ledgers: B.doc.ledgers(.all)).mapValues { "\($0.quantity)|\($0.costBasis)" }
        check(allA == allB, "ALL aggregate identical on both clients")
        if let tr { check(holdings(B, tr)["cg:bitcoin"] == nil, "TRADING not contaminated by other portfolios' BTC") }

        // ------------------------------------------------------------------
        section("Rename")
        A.startRename(main); A.manage.renameText = "core"; A.commitRename()
        await sync(A); await sync(B)
        check(B.doc.portfolio(main)?.name == "CORE", "B sees CORE with the same portfolio ID")
        check(B.doc.portfolios.count == 3 && !B.doc.portfolios.contains { $0.name == "MAIN" }, "no second portfolio created")

        // ------------------------------------------------------------------
        section("Archive")
        if let lt {
            let n = B.transactionCount(lt)
            B.toggleArchive(lt)
            await sync(B); await sync(A)
            check(A.doc.portfolio(lt)?.isArchived == true, "A received the archived state")
            check(A.transactionCount(lt) == n && n > 0, "archived portfolio kept its \(n) transactions")
            A.toggleArchive(lt); await sync(A); await sync(B)
            check(B.doc.portfolio(lt)?.isArchived == false, "unarchive propagated back")
        }

        // ------------------------------------------------------------------
        section("Delete propagation / tombstone")
        if let t4, let tx = A.doc.transactions.first(where: { $0.id == t4.id }) {
            A.deleteTx(tx)
            check(!A.doc.transactions.contains { $0.id == t4.id }, "deleted on A")
            await sync(A); await sync(B)
            check(!B.doc.transactions.contains { $0.id == t4.id }, "gone on B")
            await sync(B); await sync(A); await sync(B)
            check(!A.doc.transactions.contains { $0.id == t4.id } && !B.doc.transactions.contains { $0.id == t4.id }, "not resurrected after further syncs both ways")
            recs = await cloud(A)
            let r = recs.first { $0.key == SyncRecord.key(.transaction, t4.id.uuidString) }
            check(r?.isTombstone == true && r?.payload == nil, "CloudKit record is a tombstone (deletedAt set, no payload)")
            check(A.syncState.known[SyncRecord.key(.transaction, t4.id.uuidString)]?.deletedAt != nil
                  && B.syncState.known[SyncRecord.key(.transaction, t4.id.uuidString)]?.deletedAt != nil, "both clients track the tombstone")
        }

        // ------------------------------------------------------------------
        section("Offline queue")
        link(A).offline = true
        let off = add(A, main, .buy, "ETH", "0.75", "3100", "2024-08-15")
        check(off != nil && A.doc.transactions.contains { $0.id == off?.id }, "local write succeeds while offline")
        check(A.summary.positions.contains { $0.asset.id == "cg:ethereum" }, "portfolio updates locally")
        await sync(A)
        check(A.syncStatus == .offline, "status: \(A.syncStatusLabel)")
        let queued = stateOnDisk(A)
        check(queued?.known[SyncRecord.key(.transaction, off?.id.uuidString ?? "")]?.pending == true, "sync-state.json holds the pending transaction (\(queued?.pendingCount ?? 0) queued)")
        recs = await cloud(A)
        check(!recs.contains { $0.id == off?.id.uuidString }, "not in CloudKit yet")

        section("Restart with a queued change")
        let dirA = A.files.directory
        A = client("A-mac")   // new AppStore on the same directory + preferences = app restart
        check(A.files.directory == dirA && A.syncEnabled && A.syncState.pendingCount >= 1 && A.doc.transactions.contains { $0.id == off?.id },
              "after restart: sync still on, \(A.syncState.pendingCount) change(s) still queued, ledger intact")
        await sync(A); await sync(B)
        check(A.syncState.pendingCount == 0, "queue cleared after reconnect")
        check(B.doc.transactions.filter { $0.id == off?.id }.count == 1, "queued transaction reached B exactly once")

        // ------------------------------------------------------------------
        section("Conflicts")
        // (1) newer edit beats older edit — the older edit syncs last and still loses.
        let base = A.doc.transactions.first { $0.id == t2?.id }!
        B.editTx(B.doc.transactions.first { $0.id == base.id }!); B.tx?.note = "edit on B (older)"; B.confirmTx(); B.syncDebounce?.cancel()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        A.editTx(base); A.tx?.note = "edit on A (newer)"; A.confirmTx(); A.syncDebounce?.cancel()
        await sync(A); await sync(B); await sync(A)
        check(A.doc.transactions.first { $0.id == base.id }?.note == "edit on A (newer)" && B.doc.transactions.first { $0.id == base.id }?.note == "edit on A (newer)",
              "newer edit (A) won on both, although the older edit synced last")
        let c1 = B.syncState.conflicts.first { $0.key == SyncRecord.key(.transaction, base.id.uuidString) }
        check(c1 != nil && (c1?.other.payload).map { String(decoding: $0, as: UTF8.self).contains("edit on B (older)") } == true,
              "losing version kept for review on B: \(c1?.reason ?? "-")")

        // (2) edit beats delete.
        let victim = A.doc.transactions.first { $0.id == t1?.id }!
        let later = A.doc.transactions.filter { $0.portfolioID == main && $0.assetID == victim.assetID && $0.id != victim.id }
        for t in later { A.deleteTx(t) }   // the SELL depends on this BUY; remove it first so the delete is allowed
        await sync(A); await sync(B)
        A.deleteTx(A.doc.transactions.first { $0.id == victim.id }!); A.syncDebounce?.cancel()
        B.editTx(B.doc.transactions.first { $0.id == victim.id }!); B.tx?.note = "kept by edit"; B.confirmTx(); B.syncDebounce?.cancel()
        await sync(A); await sync(B); await sync(A)
        check(A.doc.transactions.first { $0.id == victim.id }?.note == "kept by edit", "edit beat delete: A got the transaction back with B's edit")
        let c2 = B.syncState.conflicts.first { $0.key == SyncRecord.key(.transaction, victim.id.uuidString) }
        check(c2?.other.isTombstone == true, "the delete is kept for review on B: \(c2?.reason ?? "-")")

        section("Conflict restore through the Settings conflict UI")
        B.go(.settings)
        check(B.syncStatusLabel.contains("conflict") || !B.syncState.conflicts.isEmpty, "Settings → DATA & SYNC lists \(B.syncState.conflicts.count) conflict(s)")
        B.syncSheet = .conflicts   // the "[ review · n ]" row's action
        let png = ImageRenderer(content: SyncSheetView().environment(B).frame(width: 580).background(Theme.bg)).nsImage?.tiffRepresentation
        if let png, let rep = NSBitmapImageRep(data: png)?.representation(using: .png, properties: [:]) {
            let url = root.appendingPathComponent("conflicts-sheet.png"); try? rep.write(to: url); print("   rendered:", url.path)
            print("PFPNG e2e-conflicts-sheet \(rep.base64EncodedString())")
        }
        let h = png.flatMap { NSBitmapImageRep(data: $0)?.pixelsHigh } ?? 0
        check(h > 250, "conflict review sheet renders its conflict rows (\(h) px tall)")
        if let c1 {
            B.resolveConflict(c1, useOther: true)          // "[ use other version ]"
            check(B.doc.transactions.first { $0.id == base.id }?.note == "edit on B (older)", "B restored the losing version locally")
            let dirB = B.files.directory
            B = client("B-iphone")                            // restart: restored state persisted
            check(B.files.directory == dirB && B.doc.transactions.first { $0.id == base.id }?.note == "edit on B (older)"
                  && !B.syncState.conflicts.contains { $0.id == c1.id }, "restore persisted across restart; conflict cleared")
            await sync(B); await sync(A)
            check(A.doc.transactions.first { $0.id == base.id }?.note == "edit on B (older)", "restored version synced to A")
        }
        if let c2 = B.syncState.conflicts.first { B.resolveConflict(c2, useOther: false) }   // "[ keep current ]"
        check(B.syncState.conflicts.isEmpty, "remaining conflict dismissed with keep current")
        check(sameLedger(A, B), "A and B converged after conflicts")

        // ------------------------------------------------------------------
        section("Scenario C · local data + iCloud data → merge / use iCloud (backup first)")
        let C = client("C-other")
        C.createEmpty()
        _ = add(C, C.doc.portfolios[0].id, .buy, "DOGE", "1000", "0.08", "2024-05-05")
        let cOriginal = C.doc
        _ = await enable(C, expect: .choose, .useCloud)
        let backup = C.snapshots.list().first { $0.reason == "before-icloud" }
        let backupDoc = backup.flatMap { try? C.snapshots.load($0) }
        check(backupDoc.map { Set($0.transactions.map(\.id)) == Set(cOriginal.transactions.map(\.id)) } ?? false, "USE ICLOUD: verified recovery snapshot of the local ledger first (\(backup?.id ?? "none"))")
        check(sameLedger(C, A), "USE ICLOUD: C now equals the iCloud dataset")
        let Dm = client("D-merge")
        Dm.createEmpty()
        let dTx = add(Dm, Dm.doc.portfolios[0].id, .buy, "ADA", "500", "0.45", "2024-05-06")
        let before = live(await cloud(A), .transaction).count
        _ = await enable(Dm, expect: .choose, .merge)
        await sync(A)
        check(Dm.doc.transactions.count == A.doc.transactions.count && A.doc.transactions.contains { $0.id == dTx?.id }, "MERGE: union of both sides on both clients")
        let after = live(await cloud(A), .transaction).count
        check(after == before + 1, "MERGE: exactly one new transaction in CloudKit (\(before) → \(after)), no duplicates")
        check(Set(A.doc.portfolios.map(\.name)).count == A.doc.portfolios.count, "MERGE: portfolio names unique (\(A.doc.portfolios.map(\.name).sorted()))")

        // ------------------------------------------------------------------
        section("Disable sync → local only")
        let cloudBefore = await cloud(A)
        let docBefore = A.doc
        A.syncSheet = .disable; A.confirmDisableSync()
        check(!A.syncEnabled && A.syncStatus == .localOnly && A.doc == docBefore, "A local-only; portfolios and transactions unchanged")
        let localOnly = add(A, A.doc.portfolios.first { $0.name == "CORE" }!.id, .buy, "BTC", "0.01", "65000", "2024-09-01")
        await sync(A); try? await Task.sleep(nanoseconds: 3_000_000_000)
        let cloudAfter = await cloud(A)
        check(cloudAfter.count == cloudBefore.count && !cloudAfter.contains { $0.id == localOnly?.id.uuidString }, "new local transaction NOT uploaded; iCloud copy unchanged (\(cloudAfter.count) records)")
        check(stateOnDisk(A)?.mode == .localOnly, "sync-state.json says localOnly")

        section("Scenario D · identical → enable without duplication")
        let E = client("E-identical")
        _ = await enable(E, expect: .useCloud, .useCloud)
        E.syncSheet = .disable; E.confirmDisableSync()
        let countE = live(await cloud(E), .transaction).count
        _ = await enable(E, expect: .resume, .merge)
        let countE2 = live(await cloud(E), .transaction).count
        check(E.syncEnabled && countE2 == countE && E.syncState.conflicts.isEmpty, "resume: sync on, no new records (\(countE2)), no conflicts")

        section("Re-enable sync on A (local change made while off)")
        _ = await enable(A, expect: .choose, .merge)
        await sync(B)
        check(B.doc.transactions.filter { $0.id == localOnly?.id }.count == 1, "change made while off reached B exactly once")
        check(sameLedger(A, B), "A and B identical after re-enable")

        // ------------------------------------------------------------------
        // 0.6 hardening soak: the same two clients, CloudKit Development, throwaway zone.
        func converged(_ what: String) async {
            await sync(A); await sync(B); await sync(A)
            let c = live(await cloud(A), .transaction)
            check(sameLedger(A, B), "\(what): A and B identical (\(A.doc.transactions.count) tx)")
            check(c.count == A.doc.transactions.count && Set(c.map(\.id)).count == c.count, "\(what): CloudKit holds exactly the ledger (\(c.count) live tx, no duplicates)")
            check(A.syncState.pendingCount == 0 && B.syncState.pendingCount == 0, "\(what): nothing left queued")
        }
        let core = A.doc.portfolios.first { $0.name == "CORE" }?.id ?? A.doc.portfolios[0].id

        section("Soak · repeated launch / foreground / reconnect")
        let soakBefore = live(await cloud(A), .transaction).count
        for i in 1...4 {
            A = client("A-mac")                                   // relaunch on the same directory
            A.syncNow(reason: .launch); while let t = A.syncTask { await t.value }
            A.syncNow(reason: .active); while let t = A.syncTask { await t.value }
            link(A).offline = true; A.syncNow(reason: .timer); while let t = A.syncTask { await t.value }
            check(A.syncStatus == .offline, "round \(i): offline pass keeps local data (\(A.doc.transactions.count) tx)")
            link(A).offline = false; A.syncNow(reason: .network); while let t = A.syncTask { await t.value }
        }
        check(live(await cloud(A), .transaction).count == soakBefore, "launch/foreground/reconnect wrote nothing new (\(soakBefore) live tx)")
        await converged("after relaunches")

        section("Soak · offline edits on both sides")
        link(A).offline = true; link(B).offline = true
        let offA = add(A, core, .buy, "ETH", "0.5", "3000", "2024-10-01")
        if let i = B.doc.transactions.firstIndex(where: { $0.portfolioID == core && $0.id != offA?.id }) { B.doc.transactions[i].note = "edited offline on B"; B.save() }
        await sync(A); await sync(B)
        check(A.syncStatus == .offline && B.syncStatus == .offline, "both offline: edits queued (A \(A.syncState.pendingCount), B \(B.syncState.pendingCount))")
        link(A).offline = false; link(B).offline = false
        await converged("offline edits")
        check(B.doc.transactions.contains { $0.id == offA?.id } && A.doc.transactions.contains { $0.note == "edited offline on B" }, "both offline edits survived")

        section("Soak · same-record conflict")
        if let x = A.doc.transactions.first(where: { $0.portfolioID == core }), let ia = A.doc.transactions.firstIndex(of: x), let ib = B.doc.transactions.firstIndex(where: { $0.id == x.id }) {
            A.doc.transactions[ia].note = "A's edit"; A.save()
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            B.doc.transactions[ib].note = "B's later edit"; B.save()
            await sync(A); await sync(B); await sync(A)
            check(A.doc.transactions.first { $0.id == x.id }?.note == "B's later edit" && B.doc.transactions.first { $0.id == x.id }?.note == "B's later edit", "newer edit wins on both")
            check(B.syncState.conflicts.contains { $0.key.hasSuffix(x.id.uuidString) } || A.syncState.conflicts.contains { $0.key.hasSuffix(x.id.uuidString) }, "the other version kept for review")
            A.syncState.conflicts.removeAll(); B.syncState.conflicts.removeAll()
        }
        await converged("conflict")

        section("Soak · delete vs stale copy")
        let stale = A.doc
        if let y = A.doc.transactions.first(where: { $0.portfolioID == core }) {
            A.deleteTx(y)
            await sync(A)
            let F = client("F-stale")
            F.doc = stale; F.save()                               // an old Mac with yesterday's ledger
            _ = await enable(F, expect: .choose, .merge)
            await sync(A); await sync(B)
            check(!A.doc.transactions.contains { $0.id == y.id } && !B.doc.transactions.contains { $0.id == y.id } && !F.doc.transactions.contains { $0.id == y.id },
                  "deleted transaction stays deleted on A, B and the stale Mac")
            check(F.syncState.conflicts.contains { $0.reason.contains("kept the delete") }, "the stale copy is kept for review, not resurrected")
            F.syncSheet = .disable; F.confirmDisableSync()
        }
        await converged("delete vs stale copy")

        section("Soak · reset local ledger while CloudKit has data")
        let cloudCount = live(await cloud(B), .transaction).count
        B.createEmpty()                                           // e.g. unreadable portfolio.json, then onboarding "1"
        await sync(B)
        check(live(await cloud(B), .transaction).count == cloudCount, "nothing deleted in CloudKit (\(cloudCount) live tx)")
        check(B.doc.transactions.count == cloudCount, "B recovered its ledger from iCloud (\(B.doc.transactions.count) tx)")
        await converged("reset ledger")

        section("Soak · interrupted sync")
        _ = add(A, core, .buy, "SOL", "3", "150", "2024-10-02")
        A.syncNow(reason: .manual)
        try? await Task.sleep(nanoseconds: 150_000_000)
        A.syncTask?.cancel()                                      // the pass is cut off mid-way
        while let t = A.syncTask { await t.value }
        await converged("after an interrupted pass")

        section("Soak · sync turned off during an active pass")
        let midTx = add(A, core, .buy, "LINK", "10", "12", "2024-10-03")
        A.syncNow(reason: .manual)
        A.syncSheet = .disable; A.confirmDisableSync()
        try? await Task.sleep(nanoseconds: 4_000_000_000)          // let the cancelled pass wind down
        check(!A.syncEnabled && A.syncState.known.isEmpty, "turned off: no sync bookkeeping written back by the old pass")
        _ = await enable(A, expect: .choose, .merge)
        await converged("re-enabled after mid-pass disable")
        check(B.doc.transactions.filter { $0.id == midTx?.id }.count == 1, "the edit made during the cancelled pass arrives exactly once")

        section("Soak · idempotent repeated sync")
        let saves = live(await cloud(A), .transaction).count
        for _ in 0..<3 { await sync(A); await sync(B) }
        check(live(await cloud(A), .transaction).count == saves && A.syncState.pendingCount == 0 && B.syncState.pendingCount == 0, "three more rounds change nothing")

        // ------------------------------------------------------------------
        section("What is in CloudKit")
        let raw = CKContainer(identifier: cid).privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var ckRecords: [CKRecord] = []
        if let ch = try? await raw.recordZoneChanges(inZoneWith: zone, since: nil) {
            ckRecords = ch.modificationResultsByID.values.compactMap { try? $0.get().record }
        }
        let types = Set(ckRecords.map(\.recordType))
        let fields = Set(ckRecords.flatMap { $0.allKeys() }).union(["payload (encrypted)"])
        print("   record types:", types.sorted(), "· records:", ckRecords.count)
        print("   fields:", fields.sorted())
        check(types == ["PFRecord"], "only PFRecord records")
        let allowed: [String: Set<String>] = [
            "portfolio": ["id", "name", "glyph", "createdAt", "status", "isDemo"],
            "transaction": ["id", "portfolioID", "assetID", "type", "quantity", "price", "currency", "timestamp", "fee", "note"],
            "asset": ["id", "symbol", "name", "coingeckoID", "binanceSymbol", "chain", "contractAddress", "decimals", "preferredSource"],
        ]
        var unexpected: Set<String> = []
        var kinds: [String: Int] = [:]
        for r in ckRecords {
            let kind = r["kind"] as? String ?? "?"
            kinds[kind, default: 0] += 1
            guard let p = r.encryptedValues["payload"] as? Data, let obj = try? JSONSerialization.jsonObject(with: p) as? [String: Any] else { continue }
            unexpected.formUnion(Set(obj.keys).subtracting(allowed[kind] ?? []))
        }
        print("   kinds:", kinds)
        check(Set(kinds.keys).isSubset(of: ["portfolio", "transaction", "asset"]), "only portfolio / transaction / asset records")
        check(unexpected.isEmpty, "payloads contain only domain fields\(unexpected.isEmpty ? "" : ": unexpected \(unexpected.sorted())")")
        let blob = ckRecords.compactMap { $0.encryptedValues["payload"] as? Data }.map { String(decoding: $0, as: UTF8.self) }.joined()
            + ckRecords.flatMap { r in r.allKeys().map { "\(r[$0] ?? "" as CKRecordValue)" } }.joined()
        for banned in ["refreshSeconds", "primaryProvider", "widget", "quote", "marketCap", "coingecko-api-key", "apiKey", "unrealized", "totalValue", "snapshot"] {
            check(!blob.localizedCaseInsensitiveContains(banned), "no \"\(banned)\" anywhere in CloudKit")
        }
        let zones = (try? await raw.allRecordZones().map(\.zoneID.zoneName)) ?? []
        check(!zones.contains("com.apple.coredata.cloudkit.zone"), "no SwiftData market-cache mirror zone (zones: \(zones.sorted()))")
        let mirror = A.cache.container.configurations.map { "\($0.cloudKitContainerIdentifier ?? "none")" }
        check(mirror.allSatisfy { $0 == "none" }, "MarketCache ModelConfiguration has no CloudKit container in this signed build (\(mirror))")

        // ------------------------------------------------------------------
        do { try await link(A).inner.deleteZone(); print("\ncleanup: zone \(zoneName) deleted") } catch { print("cleanup failed:", error) }
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "SYNC E2E PASSED" : "SYNC E2E FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
#endif
