import Foundation
import Testing
import PFCore

// 0.7 Portfolio Intelligence domain: watchlist, alerts, scenarios, attribution, benchmark, store.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let btc = Asset(id: "cg:bitcoin", symbol: "BTC", name: "Bitcoin", coingeckoID: "bitcoin")
private let tel = Asset(id: "cg:telcoin", symbol: "TEL", name: "Telcoin", coingeckoID: "telcoin")
private let fakeTel = Asset(id: "dex:base:0xfake", symbol: "TEL", name: "Not Telcoin", chain: "base", contractAddress: "0xfake")
private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!
private func q(_ p: Decimal, ch: Double? = nil, at: Date = t0) -> Quote { Quote(price: p, change: ch.map { [.h24: $0] } ?? [:], source: "t", timestamp: at) }
private let pf = UUID()
private func tx(_ a: Asset, _ type: TransactionType, _ qty: Decimal, _ p: Decimal, _ at: Date) -> Transaction {
    Transaction(portfolioID: pf, assetID: a.id, type: type, quantity: qty, price: p, timestamp: at)
}

struct WatchlistTests {
    @Test func addRemoveAndCanonicalIdentity() {
        var d = IntelDocument()
        let a = Watchlist.add(tel, price: 0.02, entry: 0.015, to: &d, now: t0)
        let again = Watchlist.add(tel, price: 0.03, target: 0.05, to: &d, now: t0.addingTimeInterval(60))
        #expect(d.watchlist.count == 1 && again.id == a.id && d.watchlist[0].target == 0.05 && d.watchlist[0].priceAtAdd == 0.02, "same asset: updated, not duplicated")
        Watchlist.add(fakeTel, price: 1, to: &d, now: t0)
        #expect(d.watchlist.count == 2, "same ticker, different asset: two items (no ticker collision)")
        Watchlist.remove(a.id, from: &d)
        #expect(d.watchlist.map(\.assetID) == [fakeTel.id])
    }

    @Test func rowMathsAndOrder() {
        var d = IntelDocument()
        Watchlist.add(tel, price: 0.02, entry: 0.018, to: &d, now: t0)
        Watchlist.add(btc, price: 100_000, entry: 90_000, to: &d, now: t0)
        Watchlist.add(fakeTel, price: 1, to: &d, now: t0)
        let rows = Watchlist.rows(d.watchlist, quotes: [tel.id: q(0.017), btc.id: q(95_000)])
        #expect(rows.map(\.item.assetID) == [tel.id, btc.id, fakeTel.id], "closest to entry first, no entry last")
        #expect(rows[0].atEntry && abs(rows[0].sinceAdded! - (-15)) < 1e-9)
        #expect(!rows[1].atEntry && abs(rows[1].toEntry! - (90_000.0 / 95_000 - 1) * 100) < 1e-9)
        #expect(rows[2].price == nil && rows[2].sinceAdded == nil, "no quote: shown as —, never 0")
    }

    @Test func conversionCarriesOverAndCanBeUndone() {
        var d = IntelDocument()
        let w = Watchlist.add(tel, price: 0.02, entry: 0.015, target: 0.05, note: "thesis", to: &d, now: t0)
        d.alerts.append(AlertRule(number: 1, kind: .priceBelow, subject: .asset(tel.id), threshold: 0.015, createdAt: t0))
        let tx = UUID()
        let before = WatchConversion.apply(w, tx: tx, carry: .init(), to: &d, now: t0)
        #expect(d.watchlist[0].archivedAt != nil && d.watchlist[0].convertedTx == tx, "archived, not deleted")
        #expect(Scenarios.base(d)?.targets[tel.id]?.price == 0.05, "target → Base scenario")
        #expect(d.alerts.first { $0.number == 1 }?.paused == true && d.alerts.contains { $0.kind == .priceAbove && $0.threshold == 0.05 })
        d = before
        #expect(d.watchlist[0].isActive && d.alerts.count == 1 && d.scenarios.isEmpty, "⌘Z restores the intel state")
        let r = WatchConversion.review(w, quantity: 1000, price: 0.016, fee: 0, portfolioValue: 84)
        #expect(abs(r.vsWatchAdd! - (-20)) < 1e-9 && abs(r.vsEntry! - (0.016 / 0.015 - 1) * 100) < 1e-9 && abs(r.weightAfter! - 16) < 1e-9)
    }
}

struct AlertTests {
    private func inputs(_ prices: [AssetID: Decimal], at: Date = t0, stale: Bool = false) -> AlertInputs {
        AlertInputs(now: at, quotes: prices.mapValues { q($0, at: stale ? at.addingTimeInterval(-3600) : at) }, staleAfter: 900, held: Set(prices.keys))
    }

    @Test func firesOnceOnCrossingAndStaysQuiet() {
        var rules = [AlertRule(number: 1, kind: .priceBelow, subject: .asset(tel.id), threshold: 0.02, createdAt: t0)]
        #expect(AlertEngine.evaluate(&rules, inputs([tel.id: 0.021])).isEmpty)
        #expect(AlertEngine.evaluate(&rules, inputs([tel.id: 0.019])).map(\.number) == [1])
        #expect(rules[0].state == .fired && rules[0].unseen)
        #expect(AlertEngine.evaluate(&rules, inputs([tel.id: 0.018])).isEmpty, "no repeat while still true")
        #expect(AlertEngine.evaluate(&rules, inputs([tel.id: 0.05])).isEmpty && rules[0].state == .fired, "once: re-arm only by hand")
    }

    @Test func everyCrossReArmsPastHysteresis() {
        var rules = [AlertRule(number: 1, kind: .priceAbove, subject: .asset(btc.id), threshold: 100, repeatMode: .cross, hysteresis: 2, createdAt: t0)]
        #expect(AlertEngine.evaluate(&rules, inputs([btc.id: 101])).count == 1)
        _ = AlertEngine.evaluate(&rules, inputs([btc.id: 99]))
        #expect(rules[0].state == .fired, "inside the reset band: not re-armed")
        #expect(AlertEngine.evaluate(&rules, inputs([btc.id: 100.5])).isEmpty, "hovering on the line doesn't spam")
        _ = AlertEngine.evaluate(&rules, inputs([btc.id: 97]))
        #expect(rules[0].state == .armed)
        #expect(AlertEngine.evaluate(&rules, inputs([btc.id: 102])).count == 1, "a new crossing fires again")
    }

    @Test func dailyFiresAtMostOncePerDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var rules = [AlertRule(number: 1, kind: .move24h, subject: .anyHeld, threshold: 10, repeatMode: .daily, createdAt: t0)]
        let i = { (at: Date) in AlertInputs(now: at, quotes: [tel.id: q(1, ch: 12, at: at)], staleAfter: 900, held: [tel.id]) }
        #expect(AlertEngine.evaluate(&rules, i(t0), calendar: cal).count == 1)
        #expect(AlertEngine.evaluate(&rules, i(t0.addingTimeInterval(3600)), calendar: cal).isEmpty)
        #expect(AlertEngine.evaluate(&rules, i(t0.addingTimeInterval(86400)), calendar: cal).count == 1, "next day: once more")
    }

    @Test func pausedAndStaleNeverFire() {
        var rules = [AlertRule(number: 1, kind: .priceAbove, subject: .asset(btc.id), threshold: 1, paused: true, createdAt: t0),
                     AlertRule(number: 2, kind: .priceAbove, subject: .asset(btc.id), threshold: 1, createdAt: t0)]
        #expect(AlertEngine.evaluate(&rules, inputs([btc.id: 5], stale: true)).isEmpty, "stale price: nothing fires")
        #expect(AlertEngine.evaluate(&rules, inputs([btc.id: 5])).map(\.number) == [2], "paused rule skipped")
        #expect(AlertEngine.evaluate(&rules, AlertInputs(now: t0, quotes: [:], staleAfter: 900, held: [])).isEmpty, "no price at all: nothing")
    }

    @Test func portfolioWeightPnlDrawdownAndDepeg() {
        var rules = [
            AlertRule(number: 1, kind: .weightAbove, subject: .asset(tel.id), threshold: 40, createdAt: t0),
            AlertRule(number: 2, kind: .pnlAbove, subject: .asset(tel.id), threshold: 25, createdAt: t0),
            AlertRule(number: 3, kind: .drawdown, subject: .portfolio("all"), threshold: 20, createdAt: t0),
            AlertRule(number: 4, kind: .valueAbove, subject: .portfolio("all"), threshold: 25_000, createdAt: t0),
            AlertRule(number: 5, kind: .depeg, subject: .anyStablecoin, threshold: 0.5, repeatMode: .cross, createdAt: t0),
        ]
        let peg = Stablecoins.check(usdc.id, quote: q(0.99), currency: "USD")!
        let i = AlertInputs(now: t0, quotes: [tel.id: q(1), usdc.id: q(0.99)], staleAfter: 900, held: [tel.id, usdc.id],
                            positionPnL: [tel.id: 30], weights: [tel.id: 39.7], portfolioValues: ["all": 19_415], drawdowns: ["all": -21], pegs: [usdc.id: peg])
        #expect(Set(AlertEngine.evaluate(&rules, i).map(\.number)) == [2, 3, 5])
        #expect(abs(AlertEngine.distance(rules[0], AlertEngine.read(rules[0], i), i)! - 0.3) < 1e-9, "weight 0.3pp away")
        #expect(abs(AlertEngine.distance(rules[3], AlertEngine.read(rules[3], i), i)! - (25_000 / 19_415.0 - 1) * 100) < 1e-6)
    }

    @Test func persistenceDeletionAndMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-intel-\(UUID().uuidString)")
        let store = IntelStore(directory: dir)
        #expect(try store.load() == nil)
        var d = IntelDocument()
        d.migrateNotifications(alertThreshold: 5, depegAlerts: true, now: t0)
        d.migrateNotifications(alertThreshold: 5, depegAlerts: true, now: t0)
        #expect(d.alerts.map(\.kind) == [.move24h, .depeg] && d.alerts.map(\.number) == [1, 2], "migrated once, idempotent")
        d.alerts[0].state = .fired; d.alerts[0].firedAt = t0
        try store.save(d)
        var back = try #require(try store.load())
        #expect(back == d)
        back.alerts.removeAll { $0.number == 1 }
        try store.save(back)
        #expect(try store.load()?.alerts.map(\.number) == [2])
        try Data(#"{"schemaVersion":99,"alerts":[]}"#.utf8).write(to: store.url)
        #expect(throws: IntelStoreError.newerSchema(99)) { try store.load() }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)   // exists, can't be read as data
        #expect(throws: IntelStoreError.unavailable) { try store.load() }
        #expect(FileManager.default.fileExists(atPath: store.url.path), "an unreadable-right-now file is never treated as missing")
    }

    @Test func notificationMigrationIsExactAndIdempotent() {
        var d = IntelDocument()
        d.migrateNotifications(alertThreshold: 5, depegAlerts: true, now: t0)
        let move = d.alerts[0]
        #expect(move.kind == .move24h && move.subject == .portfolio(AlertSubject.activePortfolio) && move.threshold == 5 && move.repeatMode == .daily)
        #expect(d.alerts[1].kind == .depeg && d.alerts[1].subject == .anyStablecoin && d.alerts[1].repeatMode == .cross, "depeg unchanged")
        for _ in 0..<3 { d.migrateNotifications(alertThreshold: 9, depegAlerts: true, now: t0) }
        #expect(d.alerts.count == 2 && d.alerts[0].threshold == 5, "once: no duplicates, later 0.6 values ignored")
        var off = IntelDocument()
        off.migrateNotifications(alertThreshold: 0, depegAlerts: false, now: t0)
        #expect(off.alerts.isEmpty && off.migrations.contains("0.6-notifications"))
    }

    @Test func earlyPerAssetMigrationIsPutBack() {
        // What the first 0.7 build wrote: the 0.6 rule as "any held asset", plus a user rule.
        var d = IntelDocument()
        d.migrations = ["0.6-notifications"]
        d.alerts = [AlertRule(number: 1, kind: .move24h, subject: .anyHeld, threshold: 5, repeatMode: .daily, createdAt: t0, note: IntelDocument.moveNote),
                    AlertRule(number: 2, kind: .move24h, subject: .anyHeld, threshold: 15, repeatMode: .daily, createdAt: t0)]
        d.alerts[0].state = .fired; d.alerts[0].firedAt = t0
        d.migrateNotifications(alertThreshold: 5, depegAlerts: false, now: t0)
        d.migrateNotifications(alertThreshold: 5, depegAlerts: false, now: t0)
        #expect(d.alerts.count == 2)
        #expect(d.alerts[0].subject == .portfolio(AlertSubject.activePortfolio) && d.alerts[0].number == 1 && d.alerts[0].state == .fired, "same rule, state kept")
        #expect(d.alerts[1].subject == .anyHeld, "a rule the user made is left alone")
    }

    @Test func portfolioMoveReadsThePortfolioChange() {
        var rules = [AlertRule(number: 1, kind: .move24h, subject: .portfolio("active"), threshold: 5, repeatMode: .daily, createdAt: t0)]
        let quiet = AlertInputs(now: t0, quotes: [:], staleAfter: 600, held: [], portfolioChange24h: ["active": 1.2])
        #expect(AlertEngine.evaluate(&rules, quiet).isEmpty)
        let loud = AlertInputs(now: t0, quotes: [:], staleAfter: 600, held: [], portfolioChange24h: ["active": -6.1])
        #expect(AlertEngine.evaluate(&rules, loud).count == 1)
        #expect(AlertEngine.evaluate(&rules, loud).isEmpty, "daily: once per day")
        let unpriced = AlertInputs(now: t0.addingTimeInterval(86400 * 2), quotes: [:], staleAfter: 600, held: [])
        #expect(AlertEngine.read(rules[0], unpriced) == nil, "no portfolio figure (partial prices): never fires")
    }

    @Test func unreadableFileIsSetAsideNeverLost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-intel-bad-\(UUID().uuidString)")
        let store = IntelStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        #expect(throws: IntelStoreError.unreadable) { try store.load() }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("intel.unreadable-") } && !names.contains("intel.json"), "moved aside, not deleted")
        try store.save(IntelDocument()); try store.save(IntelDocument())
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("intel.prev.json").path), "previous version kept")
    }

    @Test func quietHoursWrapMidnight() {
        var s = AppSettings(); s.quietHours = "22–07"
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int) in c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: h))! }
        #expect(s.isQuiet(at(23), calendar: c) && s.isQuiet(at(3), calendar: c) && !s.isQuiet(at(7), calendar: c) && !s.isQuiet(at(12), calendar: c))
        s.quietHours = "off"
        #expect(!s.isQuiet(at(23), calendar: c))
    }

    @Test func commandGrammar() {
        let asset = { (s: String) -> AssetID? in ["ada": "cg:cardano", "tel": tel.id, "usdt": "cg:tether"][s] }
        let pf = { (s: String) -> String? in s == "main" ? "uuid-main" : nil }
        func p(_ l: String) -> AlertCommand.Draft? { try? AlertCommand.parse(l, asset: asset, portfolio: pf, style: .comma).get() }
        #expect(p("alert ada below .24") == .init(kind: .priceBelow, subject: .asset("cg:cardano"), threshold: 0.24))
        #expect(p("alert tel above .02")?.kind == .priceAbove)
        #expect(p("alert usdt depeg .5") == .init(kind: .depeg, subject: .asset("cg:tether"), threshold: 0.5))
        #expect(p("alert main drawdown 60") == .init(kind: .drawdown, subject: .portfolio("uuid-main"), threshold: 60))
        #expect(p("alert main value above 25k") == .init(kind: .valueAbove, subject: .portfolio("uuid-main"), threshold: 25_000))
        #expect(p("alert any move 15") == .init(kind: .move24h, subject: .anyHeld, threshold: 15))
        #expect(p("alert tel weight 40")?.kind == .weightAbove && p("alert tel target")?.kind == .target)
        #expect(p("alert tel pnl above 25") == .init(kind: .pnlAbove, subject: .asset(tel.id), threshold: 25))
        #expect(p("alert zzz above 1") == nil && p("alert tel above") == nil && p("alert tel depeg") == nil, "invalid rules are rejected, never created")
    }

    @Test func backtestCountsCrossingsWithHysteresis() {
        let s = PriceSeries([1.0, 0.9, 0.95, 0.9, 1.1, 0.9].enumerated().map { PricePoint(time: t0.addingTimeInterval(Double($0.offset) * 3600), price: $0.element) })
        let r = AlertRule(number: 1, kind: .priceBelow, subject: .asset(tel.id), threshold: 0.92, hysteresis: 2, createdAt: t0)
        #expect(AlertEngine.backtest(r, series: s)?.count == 3)
    }
}

struct ScenarioTests {
    @Test func createEditDuplicateDeleteAndProject() {
        var d = IntelDocument()
        Scenarios.createPresets(in: &d, prices: [tel.id: 0.02, btc.id: 100_000], now: t0)
        Scenarios.createPresets(in: &d, prices: [:], now: t0)
        #expect(d.scenarios.map(\.key) == ["c", "b", "u"], "presets once")
        let base = Scenarios.base(d)!
        Scenarios.setTarget(tel.id, price: 0.05, in: base.id, doc: &d, now: t0)
        let copy = Scenarios.duplicate(base.id, in: &d, now: t0)!
        #expect(copy.name == "BASE COPY" && copy.targets[tel.id]?.price == 0.05)
        #expect(Scenarios.rename(copy.id, to: "moon", in: &d, now: t0) && !Scenarios.rename(copy.id, to: "bull", in: &d, now: t0))
        Scenarios.delete(copy.id, in: &d)
        #expect(d.scenarios.count == 3)

        let holdings = [Scenarios.Holding(asset: tel.id, quantity: 100_000, price: 0.02), Scenarios.Holding(asset: btc.id, quantity: 0.1, price: 100_000),
                        Scenarios.Holding(asset: usdc.id, quantity: 500, price: Decimal(string: "0.999")!)]
        let p = Scenarios.project(Scenarios.base(d)!, holdings: holdings)
        #expect(p.valueNow == Decimal(string: "12499.5")! && p.projected == 15_500)
        #expect(p.rows.first { $0.asset == usdc.id }?.share == nil && p.rows.first { $0.asset == usdc.id }?.target == 1, "stablecoin fixed at peg, no share")
        #expect(p.rows.first { $0.asset == tel.id }?.share == Double(3000) / 3000, "only TEL has upside")
    }

    @Test func scenariosNeverTouchAccounting() {
        let txs = [tx(tel, .buy, 1000, 0.01, t0)]
        let before = PortfolioEngine.summarize(transactions: txs, assets: [tel.id: tel], quotes: [tel.id: q(0.02)], now: t0)
        var d = IntelDocument()
        Scenarios.createPresets(in: &d, prices: [tel.id: 0.02], now: t0)
        Scenarios.setTarget(tel.id, price: 10, in: Scenarios.base(d)!.id, doc: &d, now: t0)
        _ = Scenarios.project(Scenarios.base(d)!, holdings: [.init(asset: tel.id, quantity: 1000, price: 0.02)])
        let after = PortfolioEngine.summarize(transactions: txs, assets: [tel.id: tel], quotes: [tel.id: q(0.02)], now: t0)
        #expect(before.totalValue == after.totalValue && before.totalPnL == after.totalPnL)
    }
}

struct AttributionTests {
    private let start = t0, end = t0.addingTimeInterval(86400)

    @Test func depositsAreExcludedFromPerformance() {
        // Held 1 BTC @100 → 110 (+10 market move); bought 1 more at 105 during the day (money in 105).
        let txs = [tx(btc, .buy, 1, 100, t0.addingTimeInterval(-86400)), tx(btc, .buy, 1, 105, t0.addingTimeInterval(3600))]
        let r = Attribution.compute(ledgers: [txs], endPrices: [btc.id: 110], start: start, end: end) { _ in 100 }
        #expect(r.startValue == 100 && r.endValue == 220 && r.change == 120)
        #expect(r.moneyIn == 105 && r.flows == 105 && r.buys == 1)
        #expect(r.marketMove == 15, "10 on the old coin + 5 on the new one; the 105 deposit is not performance")
        #expect(r.change == r.marketMove + r.flows, "identity: change = market move + flows")
    }

    @Test func withdrawalsAndRealizedPnL() {
        // 2 BTC avg 100; sell 1 at 150 during the window; price ends at 160.
        let txs = [tx(btc, .buy, 2, 100, t0.addingTimeInterval(-86400)), tx(btc, .sell, 1, 150, t0.addingTimeInterval(3600))]
        let r = Attribution.compute(ledgers: [txs], endPrices: [btc.id: 160], start: start, end: end) { _ in 140 }
        #expect(r.moneyOut == -150 && r.sells == 1)
        #expect(r.realized == 50, "sold at 150 vs avg 100, booked inside the window")
        #expect(r.marketMove.double == 30, "price effect only: 160 − 280 + 150; the 150 taken out is a flow, not a loss")
        #expect(r.change == r.marketMove + r.flows)
    }

    @Test func contributionsWeightsAndBoundaries() {
        let txs = [tx(btc, .buy, 1, 100, t0.addingTimeInterval(-3600 * 30)), tx(tel, .buy, 1000, 0.1, t0.addingTimeInterval(-3600 * 30)),
                   tx(tel, .buy, 1000, 0.1, end.addingTimeInterval(60))]   // after the window: ignored
        let r = Attribution.compute(ledgers: [txs], endPrices: [btc.id: 90, tel.id: 0.2], start: start, end: end) { $0 == btc.id ? 100 : 0.1 }
        #expect(r.byImpact.map(\.id) == [tel.id, btc.id])
        #expect(r.assets.first { $0.id == tel.id }?.contribution == 100 && r.assets.first { $0.id == btc.id }?.contribution == -10)
        #expect(r.flows == 0 && abs(r.assets.first { $0.id == btc.id }!.weightStart - 50) < 1e-9)
        let s = Attribution.summary(r, twr: nil, period: .today, symbol: { $0 == btc.id ? "BTC" : "TEL" }, fmt: Fmt(style: .comma, currency: "USD"))
        #expect(s.hasPrefix("TEL added $100, more than the whole market move."), "TEL +100 vs market move +90")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        #expect(Attribution.Period.today.start(now: noon, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        #expect(Attribution.Period.today.start(now: noon, dayStartHour: 14, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14)))
    }

    @Test func missingHistoryIsReportedNotEstimated() {
        let txs = [tx(btc, .buy, 1, 100, t0.addingTimeInterval(-86400))]
        let r = Attribution.compute(ledgers: [txs], endPrices: [btc.id: 110], start: start, end: end) { _ in nil }
        #expect(!r.complete && r.missing == [btc.id])
    }
}

struct BenchmarkTests {
    @Test func portfolioTWRVsBuyAndHold() {
        // Portfolio: +10% market, then a deposit that doubles value (TWR still +10%).
        let pts = [HistoryPoint(time: t0, value: 100, cost: 100, invested: 100), HistoryPoint(time: t0.addingTimeInterval(86400 * 10), value: 110, cost: 100, invested: 100),
                   HistoryPoint(time: t0.addingTimeInterval(86400 * 20), value: 220, cost: 210, invested: 210)]
        let chart = PortfolioChart(value: pts.compactMap(\.value), twr: PortfolioHistoryEngine.twrIndex(pts), points: pts)
        let p = Benchmark.portfolioSide(chart, start: t0, firstTransaction: t0)
        #expect(abs(p.returnPct! - 10) < 1e-9, "deposit excluded")
        let s = PriceSeries([PricePoint(time: t0, price: 50_000), PricePoint(time: t0.addingTimeInterval(86400 * 20), price: 60_000)])
        let b = Benchmark.priceSide(s, start: t0, endPrice: 60_000, now: t0.addingTimeInterval(86400 * 20), name: "BTC")
        #expect(abs(b.returnPct! - 20) < 1e-9)
        let r = Benchmark.Result(range: .m1, start: t0, portfolio: p, btc: b, eth: Benchmark.Side(returnPct: nil, path: [], missing: "x"))
        #expect(abs(r.vsBTC! - (-10)) < 1e-9 && r.vsETH == nil, "pp vs BTC; ETH unknown stays unknown")
    }

    @Test func missingHistoryIsExplicit() {
        let late = PriceSeries([PricePoint(time: t0.addingTimeInterval(86400 * 30), price: 1), PricePoint(time: t0.addingTimeInterval(86400 * 31), price: 1)])
        #expect(Benchmark.priceSide(late, start: t0, endPrice: 1, now: t0.addingTimeInterval(86400 * 31), name: "ETH").missing?.contains("history starts") == true)
        #expect(Benchmark.priceSide(nil, start: t0, endPrice: 1, now: t0, name: "BTC").missing == "BTC price history unavailable")
        #expect(Benchmark.portfolioSide(PortfolioChart(), start: t0, firstTransaction: t0).returnPct == nil)
        #expect(Benchmark.Range.m6.start(now: t0, firstTransaction: nil) == t0.addingTimeInterval(-182 * 86400))
    }
}
