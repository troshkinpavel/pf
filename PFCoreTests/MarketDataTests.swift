import Foundation
import Testing
@testable import PFCore

private let reg = AssetRegistry.shared
private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private let tel = AssetCatalog.known.first { $0.symbol == "TEL" }!
private let usdt = AssetCatalog.known.first { $0.symbol == "USDT" }!
private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - Registry

struct RegistryTests {
    @Test func bundledSnapshotLoadsDeterministically() {
        let a = AssetRegistry.bundledSnapshot(), b = AssetRegistry.bundledSnapshot()
        #expect(a?.registryVersion == "2026-09-30" && a?.assetCount == 1000 && a?.assets.count == 1000)
        #expect(a?.assets.map(\.id) == b?.assets.map(\.id))
        #expect(reg.count == 1000 && reg.version == "2026-09-30")
        #expect(reg.overlayVersions.contains("curated-2026-09-30"))
        #expect(reg.assets.first?.symbol == "BTC", "rank order")
    }

    @Test func localSearchBySymbolNameAndIDs() {
        #expect(reg.search("btc").first?.symbol == "BTC")
        #expect(reg.search("bitcoin").first?.symbol == "BTC")
        #expect(reg.search("telcoin-2").first?.symbol == "TEL", "CoinGecko id")
        #expect(reg.search("cmc-1027").first?.symbol == "ETH", "registry id")
        #expect(reg.search("ethe").first?.symbol == "ETH", "name prefix, rank breaks ties")
        #expect(reg.search("").isEmpty && reg.search("zzqqxx").isEmpty)
    }

    @Test func tickerCollisionsAreKeptApart() {
        let g = reg.entries(symbol: "GUSD")
        #expect(g.count == 2 && Set(g.compactMap(\.coingeckoId)) == ["gusd", "gemini-dollar"])
        #expect(reg.search("gusd").filter { $0.symbol == "GUSD" }.count == 2, "both offered, none auto-picked")
    }

    @Test func coingeckoMappingKeepsLedgerIDs() {
        #expect(reg.entry(for: tel)?.id == "cmc-2394", "cg:telcoin → telcoin-2 via the catalog override")
        #expect(reg.assetID(for: reg.entry(registryID: "cmc-2394")!) == "cg:telcoin", "a registry pick lands on the existing id")
        #expect(reg.assetID(for: reg.entry(registryID: "cmc-1")!) == "cg:bitcoin")
        let kcs = reg.entry(registryID: "cmc-2087")!
        #expect(kcs.coingeckoId == nil && reg.assetID(for: kcs) == "cmc:2087", "no CoinGecko id: registry-namespaced id")
        #expect(reg.entry(forID: "cmc:2087")?.symbol == "KCS")
        #expect(MarketMappings.coingeckoID(reg.asset(for: kcs)) == nil)
    }

    @Test func binanceMappingIsValidatedNotInferred() {
        #expect(MarketMappings.binanceSymbol(btc) == "BTCUSDT")
        #expect(reg.entry(for: usdt)?.binanceSymbol == "USDTTRY", "as delivered in the snapshot")
        #expect(MarketMappings.binanceSymbol(usdt) == nil, "USDTTRY quotes in lira: rejected")
        #expect(MarketMappings.binanceSymbol(tel) == nil, "TEL isn't on Binance")
        #expect(MarketMappings.validBinance("USDT") == nil && MarketMappings.validBinance("ETHFDUSD") == "ETHFDUSD")
    }

    @Test func bybitMappingOnlyWhereVerified() {
        #expect(MarketMappings.bybitSymbol(tel) == "TELUSDT", "curated, verified overlay")
        #expect(MarketMappings.bybitSymbol(btc) == nil, "not inferred from the ticker")
        let kas = reg.asset(for: reg.entry(registryID: "cmc-20396")!)
        #expect(MarketMappings.bybitSymbol(kas) == "KASUSDT", "curated: Bybit + CoinGecko tickers confirm it")
        #expect(MarketMappings.availableSources(kas) == [.bybit, .coingecko])
        #expect(MarketMappings.availableSources(tel) == [.bybit, .coingecko, .dexscreener])
    }

    @Test func contractMappingUsesDexChainIDsAndSkipsUnknownChains() {
        let usdcTargets = MarketMappings.dexTargets(usdc)
        #expect(usdcTargets.contains(.init(chain: "ethereum", contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")))
        #expect(usdcTargets.contains(.init(chain: "zksync", contract: "0x1d17cbcf0d6d143135ae902365d2e5e2a16538d4")))
        let aster = reg.asset(for: reg.entry(registryID: "cmc-36341")!)
        #expect(MarketMappings.dexTargets(aster) == [.init(chain: "bsc", contract: "0x000ae314e2a2172a039b26378814c252734f556a")])
        let pons = reg.asset(for: reg.entry(registryID: "cmc-40938")!)
        #expect(MarketMappings.dexTargets(pons).isEmpty, "'robinhood' has no known DexScreener chain id: skipped, not guessed")
        #expect(Set(MarketMappings.dexTargets(tel).map(\.chain)) == ["ethereum", "base", "polygon"], "TEL multi-chain kept")
    }

    @Test func stablecoinMetadataFromRegistryWithCuratedFallback() {
        #expect(reg.assets.filter { $0.stablecoin != nil }.count == 39)
        #expect(Stablecoins.peg(for: "cg:usd-coin") == .usd)
        #expect(Stablecoins.peg(for: "cg:ethena-usde") == .usd, "registry-only stablecoin")
        #expect(reg.entry(forID: "cg:usds") == nil && Stablecoins.peg(for: "cg:usds") == .usd, "USDS isn't in the snapshot: curated")
        #expect(Stablecoins.peg(for: "cg:bitcoin") == nil)
    }

    @Test func missingOptionalFieldsDecode() throws {
        let json = #"{"registryVersion":"x","assets":[{"id":"cmc-9","symbol":"abc","name":"Abc"}]}"#
        let s = try JSONDecoder().decode(RegistrySnapshot.self, from: Data(json.utf8))
        let a = s.assets[0]
        #expect(a.symbol == "ABC" && a.coingeckoId == nil && a.contracts.isEmpty && a.stablecoin == nil && a.bybitSymbol == nil)
        #expect(s.assetCount == nil && s.source == nil)
    }
}

// MARK: - Overlay

struct RegistryOverlayTests {
    private let base = AssetRegistry.bundledSnapshot()!

    @Test func overlayValidatesAndMerges() throws {
        let o = RegistryOverlay(overlayVersion: "o1", baseRegistryVersions: ["2026-09-30"],
                                patches: [.init(id: "cmc-1", bybitSymbol: "BTCUSDT", contracts: ["base": "0xabc"])])
        try o.validate(against: base)
        let r = AssetRegistry(snapshot: base, overlays: [o])
        #expect(r.entry(registryID: "cmc-1")?.bybitSymbol == "BTCUSDT" && r.entry(registryID: "cmc-1")?.contracts["base"] == "0xabc")
        #expect(r.overlayVersions == ["o1"])
    }

    @Test func invalidOverlaysAreIgnoredAndTheBaselineStays() {
        let wrongBase = RegistryOverlay(overlayVersion: "o2", baseRegistryVersions: ["1999-01-01"], patches: [.init(id: "cmc-1", bybitSymbol: "X")])
        let unknown = RegistryOverlay(overlayVersion: "o3", patches: [.init(id: "cmc-nope", bybitSymbol: "X")])
        #expect(throws: RegistryOverlay.ValidationError.wrongBase("2026-09-30")) { try wrongBase.validate(against: base) }
        #expect(throws: RegistryOverlay.ValidationError.unknownID("cmc-nope")) { try unknown.validate(against: base) }
        let r = AssetRegistry(snapshot: base, overlays: [wrongBase, unknown])
        #expect(r.overlayVersions.isEmpty && r.entry(registryID: "cmc-1")?.bybitSymbol == nil && r.count == 1000)
    }

    @Test func updatePolicyIsRareCachedAndNeverBreaksTheBaseline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-reg-\(UUID().uuidString)")
        let store = RegistryOverlayStore(directory: dir)
        #expect(store.shouldCheck(now: t0), "never checked")
        let good = try JSONEncoder().encode(RegistryOverlay(overlayVersion: "r1", patches: [.init(id: "cmc-1", bybitSymbol: "BTCUSDT")]))
        #expect(await store.refreshIfDue(fetch: { good }, base: base, now: t0) == .updated("r1"))
        #expect(store.cachedOverlay(base: base)?.overlayVersion == "r1")
        #expect(!store.shouldCheck(now: t0.addingTimeInterval(86400)), "not again within 5 days")
        #expect(await store.refreshIfDue(fetch: { Data("junk".utf8) }, base: base, now: t0.addingTimeInterval(86400)) == .skipped)
        let later = t0.addingTimeInterval(RegistryOverlayStore.minInterval + 1)
        #expect(await store.refreshIfDue(fetch: { Data("junk".utf8) }, base: base, now: later) == .rejected)
        #expect(store.cachedOverlay(base: base)?.overlayVersion == "r1", "a rejected update keeps the cached overlay")
        #expect(RegistryOverlayStore.remoteURL == nil, "0.5.0 makes no overlay requests")
    }
}

// MARK: - Live feeds

@MainActor
struct LiveFeedTests {
    @Test func binanceMessageParses() {
        let m = #"{"stream":"btcusdt@miniTicker","data":{"e":"24hrMiniTicker","s":"BTCUSDT","c":"61000.5","o":"60000"}}"#
        let t = LiveFeed.Venue.binance.parse(Data(m.utf8))
        #expect(t?.symbol == "BTCUSDT" && t?.price == Decimal(string: "61000.5"))
        #expect(abs((t?.change24h ?? 0) - 1.6675) < 1e-3)
    }

    @Test func bybitMessageParsesAndIgnoresControlFrames() {
        let m = #"{"topic":"tickers.TELUSDT","ts":1790000000000,"type":"snapshot","data":{"symbol":"TELUSDT","lastPrice":"0.00431","price24hPcnt":"0.0123","turnover24h":"12345.6"}}"#
        let t = LiveFeed.Venue.bybit.parse(Data(m.utf8))
        #expect(t?.symbol == "TELUSDT" && t?.price == Decimal(string: "0.00431") && abs((t?.change24h ?? 0) - 1.23) < 1e-9)
        #expect(LiveFeed.Venue.bybit.parse(Data(#"{"success":true,"ret_msg":"pong","op":"ping"}"#.utf8)) == nil)
        #expect(LiveFeed.Venue.bybit.parse(Data(#"{"success":true,"op":"subscribe"}"#.utf8)) == nil)
    }

    @Test func bybitSubscribesOnlyGivenPairsWithoutAuth() {
        let syms = (1...12).map { "T\($0)USDT" }
        let msgs = LiveFeed.Venue.bybit.subscribe(syms)
        #expect(msgs.count == 2, "at most 10 args per request")
        #expect(msgs.allSatisfy { $0.contains("\"op\":\"subscribe\"") && !$0.contains("auth") && !$0.contains("api_key") })
        #expect(msgs.joined().contains("tickers.T12USDT"))
        #expect(LiveFeed.Venue.bybit.url([])?.absoluteString == "wss://stream.bybit.com/v5/public/spot")
        #expect(LiveFeed.Venue.binance.url(["BTCUSDT"])?.absoluteString.contains("btcusdt@miniTicker") == true)
    }

    @Test func ticksAreLiveThenStale() {
        var now = t0
        let f = LiveFeed(venue: .bybit, now: { now })
        f.prepare(symbols: ["TELUSDT"])
        var got: [LiveFeed.Tick] = []
        f.onTick = { got.append($0) }
        f.handle(Data(#"{"topic":"tickers.TELUSDT","data":{"symbol":"TELUSDT","lastPrice":"0.0043"}}"#.utf8))
        f.handle(Data(#"{"topic":"tickers.OTHERUSDT","data":{"symbol":"OTHERUSDT","lastPrice":"1"}}"#.utf8))
        #expect(got.map(\.symbol) == ["TELUSDT"], "unsubscribed symbols are ignored")
        #expect(f.state == .connected && f.isHealthy() && f.isLive("TELUSDT"))
        now = t0.addingTimeInterval(MarketStatusPolicy.liveThreshold + 1)
        #expect(!f.isLive("TELUSDT"), "no tick for too long: not live")
        #expect(!f.isHealthy(), "silent connection: stale")
    }

    @Test func dropsReconnectWithBackoff() {
        let f = LiveFeed(venue: .bybit)
        f.prepare(symbols: ["TELUSDT"])
        f.drop("test")
        #expect(f.reconnectDelay == 5 && f.state == .disconnected("test"))
        f.drop("test")
        #expect(f.reconnectDelay == 10, "exponential backoff")
        f.stop()
        #expect(f.reconnectDelay == nil && f.state == .off)
    }
}

// MARK: - Bybit REST

struct BybitRESTTests {
    @Test func tickersAndKlinesParse() {
        let j = #"{"retCode":0,"result":{"list":[{"symbol":"TELUSDT","lastPrice":"0.0043","price24hPcnt":"-0.02","turnover24h":"50000"}]}}"#
        let q = BybitProvider.parseTickers(Data(j.utf8), bySymbol: ["TELUSDT": tel], at: t0)[tel.id]
        #expect(q?.price == Decimal(string: "0.0043") && q?.change24h == -2 && q?.source == "Bybit" && q?.volume24h == 50000)
        let k = #"{"retCode":0,"result":{"list":[["1790003600000","1","1","1","0.0044","1","1"],["1790000000000","1","1","1","0.0043","1","1"]]}}"#
        let pts = BybitProvider.parseKlines(Data(k.utf8))
        #expect(pts.map(\.price) == [0.0043, 0.0044], "oldest first")
        #expect(BybitProvider.parseTickers(Data(#"{"retCode":10001,"result":null}"#.utf8), bySymbol: [:], at: t0).isEmpty)
    }
}

// MARK: - Router

/// Named like the real providers so routing treats them as those sources.
private final class Stub: MarketDataProvider, @unchecked Sendable {
    let name: String
    var fail: MarketError?
    private(set) var calls = 0
    init(_ name: String, fail: MarketError? = nil) { self.name = name; self.fail = fail }
    func supports(_ a: Asset) -> Bool { true }
    func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        calls += 1
        if let fail { throw fail }
        return Dictionary(uniqueKeysWithValues: assets.map { ($0.id, Quote(price: 1, source: name, timestamp: t0)) })
    }
}

struct RouterTests2 {
    private func sources() -> (Stub, Stub, Stub, Stub) { (Stub("Binance"), Stub("Bybit"), Stub("CoinGecko"), Stub("DexScreener")) }
    /// TEL listed on both exchanges, for fallback between feeds.
    private let both = Asset(id: "cg:telcoin", symbol: "TEL", name: "Telcoin", coingeckoID: "telcoin-2", binanceSymbol: "TELUSDT")

    @Test func autoPrefersBinanceAndSkipsCoinGecko() async {
        let (bn, bb, cg, dx) = sources()
        let r = ProviderRouter(providers: [cg, dx, bb, bn])   // configured order doesn't matter
        let out = await r.quotes(for: [btc], currency: "USD")
        #expect(out.quotes[btc.id]?.source == "Binance")
        #expect(bb.calls == 0 && dx.calls == 0, "no other exchange or DEX asked")
        #expect(cg.calls == 1, "CoinGecko only for metadata")
        _ = await r.quotes(for: [btc], currency: "USD")
        #expect(cg.calls == 1, "metadata at most once per 15 minutes")
        #expect(bn.calls == 2)
    }

    @Test func autoUsesBybitWhenBinanceUnavailable() async {
        let (bn, bb, cg, dx) = sources()
        let r = ProviderRouter(providers: [bn, bb, cg, dx])
        #expect(await r.quotes(for: [tel], currency: "USD").quotes[tel.id]?.source == "Bybit", "TEL has no Binance pair")
        bn.fail = .unavailable(503)
        #expect(await r.quotes(for: [both], currency: "USD").quotes[both.id]?.source == "Bybit", "Binance down → Bybit")
        #expect(cg.calls <= 1, "CoinGecko at most once, for metadata")
    }

    @Test func preferredBybitIsRespectedAndItsFailureVisiblyFallsBack() async {
        let (bn, bb, cg, dx) = sources()
        let r = ProviderRouter(providers: [bn, bb, cg, dx])
        var pref = both; pref.preferredSource = "Bybit"
        #expect(await r.quotes(for: [pref], currency: "USD").quotes[pref.id]?.source == "Bybit")
        #expect(bn.calls == 0, "preferred Bybit answered; Binance not asked")
        bb.fail = .rateLimited(retryAfter: 30)
        let q = await r.quotes(for: [pref], currency: "USD").quotes[pref.id]
        #expect(q?.source == "Binance")
        let st = SourceState.evaluate(pref, quote: q, streaming: [], now: t0)
        #expect(st.status == .fallback(.binance) && st.preferred == .bybit, "shown as FALLBACK · BINANCE, not as Bybit")
    }

    @Test func coinGeckoIsTheFallbackWhenNoExchangeCanPrice() async {
        let (bn, bb, cg, dx) = sources()
        bn.fail = .unavailable(500)
        let r = ProviderRouter(providers: [bn, bb, cg, dx])
        #expect(await r.quotes(for: [btc], currency: "USD").quotes[btc.id]?.source == "CoinGecko")
        #expect(dx.calls == 0)
    }

    @Test func dexRequiresACanonicalContract() {
        let unknown = Asset(id: "sym:foo", symbol: "FOO", name: "Foo")
        #expect(!DexScreenerProvider().supports(unknown), "no contract, no DEX guess by ticker")
        #expect(MarketMappings.route(unknown).isEmpty)
        #expect(DexScreenerProvider().supports(usdc), "registry contract")
    }
}

// MARK: - Status

struct PriceStatusTests {
    private func q(_ src: String, age: TimeInterval) -> Quote { Quote(price: 1, source: src, timestamp: t0.addingTimeInterval(-age)) }

    @Test func statesAndLabels() {
        let s = { (a: Asset, q: Quote?, live: Set<MarketSource>) in SourceState.evaluate(a, quote: q, streaming: live, now: t0).status }
        #expect(s(btc, q("Binance", age: 5), [.binance]) == .live(.binance))
        #expect(s(btc, q("Binance", age: 5), [.binance]).label == "LIVE · BINANCE")
        #expect(s(tel, q("Bybit", age: 3), [.bybit]).label == "LIVE · BYBIT")
        #expect(s(btc, q("Binance", age: 120), []) == .cached(age: 120))
        #expect(s(btc, q("cache", age: 60), []).label == "CACHED · 1m")
        #expect(s(btc, q("Binance", age: 6 * 60), []).label == "DELAYED · 6m")
        #expect(s(btc, q("CoinGecko", age: 30), []).label == "FALLBACK · COINGECKO", "Binance expected, CoinGecko answered")
        #expect(s(tel, q("DexScreener", age: 30), []).label == "FALLBACK · DEX")
        #expect(s(btc, q("Binance", age: 18 * 60), []).label == "STALE · 18m")
        #expect(s(btc, nil, []).label == "NO PRICE")
        let cgOnly = Asset(id: "cg:foo", symbol: "FOO", name: "Foo", coingeckoID: "foo")
        #expect(s(cgOnly, q("CoinGecko", age: 30), []) == .cached(age: 30), "its only source isn't a fallback")
    }

    @Test func streamSilenceEndsLive() {
        let st = SourceState.evaluate(btc, quote: q("Binance", age: MarketStatusPolicy.liveThreshold + 5), streaming: [.binance], now: t0)
        #expect(!st.isLive && st.status == .cached(age: MarketStatusPolicy.liveThreshold + 5))
    }
}
