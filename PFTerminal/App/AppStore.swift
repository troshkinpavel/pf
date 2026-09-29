import PFCore
import PFCoreUI
import AppKit
import Observation
import SwiftUI

extension Freshness {
    var color: Color {
        switch self { case .live: Theme.pos; case .syncing, .partial: Theme.acc; case .stale: Theme.neg; default: Theme.t4 }
    }
}

struct PaletteState: Equatable {
    var query = ""
    var sel = 0
}

struct PaletteItem: Identifiable {
    let id = UUID()
    let label: String
    var detail = ""
    var hint = ""
    var isCommand = false
    let run: () -> Void
}

enum MoversMode: String { case pct, abs }

/// What a portfolio chart plots: market value, or P&L (value − net invested).
enum ChartMode: String, CaseIterable { case value, pnl }

/// Single source of UI + app state. Views read; only methods here mutate.
@MainActor @Observable
final class AppStore {
    // MARK: persistence
    @ObservationIgnored let files: PortfolioStore
    @ObservationIgnored let cache: MarketCache
    @ObservationIgnored let defaults: UserDefaults
    var doc = PortfolioDocument()
    var hasPortfolio = false
    /// Active portfolio context (a portfolio or ALL). Persisted; all calculations are scoped by it.
    var context: PortfolioContext = .all   // change via setContext(_:)
    @ObservationIgnored private var heldAnywhere: Set<AssetID> = []
    var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    var share: ShareConfig { didSet { persistShare() } }

    // MARK: market
    @ObservationIgnored let router: ProviderRouter
    @ObservationIgnored private let stream = BinanceStream()
    @ObservationIgnored private let network = NetworkMonitor()
    var mockMarket: Bool
    var quotes: [AssetID: Quote] = [:]
    var lastSuccess: Date?
    var lastAttempt: Date = .distantPast
    var inFlight = false
    var lastError: MarketError?
    var consecutiveFailures = 0
    var online = true
    var streamState: BinanceStream.State = .off
    var asleep = false
    var popoverOpen = false
    var series: [String: PriceSeries] = [:]         // "assetID|range"
    var loadingHistory: Set<String> = []
    var dataVersion = 0

    // MARK: derived
    var summary: PortfolioSummary
    var now = Date()

    // MARK: ui
    var screen: Screen = .overview
    var assetID: AssetID?
    var overviewRange: ChartRange = .w1
    var overviewMode: ChartMode = .value
    var analyticsMode: ChartMode = .pnl
    var assetRange: ChartRange = .d30
    var sel = 0
    var msel = 0
    var txSel = 0
    var moversRange: ChartRange = .h24
    var moversMode: MoversMode = .abs
    var moversDesc = true
    var targetAssetID: AssetID?
    var targetInput = ""
    var palette: PaletteState?
    var switcher: SwitcherState?
    var sourcePicker: SourcePickerState?
    var newPortfolio: NewPortfolioDraft?
    var manage = ManageState()
    var tx: TxDraft?
    var quickShare = false
    var flash = ""
    var message = "ready"
    var pendingImport: PortfolioDocument?
    var pendingDelete: Transaction?
    var locked = false
    var apiKeyEntry: String?
    /// Set when data from the previous app identity exists but could not be read automatically.
    var legacyDataUnreadable = false
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var flashTask: Task<Void, Never>?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored private var lastAlertDay: String?
    // widgets
    let publishWidgets: Bool
    var widgetStatus = "not written yet"
    @ObservationIgnored var widgetTask: Task<Void, Never>?
    @ObservationIgnored var lastWidgetWrite: Date = .distantPast
    @ObservationIgnored var lastWidgetKey = ""
    // iCloud sync (off by default; see AppStore+Sync)
    var syncState = SyncState() { didSet { persistSyncState() } }
    var syncStatus: SyncStatus = .localOnly
    var syncSheet: SyncSheet?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var syncDebounce: Task<Void, Never>?
    @ObservationIgnored var syncApplying = false
    @ObservationIgnored var lastSyncAttempt: Date = .distantPast
    @ObservationIgnored var syncRemote: SyncRemoteStore?
    // lifecycle + updates (see AppStore+Lifecycle)
    var updateState: UpdateState = .idle
    @ObservationIgnored var updateChecker: UpdateChecking = GitHubReleaseChecker()
    /// SwiftUI's openWindow for the main window, captured at launch by the menu bar label.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored var windowObservers: [NSObjectProtocol] = []

    struct Options {
        var directory: URL? = PortfolioStore.defaultDirectory
        var inMemory = false
        var mockMarket = false
        var seedDemo = false
        var publishWidgets = true
        var defaults: UserDefaults = .standard
        /// nil: CloudKit when the build is entitled. Tests and the DEBUG sync check inject their own.
        var syncRemote: SyncRemoteStore?
    }

    init(_ o: Options = Options()) {
        let dir = o.directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        // Earlier builds used another bundle id, hence another sandbox container: bring that data
        // over once, before anything below reads the ledger or preferences.
        var migration: LegacyMigration.Outcome?
        if !o.seedDemo, !o.inMemory, o.directory == PortfolioStore.defaultDirectory, o.defaults === UserDefaults.standard {
            migration = LegacyMigration.live(newDir: dir, defaults: o.defaults).run()
        }
        files = PortfolioStore(directory: dir)
        cache = MarketCache(directory: dir, inMemory: o.inMemory)
        defaults = o.defaults
        var s = AppSettings.load(o.defaults)
        var mock = o.mockMarket
        #if DEBUG
        mock = mock || s.primaryProvider == "Mock"
        #endif
        if mock { s.primaryProvider = "Mock" } else if s.primaryProvider == "Mock" { s.primaryProvider = "CoinGecko" }
        mockMarket = mock
        publishWidgets = o.publishWidgets
        settings = s
        var sh = (try? JSONDecoder().decode(ShareConfig.self, from: o.defaults.data(forKey: "pf.share.v1") ?? Data())) ?? ShareConfig()
        sh = sh.safeForReuse
        share = sh
        router = ProviderRouter(providers: [])
        summary = PortfolioEngine.summarize(transactions: [], assets: [:], quotes: [:])
        Fmt.current = Fmt(style: s.numbers, currency: s.currency)

        if o.seedDemo { loadDemo(save: !o.inMemory) }
        else { loadFromDisk() }
        switch migration {
        case let .migrated(files, _)?:
            message = "✓ moved your data from the previous PF Terminal install · \(files) files · the original stays in place · " + message
        case .legacyUnreadable?:
            legacyDataUnreadable = true
            if !hasPortfolio { message = "previous PF Terminal data found but not readable · press 3 (import) and pick portfolio.json in the folder shown" }
        default: break
        }
        context = doc.validContext(o.defaults.string(forKey: Self.contextKey).flatMap(PortfolioContext.init(storageKey:)))
        loadSyncState()
        syncRemote = o.syncRemote ?? Self.makeSyncRemote()
        quotes = cache.quotes(currency: s.currency).filter { k, _ in doc.assets.contains { $0.id == k } }
        recompute()
    }

    // MARK: - lifecycle

    func start() {
        Task { await router.setProviders(makeProviders()) }
        network.onChange = { [weak self] online in
            guard let self else { return }
            self.online = online
            if online { Task { await self.refresh(auto: true) }; self.syncNow(reason: .network) }
        }
        network.start()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = true; self?.stream.stop() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asleep = false
                self.connectStream()
                Task { await self.refresh(auto: true) }
            }
        }
        stream.onTick = { [weak self] sym, price, ch in self?.applyTick(sym, price, ch) }
        stream.onState = { [weak self] s in self?.streamState = s }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if settings.alertThreshold > 0 { Notifier.requestAuthorization() }
        Task { await refresh(auto: true) }
        connectStream()
        if settings.appLock { locked = true }
        startSync()
    }

    private func makeProviders() -> [MarketDataProvider] {
        if mockMarket { return [MockMarketDataProvider()] }
        let key = Keychain.get("coingecko-api-key")
        var list: [MarketDataProvider] = []
        let cg = CoinGeckoProvider(apiKey: key)
        let names = [settings.primaryProvider, settings.primaryProvider == "Binance" ? "CoinGecko" : "Binance", settings.fallbackProvider, "CoinGecko"]
        for n in names {
            guard !list.contains(where: { $0.name == n }) else { continue }
            switch n {
            case "CoinGecko": list.append(cg)
            case "Binance": list.append(BinanceProvider())
            case "DexScreener": list.append(DexScreenerProvider())
            default: break
            }
        }
        if !list.contains(where: { $0.name == "DexScreener" }) { list.append(DexScreenerProvider()) }
        return list
    }

    /// Effective refresh interval: active window uses the setting; background backs off; failures back off.
    var effectiveInterval: TimeInterval {
        let base = TimeInterval(settings.refreshSeconds)
        let active = NSApp?.isActive ?? true
        var i = active || popoverOpen ? base : max(300, base * 5)
        if consecutiveFailures > 0 { i = min(i * pow(2, Double(consecutiveFailures)), 900) }
        return i
    }

    var nextRefreshIn: Int { max(0, Int(effectiveInterval - now.timeIntervalSince(lastAttempt))) }

    private func tick() {
        now = Date()
        guard !asleep, online, !inFlight else { return }
        if now.timeIntervalSince(lastAttempt) >= effectiveInterval { Task { await refresh(auto: true) } }
        if syncState.mode == .iCloud, now.timeIntervalSince(lastSyncAttempt) >= 300 { syncNow(reason: .timer) }
    }

    var freshness: Freshness {
        Freshness.evaluate(online: online, inFlight: inFlight, held: marketDrivenHeld, quotes: quotes,
                           hasSucceeded: lastSuccess != nil, refreshSeconds: settings.refreshSeconds, now: now)
    }

    // MARK: - market data

    /// Quotes are shared market data: track holdings of every live portfolio, not only the
    /// active one, so switching contexts never waits on the network.
    var trackedAssets: [Asset] {
        var ids = heldAnywhere.union(summary.positions.map(\.asset.id))
        if let a = assetID { ids.insert(a) }
        if let t = targetAssetID { ids.insert(t) }
        // On-peg stablecoins join the normal batched refresh only every Stablecoins.checkInterval.
        let cur = settings.currency, t = Date()
        return doc.assets.filter { ids.contains($0.id) && Stablecoins.needsMarketCheck($0.id, quote: quotes[$0.id], currency: cur, now: t) }
    }

    func refresh(auto: Bool) async {
        guard !inFlight else { return }
        let assets = trackedAssets
        lastAttempt = Date()
        guard !assets.isEmpty else { lastSuccess = Date(); return }
        inFlight = true
        let t0 = Date()
        let r = await router.quotes(for: assets, currency: settings.currency)
        inFlight = false
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        for (k, q) in r.quotes { quotes[k] = q }
        if !r.quotes.isEmpty { cache.saveQuotes(r.quotes, currency: settings.currency) }
        if r.quotes.isEmpty {
            consecutiveFailures += 1
            lastError = r.errors.values.first ?? .unavailable(0)
            message = "✗ refresh failed · \(lastError!) · showing last known prices"
        } else {
            consecutiveFailures = 0
            lastError = r.errors.values.first
            lastSuccess = Date()
            let src = Set(r.quotes.values.map { $0.source.lowercased() }).sorted().joined(separator: "+")
            var m = "✓ \(auto ? "auto-" : "")refreshed \(r.quotes.count) price\(r.quotes.count == 1 ? "" : "s") · \(src) · \(ms)ms"
            if !r.unresolved.isEmpty {
                let syms = r.unresolved.compactMap { id in doc.assets.first { $0.id == id }?.symbol }
                m += " · no quote for " + syms.joined(separator: ", ")
            }
            message = m
        }
        recompute()
        recordSnapshot()
        checkAlert()
        connectStream()
    }

    private func connectStream() {
        guard !mockMarket, settings.realtimeProvider == "Binance", settings.currency == "USD", !asleep else { stream.stop(); return }
        let syms = summary.positions.compactMap(\.asset.binanceSymbol)
        stream.connect(symbols: syms)
    }

    private func applyTick(_ sym: String, _ price: Decimal, _ ch: Double) {
        guard let a = doc.assets.first(where: { $0.binanceSymbol == sym }), var q = quotes[a.id] else { return }
        q.price = price
        q.change[.h24] = ch
        q.timestamp = Date()
        if q.source == "cache" { q.source = "Binance" }
        quotes[a.id] = q
        recompute(historyChanged: false)
    }

    private func recordSnapshot() {
        guard !summary.isEmpty, !summary.isPartial, freshness == .live else { return }
        cache.addSnapshot(.init(timestamp: Date(), value: summary.totalValue.double, costBasis: summary.costBasis.double, unrealized: summary.unrealized.double),
                          context: context.storageKey)
    }

    private func checkAlert() {
        guard settings.alertThreshold > 0, let p = summary.change24hPct, abs(p) >= settings.alertThreshold else { return }
        let day = DateFmt.ymd(Date())
        guard lastAlertDay != day else { return }
        lastAlertDay = day
        Notifier.postMove(pct: p, fmt: Fmt.current)
    }

    // MARK: history

    func seriesKey(_ id: AssetID, _ r: ChartRange) -> String { "\(id)|\(r.rawValue)" }

    /// Ensure price history for `ids` over `range` is loaded (cache first, then providers).
    func loadHistory(_ ids: [AssetID], _ range: ChartRange) {
        let histRange: ChartRange = range == .ytd ? .y1 : range
        for id in ids {
            let key = seriesKey(id, histRange)
            guard !loadingHistory.contains(key), let asset = doc.assets.first(where: { $0.id == id }) else { continue }
            if let c = cache.history(id, histRange, settings.currency) {
                if series[key] == nil { series[key] = PriceSeries(c.points); dataVersion += 1 }
                if Date().timeIntervalSince(c.fetchedAt) < histRange.historyTTL { continue }
            } else if series[key] != nil { continue }
            loadingHistory.insert(key)
            let cur = settings.currency
            Task {
                let pts = try? await router.history(for: asset, range: histRange, currency: cur)
                loadingHistory.remove(key)
                if let pts, !pts.isEmpty {
                    cache.saveHistory(id, histRange, cur, pts)
                    series[key] = PriceSeries(pts)
                    dataVersion += 1
                }
            }
        }
    }

    /// Price history as the portfolio values it (stablecoin peg noise flattened; see Stablecoins).
    func assetSeries(_ id: AssetID, _ range: ChartRange) -> PriceSeries? {
        series[seriesKey(id, range == .ytd ? .y1 : range)].map { Stablecoins.valuationSeries($0, for: id, currency: settings.currency) }
    }

    /// Raw market quotes with stablecoins valued by their peg state. Everything that values the
    /// portfolio reads this; `quotes` stays the raw market data (freshness, peg status).
    var valuationQuotes: [AssetID: Quote] {
        Stablecoins.valuationQuotes(quotes, assets: doc.assets.map(\.id), currency: settings.currency)
    }

    /// Held assets whose value depends on a live market price (on-peg stablecoins don't).
    var marketDrivenHeld: [AssetID] {
        summary.positions.map(\.asset.id).filter { !Stablecoins.isPegValued($0, quote: quotes[$0], currency: settings.currency) }
    }

    /// Peg state for the asset detail screen; nil for non-stablecoins or another ledger currency.
    func pegCheck(_ id: AssetID) -> PegCheck? { Stablecoins.check(id, quote: quotes[id], currency: settings.currency) }

    /// Assets held at any point during the range in a context (default: the active one).
    func assetsHeld(during range: ChartRange, in c: PortfolioContext? = nil) -> [AssetID] {
        PortfolioEngine.assetsHeld(doc.transactions(c ?? context), during: range, now: now)
    }

    /// Reconstructed history for a range and context (default: active), ending at the live valuation.
    /// Only the context's own transactions contribute, so a portfolio has no value before its first one.
    func portfolioHistory(_ range: ChartRange, points: Int = 151, in c: PortfolioContext? = nil) -> PortfolioChart {
        _ = dataVersion
        let c = c ?? context
        let summary = c == context ? self.summary : summary(for: c)
        let txs = doc.transactions(c)
        var s: [AssetID: PriceSeries] = [:]
        for id in assetsHeld(during: range, in: c) {
            if let x = assetSeries(id, range) ?? assetSeries(id, .all) { s[id] = x }
            else if let peg = pegCheck(id), peg.status != .depeg { s[id] = Stablecoins.flatSeries(peg.peg) }
        }
        return PortfolioHistoryEngine.chart(transactions: txs, summary: summary, range: range, points: points, series: s, now: Date()) {
            self.cache.snapshots(since: $0, context: c.storageKey)
        }
    }

    // MARK: - derived

    func recompute(historyChanged: Bool = true) {
        summary = summary(for: context)
        if historyChanged {
            heldAnywhere = Set(PortfolioEngine.positions(ledgers: doc.ledgers(.all)).filter { $0.value.quantity > 0 }.keys)
        }
        if historyChanged { dataVersion += 1 }
        sel = min(sel, max(0, summary.positions.count - 1))
        scheduleWidgetSnapshot()
    }

    /// Portfolio maths for any context from shared quotes. Pure recomputation, no I/O.
    func summary(for c: PortfolioContext) -> PortfolioSummary {
        let assets = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PortfolioEngine.summarize(ledgers: doc.ledgers(c), assets: assets, quotes: valuationQuotes)
    }

    /// Transactions of the active context.
    var contextTransactions: [Transaction] { doc.transactions(context) }

    func asset(_ id: AssetID?) -> Asset? { id.flatMap { i in doc.assets.first { $0.id == i } } }

    var currentAsset: PositionValuation? {
        (assetID.flatMap { summary.valuation($0) }) ?? summary.positions.first
    }

    // MARK: - persistence

    private func loadFromDisk() {
        do {
            if let d = try files.load() {
                doc = d
                hasPortfolio = true
                // A v1 file was migrated in memory (its original is kept as portfolio.v1-backup.json):
                // persist v2 and attribute existing snapshots to MAIN.
                if let raw = try? Data(contentsOf: files.fileURL), !(String(data: raw, encoding: .utf8) ?? "").contains("\"portfolios\"") {
                    save()
                    cache.assignLegacySnapshots(to: doc.portfolios[0].id.uuidString)
                }
            }
        } catch {
            files.quarantine()
            message = "✗ portfolio.json was unreadable and has been set aside · \(error)"
        }
        if hasPortfolio {
            message = "ready · \(doc.livePortfolios.count) portfolio\(doc.livePortfolios.count == 1 ? "" : "s") · \(doc.transactions.count) transactions loaded from \(displayPath)"
                + (doc.isDemo(.all) ? " · DEMO DATA" : "")
        }
    }

    var displayPath: String {
        files.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    var dataDirectoryDisplay: String {
        files.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func save() {
        do { try files.save(doc); hasPortfolio = true }
        catch { message = "✗ could not save portfolio · \(error.localizedDescription)" }
        scheduleSync()
    }

    func createEmpty() {
        doc = .fresh()
        context = .portfolio(doc.portfolios[0].id)
        persistContext()
        save()
        settings.onboarded = true
        quotes = [:]
        recompute()
        message = "✓ empty portfolio created · ⌘N add your first transaction"
    }

    func loadDemo(save doSave: Bool = true) {
        let main = PortfolioInfo(id: UUID(), name: "MAIN", glyph: PortfolioGlyphs.main, createdAt: DateFmt.parseYMD("2024-09-06")!, isDemo: true)
        doc = PortfolioDocument(portfolios: [main], assets: MockMarketDataProvider.assets, transactions: DemoPortfolio.transactions(portfolio: main.id))
        context = .portfolio(main.id)
        persistContext()
        if doSave { save() }
        hasPortfolio = true
        settings.onboarded = true
        cache.invalidateSnapshots(from: .distantPast)
        recompute()
        message = "✓ demo portfolio loaded · clearly marked DEMO · remove any time: ⌘K → remove demo"
        Task { await refresh(auto: false) }
    }

    func removeDemo() {
        guard doc.isDemo(.all) || doc.portfolios.contains(where: \.isDemo) else { return }
        let demo = Set(doc.portfolios.filter(\.isDemo).map(\.id))
        doc.portfolios.removeAll { demo.contains($0.id) }
        doc.transactions.removeAll { demo.contains($0.portfolioID) }
        if doc.portfolios.isEmpty { doc = .fresh() }
        context = doc.validContext(context)
        persistContext()
        save()
        quotes = [:]
        series = [:]
        cache.clearAll()
        screen = .overview
        recompute()
        message = "✓ demo data removed · empty portfolio"
    }

    // MARK: - navigation

    func go(_ s: Screen) {
        screen = s
        palette = nil; tx = nil; quickShare = false; switcher = nil; newPortfolio = nil; syncSheet = nil
        manage.renaming = nil; manage.confirmDelete = nil
        if s == .overview { loadHistory(assetsHeld(during: overviewRange), overviewRange) }
    }

    func openAsset(_ id: AssetID) {
        assetID = id
        txSel = 0
        go(.asset)
        loadHistory([id], assetRange)
        if quotes[id] == nil { Task { await refresh(auto: false) } }
    }

    func openTarget(_ id: AssetID, _ value: String? = nil) {
        targetAssetID = id
        assetID = id
        if let v = value { targetInput = v }
        else if let p = quotes[id]?.price, let pre = ScenarioEngine.presets(for: p).dropFirst(2).first { targetInput = "\(pre)" }
        go(.target)
    }

    func back() {
        if syncSheet != nil { syncSheet = nil; return }
        if sourcePicker != nil { sourcePicker = nil; return }
        if switcher != nil { switcher = nil; return }
        if newPortfolio != nil { newPortfolio = nil; return }
        if manage.renaming != nil || manage.confirmDelete != nil { manage.renaming = nil; manage.confirmDelete = nil; return }
        if quickShare { quickShare = false; return }
        if palette != nil { palette = nil; return }
        if tx != nil { tx = nil; return }
        switch screen {
        case .target: if let t = targetAssetID { openAsset(t) } else { go(.overview) }
        case .overview: break
        default: go(.overview)
        }
    }

    func showFlash(_ short: String, _ long: String? = nil) {
        flash = short
        message = long ?? short
        flashTask?.cancel()
        flashTask = Task { try? await Task.sleep(nanoseconds: 2_200_000_000); if !Task.isCancelled { flash = "" } }
    }

    // MARK: - settings

    private func settingsChanged(_ old: AppSettings) {
        settings.save(defaults)
        Fmt.current = Fmt(style: settings.numbers, currency: settings.currency)
        if old.primaryProvider != settings.primaryProvider || old.fallbackProvider != settings.fallbackProvider {
            let wasMock = mockMarket
            mockMarket = settings.primaryProvider == "Mock"
            if wasMock != mockMarket { quotes = [:]; series = [:]; recompute(); connectStream() }
            let p = makeProviders()
            Task { await router.setProviders(p); await refresh(auto: false) }
        }
        if old.menuBarContext != settings.menuBarContext { scheduleWidgetSnapshot() }
        if old.currency != settings.currency {
            quotes = cache.quotes(currency: settings.currency).filter { k, _ in doc.assets.contains { $0.id == k } }
            series = [:]
            recompute()
            Task { await refresh(auto: false) }
        }
        if old.realtimeProvider != settings.realtimeProvider { connectStream() }
        if old.alertThreshold == 0 && settings.alertThreshold > 0 { Notifier.requestAuthorization() }
        if old.numbers != settings.numbers { recompute() }
        if old.widgetPrivacy != settings.widgetPrivacy { writeWidgetSnapshot() }
        if old.keepInDock != settings.keepInDock { keepInDockChanged() }   // privacy applies immediately
    }

    /// Currency is the ledger's currency: switching is allowed only when every transaction matches.
    func cycleCurrency() {
        let next = AppSettings.currencyOptions.cycled(from: settings.currency)
        if doc.transactions.contains(where: { $0.currency != next }) {   // every portfolio shares the base currency
            message = "✗ ledger is recorded in \(Set(doc.transactions.map(\.currency)).sorted().joined(separator: "/")) · mixed-currency ledgers are not supported"
            return
        }
        settings.currency = next
    }

    func setAPIKey(_ key: String?) {
        Keychain.set(key, for: "coingecko-api-key")
        let p = makeProviders()
        Task { await router.setProviders(p); await refresh(auto: false) }
        message = key?.isEmpty == false ? "✓ CoinGecko key saved to Keychain" : "✓ CoinGecko key removed"
    }
    var hasAPIKey: Bool { Keychain.get("coingecko-api-key") != nil }

    private func persistShare() {
        if let d = try? JSONEncoder().encode(share.safeForReuse) { defaults.set(d, forKey: "pf.share.v1") }
    }

    func unlock() {
        Task { if await AppLock.authenticate() { locked = false } }
    }
}
