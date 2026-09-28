import PFCore
import PFCoreUI
import Foundation

/// One market for an asset: a single provider identity plus its live quote, for comparison.
struct SourceCandidate: Identifiable, Equatable {
    let id: String            // "<provider>:<key>"
    let provider: String      // "CoinGecko" | "Binance" | "DexScreener"
    let identity: Asset       // only this provider's identifier is set
    let label: String         // "immutable-x", "IMXUSDT", "ethereum · 0xf57e…ad3a"
    var quote: Quote?
    var isCurrent: Bool
}

struct SourcePickerState: Equatable {
    var assetID: AssetID
    var candidates: [SourceCandidate] = []
    var loading = true
    var sel = 0
}

/// Volume below this makes a quote untrustworthy (thin DEX pools, dead markets).
let lowLiquidityVolume: Decimal = 10_000

extension AppStore {
    // MARK: price source picker (existing assets)

    func openSourcePicker(_ id: AssetID) {
        guard let a = asset(id) else { return }
        palette = nil; tx = nil
        sourcePicker = SourcePickerState(assetID: id)
        let cur = settings.currency
        Task {
            let cands = await sourceCandidates(for: a, currency: cur)
            guard sourcePicker?.assetID == id else { return }
            sourcePicker?.candidates = cands
            sourcePicker?.loading = false
            sourcePicker?.sel = cands.firstIndex(where: \.isCurrent) ?? 0
        }
    }

    /// Every market we can find for the asset's symbol, each quoted by its own provider.
    func sourceCandidates(for a: Asset, currency: String) async -> [SourceCandidate] {
        func ident(_ provider: String, cg: String? = nil, bn: String? = nil, chain: String? = nil, contract: String? = nil, name: String? = nil) -> Asset {
            Asset(id: "\(provider):\(cg ?? bn ?? "\(chain ?? ""):\(contract ?? "")")", symbol: a.symbol, name: name ?? a.name,
                  coingeckoID: cg, binanceSymbol: bn, chain: chain, contractAddress: contract)
        }
        var ids: [(String, Asset)] = []
        if let cg = a.coingeckoID { ids.append(("CoinGecko", ident("CoinGecko", cg: cg))) }
        if let bn = a.binanceSymbol { ids.append(("Binance", ident("Binance", bn: bn))) }
        if let ch = a.chain, let ct = a.contractAddress { ids.append(("DexScreener", ident("DexScreener", chain: ch, contract: ct))) }
        for f in await router.search(a.symbol) where f.symbol == a.symbol.uppercased() {
            if let cg = f.coingeckoID { ids.append(("CoinGecko", ident("CoinGecko", cg: cg, name: f.name))) }
            if let ch = f.chain, let ct = f.contractAddress { ids.append(("DexScreener", ident("DexScreener", chain: ch, contract: ct, name: f.name))) }
        }
        // Binance lists USDT pairs by ticker: offered as a candidate, never assumed.
        ids.append(("Binance", ident("Binance", bn: a.symbol.uppercased() + "USDT")))

        var seen = Set<String>(), out: [SourceCandidate] = []
        for (p, i) in ids where !seen.contains(i.id) {
            seen.insert(i.id)
            let q = await router.probe(i, provider: p, currency: currency)
            if q == nil && p == "Binance" && a.binanceSymbol == nil { continue }   // guessed pair doesn't exist
            let current = (p == "CoinGecko" && i.coingeckoID == a.coingeckoID) || (p == "Binance" && i.binanceSymbol == a.binanceSymbol)
                || (p == "DexScreener" && i.contractAddress?.lowercased() == a.contractAddress?.lowercased() && a.contractAddress != nil)
            let label = i.coingeckoID ?? i.binanceSymbol ?? "\(i.chain ?? "") · \(Self.short(i.contractAddress))"
            out.append(SourceCandidate(id: i.id, provider: p, identity: i, label: label, quote: q,
                                       isCurrent: current && (a.preferredSource == nil || a.preferredSource == p)))
        }
        // Liquid, listed markets first.
        let order = ["CoinGecko": 0, "Binance": 1, "DexScreener": 2]
        return out.sorted { (order[$0.provider] ?? 3, -($0.quote?.volume24h?.double ?? 0)) < (order[$1.provider] ?? 3, -($1.quote?.volume24h?.double ?? 0)) }
    }

    static func short(_ addr: String?) -> String {
        guard let a = addr, a.count > 12 else { return addr ?? "" }
        return a.prefix(6) + "…" + a.suffix(4)
    }

    /// Point the asset at the chosen market. The internal id is unchanged, so every
    /// transaction in every portfolio keeps its link; only the provider mapping changes.
    func applySource(_ c: SourceCandidate) {
        guard let id = sourcePicker?.assetID, let i = doc.assets.firstIndex(where: { $0.id == id }) else { return }
        var a = doc.assets[i]
        a.coingeckoID = c.identity.coingeckoID
        a.binanceSymbol = c.identity.binanceSymbol ?? (c.provider == "CoinGecko" ? AssetCatalog.binanceSymbol(forCoinGecko: c.identity.coingeckoID ?? "") : nil)
        a.chain = c.identity.chain
        a.contractAddress = c.identity.contractAddress
        if c.provider == "CoinGecko" { a.name = c.identity.name }
        a.preferredSource = c.provider
        doc.assets[i] = a
        save()
        if var q = c.quote { q.source = c.provider; quotes[id] = q }
        series = series.filter { !$0.key.hasPrefix(id + "|") }
        cache.deleteHistory(assetID: id)
        cache.invalidateSnapshots(from: .distantPast)
        sourcePicker = nil
        recompute()
        loadHistory([id], assetRange)
        message = "✓ \(a.symbol) now priced from \(c.provider.lowercased()) · \(c.label)" + (c.quote.map { " · " + Fmt.current.price($0.price) } ?? "")
        Task { await refresh(auto: false) }
    }

    // MARK: transaction sheet candidates

    /// Quote search results so the user can tell the real market from a lookalike.
    func probeSearchResults(_ results: [Asset]) async -> [AssetID: Quote] {
        var out: [AssetID: Quote] = [:]
        for a in results.prefix(5) {
            let p = a.coingeckoID != nil ? "CoinGecko" : "DexScreener"
            if let q = await router.probe(a, provider: p, currency: settings.currency) { out[a.id] = q }
        }
        return out
    }
}
