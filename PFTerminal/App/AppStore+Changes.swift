import PFCore
import PFCoreUI
import AppKit
import ServiceManagement

// What Changed (design §03) and Benchmark (§10) on top of the existing price pipeline.
// Results are cached per minute + data version: views can ask on every render.
extension AppStore {
    // MARK: attribution

    /// Price of an asset at the start of a period: the quote's own period change first
    /// (7D / 30D), else price history at that moment, else the peg for on-peg stablecoins.
    func startPrice(_ id: AssetID, period: Attribution.Period, start: Date) -> Decimal? {
        if let cp = period.changePeriod, let sp = valuationQuotes[id]?.startPrice(cp) { return sp }
        if let s = assetSeries(id, period.historyRange) ?? assetSeries(id, .all), let p = s.price(at: start, tolerance: 3 * 3600) { return Decimal.of(p) }
        if let peg = pegCheck(id), peg.status != .depeg { return peg.peg.target }
        return nil
    }

    func attribution(_ p: Attribution.Period, in c: PortfolioContext? = nil) -> Attribution.Result? {
        let c = c ?? context
        let key = "\(c.storageKey)|\(p.rawValue)|\(dataVersion)|\(settings.dayStartHour)|\(Int(now.timeIntervalSince1970 / 60))|\(quotes.count)"
        if let hit = attributionCache[key] { return hit }
        let end = Date()
        let start = p.start(now: end, dayStartHour: settings.dayStartHour)
        let ledgers = doc.ledgers(c)
        guard !ledgers.flatMap({ $0 }).isEmpty else { return nil }
        let r = Attribution.compute(ledgers: ledgers, endPrices: valuationQuotes.mapValues(\.price), start: start, end: end) {
            self.startPrice($0, period: p, start: start)
        }
        if attributionCache.count > 24 { attributionCache.removeAll() }
        attributionCache[key] = r
        return r
    }

    /// TWR of the context over the period (from reconstructed history), for the KPI strip.
    func periodTWR(_ p: Attribution.Period) -> Double? {
        let start = p.start(now: Date(), dayStartHour: settings.dayStartHour)
        return portfolioChart(start: start, history: p.historyRange).twrPercent
    }

    func loadAttributionHistory() {
        let r = wcPeriod.historyRange
        loadHistory(assetsHeld(during: r), r)
    }

    /// The Base scenario's target weight for an asset (Overview ▲, Asset Detail allocation).
    func targetWeight(_ id: AssetID) -> Double? { Scenarios.base(intel)?.targets[id]?.weight }

    // MARK: history from an explicit start

    /// Reconstructed history from `start` (benchmark windows such as 6M).
    func portfolioChart(start: Date, history: ChartRange, points: Int = 121, in c: PortfolioContext? = nil) -> PortfolioChart {
        _ = dataVersion
        let c = c ?? context
        let summary = c == context ? self.summary : summary(for: c)
        let key = "start|\(c.storageKey)|\(Int(start.timeIntervalSince1970 / 60))|\(history.rawValue)|\(points)|\(dataVersion)|\(summary.totalValue)"
        if let h = historyCache[key] { return h }
        let txs = doc.transactions(c)
        var s: [AssetID: PriceSeries] = [:]
        for id in assetsHeld(during: history, in: c) {
            // A range series that starts after `start` (a young listing, a short feed) would leave the
            // window's beginning unpriced; the ALL series covers it when loaded.
            let ranged = assetSeries(id, history)
            let covers = ranged?.first.map { $0.time <= start.addingTimeInterval(2 * 86400) } ?? false
            if let x = covers ? ranged : assetSeries(id, .all) ?? ranged { s[id] = x }
            else if let peg = pegCheck(id), peg.status != .depeg { s[id] = Stablecoins.flatSeries(peg.peg) }
        }
        let chart = PortfolioHistoryEngine.chart(transactions: txs, summary: summary, start: start, points: points, series: s, now: Date()) {
            self.cache.snapshots(since: $0, context: c.storageKey)
        }
        if historyCache.count > 16 { historyCache.removeAll() }
        historyCache[key] = chart
        return chart
    }

    // MARK: benchmark

    static let benchmarkAssets: [Asset] = [Benchmark.btc, Benchmark.eth].compactMap { id in AssetCatalog.known.first { $0.id == id } }

    func benchmark(_ r: Benchmark.Range) -> Benchmark.Result {
        let key = "\(context.storageKey)|\(r.rawValue)|\(dataVersion)|\(Int(now.timeIntervalSince1970 / 60))"
        if let hit = benchmarkCache[key] { return hit }
        if benchmarkCache.count > 20 { benchmarkCache.removeAll() }
        let res = computeBenchmark(r)
        benchmarkCache[key] = res
        return res
    }

    private func computeBenchmark(_ r: Benchmark.Range) -> Benchmark.Result {
        let now = Date()
        let start = r.start(now: now, firstTransaction: summary.firstDate)
        let pf = Benchmark.portfolioSide(portfolioChart(start: start, history: r.history), start: start, firstTransaction: summary.firstDate)
        func side(_ id: AssetID, _ name: String) -> Benchmark.Side {
            Benchmark.priceSide(assetSeries(id, r.history) ?? assetSeries(id, .all), start: start, endPrice: quotes[id]?.price, now: now, name: name)
        }
        return Benchmark.Result(range: r, start: start, portfolio: pf, btc: side(Benchmark.btc, "BTC"), eth: side(Benchmark.eth, "ETH"))
    }

    /// Price history still on its way (benchmark / What Changed say "loading", not "missing").
    var historyPending: Bool { !historyQueue.isEmpty || !loadingHistory.isEmpty }

    func setBenchmarkRange(_ r: Benchmark.Range) {
        benchmarkRange = r
        loadBenchmarkHistory()
    }

    /// Portfolio plus BTC/ETH history (even when not held) for every range: the relative table
    /// shows all of them at once.
    func loadBenchmarkHistory() {
        // The chart's range first: the queue is paced, the table's other ranges can follow.
        var order = [benchmarkRange.history]
        for r in Benchmark.Range.allCases where !order.contains(r.history) { order.append(r.history) }
        for h in order {
            loadHistory(assetsHeld(during: h), h)
            for a in Self.benchmarkAssets { loadReferenceHistory(a, h) }
        }
    }

    /// History for an asset that may not be in the ledger (benchmarks).
    func loadReferenceHistory(_ a: Asset, _ range: ChartRange) {
        let key = seriesKey(a.id, range)
        guard !loadingHistory.contains(key) else { return }
        if let c = cache.history(a.id, range, settings.currency) {
            if series[key] == nil { series[key] = PriceSeries(c.points); dataVersion += 1 }
            if Date().timeIntervalSince(c.fetchedAt) < range.historyTTL { return }
        }
        loadingHistory.insert(key)
        let cur = settings.currency, asset = routed(a)
        Task {
            let pts = try? await router.history(for: asset, range: range, currency: cur)
            loadingHistory.remove(key)
            if let pts, !pts.isEmpty {
                cache.saveHistory(a.id, range, cur, pts)
                series[key] = PriceSeries(pts)
                dataVersion += 1
            }
        }
    }

    // MARK: launch at login

    func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "✗ launch at login · \(error.localizedDescription)"
        }
    }

    /// Launched by the login item: start in the menu bar without the window.
    static var launchedAsLoginItem: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return e.eventID == kAEOpenApplication && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

// MARK: - Asset Detail intelligence (design §04)

extension AppStore {
    struct ImpactRow { let label: String; let priceChange: Double?; let contribution: Decimal?; let pp: Double?; let rank: String }

    /// This asset's share of the portfolio move over today · 7d · 30d (from What Changed).
    func assetImpact(_ id: AssetID) -> [ImpactRow] {
        Attribution.Period.allCases.map { p in
            guard let r = attribution(p), r.complete, let a = r.assets.first(where: { $0.id == id }) else {
                return ImpactRow(label: p.label.lowercased(), priceChange: nil, contribution: nil, pp: nil, rank: "—")
            }
            let rank = (r.byImpact.firstIndex { $0.id == id } ?? 0) + 1
            return ImpactRow(label: p.label.lowercased(), priceChange: a.priceChange, contribution: a.contribution,
                             pp: r.startValue > 0 ? (a.contribution / r.startValue).double * 100 : nil, rank: "\(rank)/\(r.assets.count)")
        }
    }

    /// Position value against its local peak since the first buy. The path is quantity held at
    /// each point × price, so a later buy doesn't reset the peak to "now".
    func positionDrawdown(_ v: PositionValuation) -> (peak: Double, at: Date, fromPeak: Double, fromPeakValue: Double)? {
        guard let first = v.position.transactions.first?.timestamp, let now = v.value?.double, now > 0,
              let s = assetSeries(v.asset.id, .all) ?? assetSeries(v.asset.id, assetRange) else { return nil }
        let txs = v.position.transactions.sorted { $0.timestamp < $1.timestamp }
        var i = 0, q = Decimal(0)
        var peak = (value: now, at: Date())
        for p in s.points where p.time >= first {
            while i < txs.count, txs[i].timestamp <= p.time {
                q += txs[i].type.increases ? txs[i].quantity : -txs[i].quantity; i += 1
            }
            let val = q.double * p.price
            if val > peak.value { peak = (val, p.time) }
        }
        return (peak.value, peak.at, (now / peak.value - 1) * 100, now - peak.value)
    }
}
