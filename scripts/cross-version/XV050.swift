import Foundation
import Testing
import PFCore

// The 0.5.0 half of the upgrade/downgrade check (see docs/DEVELOPMENT.md): copy into
// PFCoreTests/ of a `v0.5.0` worktree. The 0.6 half is PFCoreTests/CrossVersionTests.swift.
struct XV050 {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PF_XV_DIR"] ?? "/nonexistent")
    let step = ProcessInfo.processInfo.environment["PF_XV_STEP"] ?? ""

    @Test func run() throws {
        let store = PortfolioStore(directory: dir)
        let settingsURL = dir.appendingPathComponent("settings.json")
        switch step {
        case "1-write-050":
            var d = PortfolioDocument.fresh()
            d.assets = [AssetCatalog.known.first { $0.symbol == "BTC" }!]
            d.transactions = (1...3).map { Transaction(portfolioID: d.portfolios[0].id, assetID: "cg:bitcoin", type: .buy, quantity: Decimal($0), price: 100, timestamp: Date(timeIntervalSince1970: 1_750_000_000 + Double($0) * 86400), note: $0 == 1 ? "first" : nil) }
            try store.save(d)
            var st = SyncState(); st.mode = .iCloud; st.deviceName = "xv"; st.token = Data("tok".utf8)
            SyncEngine.detectLocalChanges(d, &st, now: Date(timeIntervalSince1970: 1_760_000_000))
            for k in st.known.keys { st.known[k]?.pending = false; st.known[k]?.version = "v1" }
            SyncStateFile.save(st, to: dir)
            var s = AppSettings(); s.fallbackProvider = "CoinGecko"; s.appLock = true
            try JSONEncoder().encode(s).write(to: settingsURL)
            print("XV 0.5.0 wrote ledger \(d.transactions.count) tx · state \(st.known.count) records")
        case "3-read-050":
            let d = try #require(try store.load(), "0.5.0 reads the 0.6 ledger")
            let st = try #require(SyncStateFile.load(from: dir), "0.5.0 decodes the 0.6 sync state")
            let s = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
            #expect(d.transactions.count == 4 && d.transactions.contains { $0.note == "added by 0.6" })
            #expect(st.mode == .iCloud && st.known.count >= 6 && st.token != nil)
            #expect(s.appLock && s.fallbackProvider == "DexScreener", "missing key falls back to the 0.5 default")
            // 0.5 keeps working on it: one more edit, saved and queued.
            var d2 = d
            d2.transactions[0].note = "edited by 0.5.0"
            try store.save(d2)
            var st2 = st
            SyncEngine.detectLocalChanges(d2, &st2, now: Date(timeIntervalSince1970: 1_760_100_000))
            SyncStateFile.save(st2, to: dir)
            try JSONEncoder().encode(s).write(to: settingsURL)
            print("XV 0.5.0 read 0.6 data OK · pending \(st2.pendingCount)")
        default:
            break
        }
    }
}
