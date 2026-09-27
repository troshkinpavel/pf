import Foundation
import WidgetKit

// market data → PortfolioEngine (recompute) → throttled snapshot → App Group → WidgetCenter reload

extension AppStore {
    /// At most one write per `widgetMinInterval`; bursts (realtime ticks) coalesce into one.
    static let widgetMinInterval: TimeInterval = 30

    func scheduleWidgetSnapshot() {
        guard publishWidgets, widgetTask == nil else { return }
        let wait = max(1.5, Self.widgetMinInterval - Date().timeIntervalSince(lastWidgetWrite))
        widgetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.widgetTask = nil
            self.writeWidgetSnapshot()
        }
    }

    /// Build and write one snapshot per context (the active one, every live portfolio, ALL),
    /// plus the picker index; then reload widgets. Skipped when nothing visible changed.
    func writeWidgetSnapshot() {
        guard publishWidgets else { return }
        guard let dir = WidgetSnapshotStore.containerURL else {
            widgetStatus = "App Group unavailable (unsigned build)"
            return
        }
        let now = Date()
        let contexts: [PortfolioContext] = doc.livePortfolios.map { .portfolio($0.id) } + [.all]
        var snaps: [String: WidgetPortfolioSnapshot] = [:]
        for c in contexts { snaps[c.storageKey] = makeWidgetSnapshot(for: c, now: now) }
        let active = snaps[context.storageKey] ?? makeWidgetSnapshot(for: context, now: now)

        let comparable = snaps.mapValues { var x = $0; x.generatedAt = .distantPast; return x }
        let key = comparable.keys.sorted().map { k in "\(k)|\((try? WidgetSnapshotStore.encoder.encode(comparable[k]!)).map { $0.hashValue } ?? 0)" }.joined() + context.storageKey
        if key == lastWidgetKey, now.timeIntervalSince(lastWidgetWrite) < 5 * 60 { return }
        do {
            try WidgetSnapshotStore.write(active, to: dir.appendingPathComponent(WidgetSnapshotStore.fileName))
            for (k, snap) in snaps { try WidgetSnapshotStore.write(snap, to: WidgetSnapshotStore.url(for: k)!) }
            let index = doc.livePortfolios.map { WidgetPortfolioRef(id: $0.id.uuidString, name: $0.name, glyph: $0.glyph) }
                + [WidgetPortfolioRef(id: "all", name: "ALL PORTFOLIOS", glyph: PortfolioGlyphs.aggregate)]
            try WidgetSnapshotStore.encoder.encode(index).write(to: dir.appendingPathComponent(WidgetSnapshotStore.indexName), options: .atomic)
            // Archived / deleted portfolios must not keep feeding widgets.
            let keep = Set(snaps.keys.map { "widget-snapshot-\($0).json" })
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where f.hasPrefix("widget-snapshot-") && !keep.contains(f) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
            lastWidgetKey = key
            lastWidgetWrite = now
            widgetStatus = "updated " + DateFmt.hms(now) + " · \(snaps.count) contexts"
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
        } catch {
            widgetStatus = "write failed · " + ((error as NSError).localizedFailureReason ?? (error as NSError).localizedDescription).prefix(60)
        }
    }

    /// Snapshot for a context from the current engine state (also used by DEBUG rendering).
    func makeWidgetSnapshot(for c: PortfolioContext? = nil, now: Date = Date()) -> WidgetPortfolioSnapshot {
        let c = c ?? context
        let sum = c == context ? summary : summary(for: c)
        loadHistory(assetsHeld(during: .d1, in: c), .d1)   // async; the chart fills in on the next write
        let hist = portfolioHistory(.d1, points: 97, in: c)
        let movers = MoversEngine.movers(summary: sum, transactions: doc.transactions(c), quotes: quotes, series: [:], range: .h24, now: now)
        let pts = hist.points
        let stale: Bool = { switch freshness { case .live, .syncing: return false; default: return true } }()
        return WidgetSnapshotBuilder.build(.init(
            summary: sum, movers24h: movers, performance: hist.twr,
            performanceStart: pts.first?.time ?? now.addingTimeInterval(-86400), performanceRange: "24H",
            performanceChangePercent: pts.count > 1 ? PortfolioHistoryEngine.moneyWeightedReturn(from: pts[0], to: pts[pts.count - 1]) : nil,
            hasPortfolio: hasPortfolio,
            quotesAsOf: sum.positions.compactMap { quotes[$0.asset.id]?.timestamp }.min(),
            refreshInterval: effectiveInterval, isStale: stale,
            privacy: settings.widgetPrivacy, currency: settings.currency, numberStyle: settings.numbers, now: now,
            contextID: c.storageKey, contextName: doc.displayName(c), contextGlyph: doc.glyph(c)))
    }

    /// `pfterminal://portfolio`, `pfterminal://movers`, `pfterminal://asset/<id or symbol>`.
    func handleDeepLink(_ url: URL) {
        presentMainWindow()   // also from menu-bar-only state (widget taps arrive here)
        guard let r = PFLink.route(url), hasPortfolio, !locked else { return }
        palette = nil; tx = nil; quickShare = false
        switch r {
        case .portfolio: go(.overview)
        case .movers: go(.movers)
        case let .asset(key):
            if let a = doc.assets.first(where: { $0.id == key }) ?? AssetCatalog.resolve(key, in: doc.assets) { openAsset(a.id) }
            else { go(.overview) }
        }
    }
}
