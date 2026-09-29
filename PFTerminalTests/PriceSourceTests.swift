import PFCore
import Foundation
import Testing
@testable import PFTerminal

/// After pinning a DexScreener pool, the asset's original market must stay selectable,
/// even when the live symbol search returns nothing (offline / rate-limited).
@MainActor
struct PriceSourceTests {
    private func store() -> AppStore {
        var o = AppStore.Options()
        o.directory = nil
        o.inMemory = true
        o.mockMarket = true
        o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf-src-\(UUID().uuidString)")!
        return AppStore(o)   // not started: no providers, so search and probes return nothing
    }

    private func pinnedToPool(_ id: AssetID, _ symbol: String) -> Asset {
        Asset(id: id, symbol: symbol, name: symbol.lowercased(), coingeckoID: nil, binanceSymbol: nil,
              chain: "ethereum", contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7", preferredSource: "DexScreener")
    }

    @Test func originalMarketIsOfferedAfterPinningAPool() async {
        let s = store()
        let a = pinnedToPool("cg:tether", "USDT")
        let c = await s.sourceCandidates(for: a, currency: "USD")
        #expect(c.contains { $0.provider == "CoinGecko" && $0.label == "tether" }, "way back to CoinGecko (registry-verified)")
        #expect(c.first?.provider == "Auto")
        #expect(c.first { $0.isCurrent }?.provider == "DexScreener", "the pinned pool stays marked current")
        #expect(c.filter(\.isCurrent).count == 1)
    }

    @Test func catalogBinancePairIsOfferedEvenWithoutAQuote() async {
        let s = store()
        let pair = AssetCatalog.binanceSymbol(forCoinGecko: "bitcoin")
        #expect(pair != nil, "catalog maps bitcoin to a Binance pair")
        let c = await s.sourceCandidates(for: pinnedToPool("cg:bitcoin", "BTC"), currency: "USD")
        #expect(c.contains { $0.provider == "Binance" && $0.label == pair })
        #expect(c.contains { $0.provider == "CoinGecko" && $0.label == "bitcoin" })
    }

    @Test func guessedBinancePairWithoutQuoteIsStillDropped() async {
        let s = store()
        let c = await s.sourceCandidates(for: pinnedToPool("cg:tether", "USDT"), currency: "USD")
        #expect(!c.contains { $0.identity.binanceSymbol == "USDTUSDT" })
    }
}
