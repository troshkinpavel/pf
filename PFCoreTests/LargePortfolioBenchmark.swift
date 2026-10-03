import Foundation
import Testing
import PFCore
import PFCoreTestSupport

@discardableResult
func measure(_ label: String, _ budget: Double, _ f: () -> Void) -> Double {
    let t = Date(); f(); let ms = Date().timeIntervalSince(t) * 1000
    print("⏱ \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(String(format: "%8.1f", ms)) ms")
    #expect(ms < budget, "\(label) took \(ms) ms")
    return ms
}

/// Prints timings (`swift test -c release --filter LargePortfolioBenchmark` for app-like numbers);
/// fails only on gross regressions.
struct LargePortfolioBenchmark {
    @Test func tenThousandTransactions() throws {
        let (d, quotes, series) = LargeFixture.make()
        let assets = Dictionary(uniqueKeysWithValues: d.assets.map { ($0.id, $0) })
        #expect(d.transactions.count == 10_000 && d.validationErrors().isEmpty)
        var s: PortfolioSummary!
        measure("summarize ALL", 5000) { s = PortfolioEngine.summarize(ledgers: d.ledgers(.all), assets: assets, quotes: quotes, now: LargeFixture.now) }
        measure("summarize one portfolio", 5000) { _ = PortfolioEngine.summarize(ledgers: d.ledgers(.portfolio(d.portfolios[0].id)), assets: assets, quotes: quotes, now: LargeFixture.now) }
        measure("contributions 30d", 5000) {
            _ = PortfolioEngine.contributions(d.transactions, quotes: quotes, start: LargeFixture.now.addingTimeInterval(-30 * 86400), now: LargeFixture.now) { _ in 400 }
        }
        measure("history chart ALL · 151 points", 5000) {
            _ = PortfolioHistoryEngine.chart(transactions: d.transactions, summary: s, range: .all, points: 151, series: series, now: LargeFixture.now)
        }
        measure("validate ledger", 5000) { _ = d.validationErrors() }
        var st = SyncState(); st.mode = .iCloud
        measure("sync: detect all as new", 5000) { SyncEngine.detectLocalChanges(d, &st, now: LargeFixture.now) }
        measure("sync: detect, nothing changed", 5000) { SyncEngine.detectLocalChanges(d, &st, now: LargeFixture.now) }
        let incoming = d.transactions.map { var t = $0; t.id = UUID(); return t }
        measure("import preview 10k into 10k", 5000) { _ = ImportPlanner.plan(incoming, into: d.portfolios[0].id, doc: d, knownAssets: Set(assets.keys)) }
        measure("duplicate scan", 5000) { _ = ImportPlanner.likelyDuplicates(in: d) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-bench-\(UUID().uuidString)")
        measure("snapshot write+verify", 5000) { _ = try? SnapshotStore(directory: dir).create(d, reason: .auto) }
        measure("encode + decode ledger", 5000) { _ = try? PortfolioDocument.load(d.encoded(), ledgerChecks: false) }
    }
}
