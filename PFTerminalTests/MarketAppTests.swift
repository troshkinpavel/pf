import PFCore
import Foundation
import Testing
@testable import PFTerminal

/// Counts online searches and price requests; named like CoinGecko.
private final class CountingCoinGecko: MarketDataProvider, @unchecked Sendable {
    let name = "CoinGecko"
    var searches = 0, quoteCalls = 0
    var rateLimited = false
    func supports(_ a: Asset) -> Bool { true }
    func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        quoteCalls += 1
        if rateLimited { throw MarketError.rateLimited(retryAfter: 60) }
        return Dictionary(uniqueKeysWithValues: assets.map { ($0.id, Quote(price: 2, source: name, timestamp: Date())) })
    }
    func search(_ query: String) async throws -> [Asset] {
        searches += 1
        return [Asset(id: "cg:zz-long-tail", symbol: "ZZQX", name: "Long Tail", coingeckoID: "zz-long-tail")]
    }
}

@MainActor
struct MarketAppTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
    private let tel = AssetCatalog.known.first { $0.symbol == "TEL" }!
    private let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!

    private func store() -> AppStore {
        var o = AppStore.Options()
        o.directory = nil; o.inMemory = true; o.mockMarket = false; o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf-mkt-\(UUID().uuidString)")!
        let s = AppStore(o)
        s.createEmpty()
        return s
    }

    @Test func registrySearchIsInstantAndNeedsNoOnlineSearch() async throws {
        let s = store(), cg = CountingCoinGecko()
        await s.router.setProviders([cg])
        s.openTx(TxDraft(asset: "hyperliq"))
        #expect(s.tx?.searchResults.first?.symbol == "HYPE", "registry results before any request")
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(cg.searches == 0, "no /search for a registry asset")
        #expect(cg.quoteCalls <= 1, "at most one batched price request for the results")
    }

    @Test func longTailFallsBackToOnlineSearchOnce() async throws {
        let s = store(), cg = CountingCoinGecko()
        await s.router.setProviders([cg])
        s.openTx(TxDraft(asset: "zzqx"))
        #expect(s.tx?.searchResults.isEmpty == true)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(cg.searches == 1 && s.tx?.searchResults.first?.symbol == "ZZQX")
    }

    @Test func searchWorksOfflineAndDuringRateLimit() async throws {
        let s = store(), cg = CountingCoinGecko()
        cg.rateLimited = true
        await s.router.setProviders([cg])
        _ = await s.router.quotes(for: [btc], currency: "USD")          // puts CoinGecko in backoff
        #expect(await s.router.isBlocked("CoinGecko"))
        s.openTx(TxDraft(asset: "rende"))
        #expect(s.tx?.searchResults.first?.symbol == "RENDER", "local registry, no network needed")
        #expect(s.registrySearch("tel").first?.symbol == "TEL")
    }

    @Test func ambiguousTickerIsNeverAutoSelected() {
        let s = store()
        #expect(s.registryUnique("GUSD") == nil, "two registry assets share GUSD")
        #expect(s.registryUnique("SOL")?.id == "cg:solana")
        #expect(s.registryUnique("TEL")?.id == "cg:telcoin", "existing ledger id")
    }

    @Test func globalPreferenceRoutesAssetsWithoutTheirOwn() {
        let s = store()
        s.settings.primaryProvider = "CoinGecko"
        #expect(s.routed(btc).preferredSource == "CoinGecko")
        var own = btc; own.preferredSource = "Binance"
        #expect(s.routed(own).preferredSource == "Binance", "a per-asset choice wins")
        s.settings.primaryProvider = "Auto"
        #expect(s.routed(btc).preferredSource == nil)
    }

    @Test func feedPlanFollowsTheRoute() {
        let s = store()
        #expect(s.streamSources(btc) == [.binance])
        #expect(s.streamSources(tel) == [.bybit], "TEL: Bybit only (no Binance pair)")
        #expect(s.streamSources(usdc).isEmpty, "stablecoins: infrequent REST peg checks, no stream")
        var cgFirst = btc; cgFirst.preferredSource = "CoinGecko"
        #expect(s.streamSources(cgFirst).isEmpty, "preferred REST source: no stream")
        s.settings.realtimeProvider = "off"
        #expect(s.streamSources(btc).isEmpty)
    }

    @Test func bybitTickPricesTheAssetAndStatusFollows() {
        let s = store()
        s.doc.assets = [tel]
        s.applyTick(.bybit, LiveFeed.Tick(symbol: "TELUSDT", price: Decimal(string: "0.0044")!, change24h: 1.5))
        #expect(s.quotes[tel.id]?.source == "Bybit" && s.quotes[tel.id]?.price == Decimal(string: "0.0044"))
        #expect(s.quotes[tel.id]?.change24h == 1.5)
        s.applyTick(.binance, LiveFeed.Tick(symbol: "TELUSDT", price: 9, change24h: nil))
        #expect(s.quotes[tel.id]?.price == Decimal(string: "0.0044"), "no unverified Binance mapping for TEL: ignored")
    }

    @Test func settingsMigrateTheOldCoinGeckoDefaultToAuto() throws {
        let old = #"{"primaryProvider":"CoinGecko","currency":"USD"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.primaryProvider == "Auto" && s.routingVersion == 1)
        var chosen = AppSettings(); chosen.primaryProvider = "CoinGecko"
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(chosen))
        #expect(again.primaryProvider == "CoinGecko", "an explicit 0.5 choice stays")
    }
}
