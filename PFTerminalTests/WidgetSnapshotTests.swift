import Foundation
import Testing
@testable import PFTerminal

struct WidgetSnapshotTests {
    func make(_ privacy: WidgetPrivacyMode, isStale: Bool = false, empty: Bool = false) async throws -> WidgetPortfolioSnapshot {
        let q = try await MockMarketDataProvider().quotes(for: MockMarketDataProvider.assets, currency: "USD")
        let a = Dictionary(uniqueKeysWithValues: MockMarketDataProvider.assets.map { ($0.id, $0) })
        let txs = empty ? [] : DemoPortfolio.transactions()
        let s = PortfolioEngine.summarize(transactions: txs, assets: a, quotes: q)
        let mv = MoversEngine.movers(summary: s, transactions: txs, quotes: q, series: [:], range: .h24, now: Date())
        return WidgetSnapshotBuilder.build(.init(
            summary: s, movers24h: mv, performance: [1, 0.98, 1.01, 1.035], performanceStart: Date().addingTimeInterval(-86400),
            performanceRange: "24H", performanceChangePercent: 3.5, hasPortfolio: !empty, quotesAsOf: Date(), refreshInterval: 60,
            isStale: isStale, privacy: privacy, currency: "USD", numberStyle: .comma, now: Date()))
    }

    @Test func fullSnapshotCarriesPrototypeFigures() async throws {
        let s = try await make(.full)
        #expect(s.fmt.money(s.portfolioValue) == "$48,286.22")
        #expect(s.fmt.pct(s.dailyChangePercent) == "+3.51%")
        #expect(s.gainers.first?.symbol == "TEL")
        #expect(s.impact.first?.id == "cg:telcoin")          // canonical ids, not tickers
        #expect(s.positions.first?.symbol == "BTC")
        #expect(s.performance.count == WidgetSnapshotBuilder.chartPoints)
        #expect(s.performance.allSatisfy { (0...1).contains($0.normalizedValue) })
    }

    @Test func privacyModeRemovesEveryAmount() async throws {
        let s = try await make(.percentageOnly)
        #expect(s.portfolioValue == nil)
        #expect(s.dailyChangeValue == nil)
        #expect(s.unrealizedPnL == nil)
        #expect(s.positions.allSatisfy { $0.value == nil })
        #expect((s.gainers + s.impact).allSatisfy { $0.impact == nil })
        #expect(s.dailyChangePercent != nil, "percentages stay")
        // Not just nil fields: no amount appears anywhere in the stored JSON.
        let json = String(data: try WidgetSnapshotStore.encoder.encode(s), encoding: .utf8)!
        // Match at the start of a JSON value only: timestamps are Doubles and can contain these digit runs.
        for leak in ["48286", "18402", "1639", "15977"] {
            #expect(!json.contains(":\(leak)") && !json.contains(":\"\(leak)") && !json.contains(":-\(leak)"), "leaked \(leak)")
        }
    }

    @Test func encodeDecodeRoundTripAndAtomicFile() async throws {
        let s = try await make(.full)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-widget-\(UUID().uuidString)/widget-snapshot.json")
        try WidgetSnapshotStore.write(s, to: url)
        #expect(WidgetSnapshotStore.read(from: url) == s)
        try Data("{\"schemaVersion\":99}".utf8).write(to: url)
        #expect(WidgetSnapshotStore.read(from: url) == nil, "newer schema is ignored, never crashes")
        #expect(WidgetSnapshotStore.read(from: nil) == nil)
    }

    @Test func freshnessStates() async throws {
        var s = try await make(.full)
        let t0 = s.quotesAsOf!
        #expect(WidgetFreshness.evaluate(s, now: t0.addingTimeInterval(20)) == .fresh(20))
        #expect(WidgetFreshness.evaluate(s, now: t0.addingTimeInterval(120)) == .aging(120))
        #expect(WidgetFreshness.evaluate(s, now: t0.addingTimeInterval(3 * 3600)).isStale)
        s.isStale = true
        #expect(WidgetFreshness.evaluate(s, now: t0.addingTimeInterval(5)).isStale, "app-reported staleness wins")
        #expect(WidgetFreshness.ageLabel(30) == "now")
        #expect(WidgetFreshness.ageLabel(3 * 3600) == "3h")
    }

    @Test func emptyPortfolioHasNoValue() async throws {
        let s = try await make(.full, empty: true)
        #expect(!s.hasPortfolio)
        #expect(s.portfolioValue == nil, "never $0.00 for missing data")
        #expect(Fmt().money(s.portfolioValue) == "$—")
    }

    @Test func deepLinks() {
        #expect(PFLink.route(PFLink.portfolio) == .portfolio)
        #expect(PFLink.route(PFLink.asset("cg:bitcoin")) == .asset("cg:bitcoin"))
        #expect(PFLink.route(URL(string: "pfterminal://asset/TEL")!) == .asset("TEL"))
        #expect(PFLink.route(URL(string: "https://example.com")!) == nil)
    }
}
