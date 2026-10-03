import PFCore
import Foundation

// Market routing on the app side: providers, live exchange feeds, per-asset source status.
// Routing rules and thresholds live in PFCore (MarketMappings, MarketStatusPolicy).
extension AppStore {
    /// A full REST pass (metadata for streamed coins too) at most this often.
    static let fullRefreshInterval: TimeInterval = 15 * 60
    /// History requests in flight at once (changing chart range never bursts).
    static let historyConcurrency = 2

    func makeProviders() -> [MarketDataProvider] {
        if mockMarket { return [MockMarketDataProvider()] }
        return [BinanceProvider(), BybitProvider(), CoinGeckoProvider(apiKey: Keychain.get("coingecko-api-key")), DexScreenerProvider()]
    }

    /// Global preferred source from Settings ("Auto" = none).
    var globalPreferredSource: String? { settings.primaryProvider == "Auto" ? nil : settings.primaryProvider }

    /// The asset as the router sees it: its own preferred source, else the global one.
    func routed(_ a: Asset) -> Asset {
        var a = a
        if a.preferredSource == nil { a.preferredSource = globalPreferredSource }
        return a
    }

    var liveFeedsEnabled: Bool { !mockMarket && settings.realtimeProvider != "off" && settings.currency == "USD" && !asleep }

    func feed(_ s: MarketSource) -> LiveFeed? { s == .binance ? binanceFeed : s == .bybit ? bybitFeed : nil }

    func streamSymbol(_ a: Asset, _ s: MarketSource) -> String? {
        s == .binance ? MarketMappings.binanceSymbol(a) : s == .bybit ? MarketMappings.bybitSymbol(a) : nil
    }

    /// Streaming sources this asset should subscribe to: those in its route ahead of the first
    /// non-streaming source (a preferred REST source means no stream). On-peg stablecoins are
    /// checked by REST every few minutes instead.
    func streamSources(_ a: Asset) -> [MarketSource] {
        guard liveFeedsEnabled, Stablecoins.peg(for: a.id)?.currency != settings.currency else { return [] }
        return Array(MarketMappings.route(routed(a)).prefix { MarketSource.streaming.contains($0) })
    }

    /// Sources whose feed is live for this asset now.
    func liveSources(_ a: Asset) -> Set<MarketSource> {
        Set(streamSources(a).filter { s in streamSymbol(a, s).map { feed(s)?.isLive($0) ?? false } ?? false })
    }

    func isStreamLive(_ a: Asset) -> Bool { !liveSources(a).isEmpty }

    func connectStream() {
        guard liveFeedsEnabled else { binanceFeed.stop(); bybitFeed.stop(); return }
        let held = doc.assets.filter { a in summary.positions.contains { $0.asset.id == a.id } || a.id == assetID }
        for s in [MarketSource.binance, .bybit] {
            let syms = held.filter { streamSources($0).contains(s) }.compactMap { streamSymbol($0, s) }
            feed(s)?.connect(symbols: syms)
        }
    }

    /// A tick from a live feed. A backup feed's tick only counts while the first-choice feed isn't
    /// live for that asset, so the status shows FALLBACK · <feed> honestly.
    func applyTick(_ source: MarketSource, _ t: LiveFeed.Tick) {
        var changed = false
        for a in doc.assets where streamSymbol(a, source) == t.symbol {
            let srcs = streamSources(a)
            guard let idx = srcs.firstIndex(of: source) else { continue }
            let earlierLive = srcs.prefix(idx).contains { s in streamSymbol(a, s).map { feed(s)?.isLive($0) ?? false } ?? false }
            guard !earlierLive else { continue }
            var q = quotes[a.id] ?? Quote(price: t.price, source: source.rawValue, timestamp: Date())
            q.price = t.price
            if let c = t.change24h { q.change[.h24] = c }
            q.timestamp = Date()
            q.source = source.rawValue
            quotes[a.id] = q
            changed = true
        }
        if changed { scheduleTickRecompute() }
    }

    /// Live feeds can tick many times a second across assets; portfolio maths runs at most every
    /// `tickRecomputeInterval` (a 10k-transaction ALL summary costs tens of milliseconds).
    func scheduleTickRecompute() {
        guard tickRecomputeTask == nil else { return }
        tickRecomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tickRecomputeInterval * 1_000_000_000))
            guard let self else { return }
            self.tickRecomputeTask = nil
            self.recompute(historyChanged: false)
        }
    }
    static let tickRecomputeInterval: TimeInterval = 0.5

    /// Where this asset's price comes from, for the UI.
    func sourceState(_ id: AssetID) -> SourceState? {
        guard let a = asset(id) else { return nil }
        return SourceState.evaluate(routed(a), quote: quotes[id], streaming: liveSources(a))
    }

    /// Queue-aware history loading: cache first (stale-while-revalidate), then at most
    /// `historyConcurrency` provider requests at a time.
    func pumpHistory() {
        while loadingHistory.count < Self.historyConcurrency, !historyQueue.isEmpty {
            let (id, range) = historyQueue.removeFirst()
            let key = seriesKey(id, range)
            guard !loadingHistory.contains(key), let a = asset(id) else { continue }
            loadingHistory.insert(key)
            let cur = settings.currency, asset = routed(a)
            Task {
                let pts = try? await router.history(for: asset, range: range, currency: cur)
                loadingHistory.remove(key)
                if let pts, !pts.isEmpty {
                    cache.saveHistory(id, range, cur, pts)
                    series[key] = PriceSeries(pts)
                    dataVersion += 1
                }
                pumpHistory()
            }
        }
    }
}
