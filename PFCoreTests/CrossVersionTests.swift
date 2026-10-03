import Foundation
import Testing
import PFCore

/// Upgrade/downgrade round trip with the real 0.5.0 PFCore: 0.5.0 → 0.6 → 0.5.0 → 0.6 on one
/// data directory. Runs only when driven by the steps in docs/DEVELOPMENT.md (PF_XV_DIR / PF_XV_STEP,
/// with the 0.5.0 half run from a `v0.5.0` worktree); skipped otherwise.
struct CrossVersionTests {
    let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PF_XV_DIR"] != nil)) func step() throws {
        let dir = URL(fileURLWithPath: env["PF_XV_DIR"]!)
        let store = PortfolioStore(directory: dir), snaps = SnapshotStore(directory: dir)
        let settingsURL = dir.appendingPathComponent("settings.json")
        switch env["PF_XV_STEP"] {
        case "2-upgrade-06":
            var d = try #require(try store.load(), "0.6 reads the 0.5.0 ledger")
            var st = try #require(SyncStateFile.load(from: dir), "0.6 decodes the 0.5.0 sync state")
            var s = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
            #expect(d.transactions.count == 3 && st.mode == .iCloud && st.pendingCount == 0 && s.appLock)
            #expect(st.matches(environment: "Production"), "a 0.5 state is a Production state")
            #expect(SyncEngine.detectLocalChanges(d, &st, now: Date(timeIntervalSince1970: 1_760_050_000)) == 0, "upgrading changes nothing to sync")
            d.transactions.append(Transaction(portfolioID: d.portfolios[0].id, assetID: "cg:bitcoin", type: .sell, quantity: 1, price: 200,
                                              timestamp: Date(timeIntervalSince1970: 1_755_000_000), note: "added by 0.6"))
            try store.save(d)
            SyncEngine.detectLocalChanges(d, &st, now: Date(timeIntervalSince1970: 1_760_050_000))
            st.environment = "Production"; st.recovering = .merge
            SyncStateFile.save(st, to: dir)
            try snaps.create(d, reason: .auto)
            s.depegAlerts = true
            try JSONEncoder().encode(s).write(to: settingsURL)
            print("XV 0.6 upgraded: \(d.transactions.count) tx · pending \(st.pendingCount) · snapshots \(snaps.list().count)")
        case "4-upgrade-again-06":
            let d = try #require(try store.load())
            let st = try #require(SyncStateFile.load(from: dir))
            let s = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
            #expect(d.transactions.contains { $0.note == "edited by 0.5.0" } && d.transactions.contains { $0.note == "added by 0.6" })
            #expect(st.mode == .iCloud && st.pendingCount >= 2, "0.6's queued change and 0.5's edit are both still queued")
            #expect(st.environment == nil || st.environment == "Production")
            let snap = try #require(snaps.list().first)
            let snapTx = try snaps.load(snap).transactions.count
            #expect(snaps.list().count == 1 && snapTx == 4, "0.5 left the snapshots alone")
            #expect(s.appLock && !s.depegAlerts, "0.5.0 drops settings it doesn't know; nothing else changes")
            print("XV 0.6 re-read OK: \(d.transactions.count) tx · pending \(st.pendingCount)")
        default:
            Issue.record("unknown PF_XV_STEP")
        }
    }
}
