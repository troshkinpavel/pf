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

    /// Source choices. Registry assets: Auto + each verified source (never unavailable ones); the
    /// choice only sets the preferred source. Other assets: Auto + every market found for the
    /// symbol (the older identity picker, for long-tail tokens).
    func sourceCandidates(for a: Asset, currency: String) async -> [SourceCandidate] {
        let auto = SourceCandidate(id: "auto", provider: "Auto", identity: a,
                                   label: sourceState(a.id).map { "\($0.status.label) · live feeds first" } ?? "live feeds first",
                                   quote: quotes[a.id], isCurrent: a.preferredSource == nil)
        guard AssetRegistry.shared.entry(for: a) != nil else {
            let markets = await marketCandidates(for: a, currency: currency)
            return [auto] + markets
        }
        var out = [auto]
        for s in MarketMappings.availableSources(a) {
            let label: String = {
                switch s {
                case .binance: MarketMappings.binanceSymbol(a) ?? ""
                case .bybit: MarketMappings.bybitSymbol(a) ?? ""
                case .coingecko: MarketMappings.coingeckoID(a) ?? ""
                default: MarketMappings.dexTargets(a).map { "\($0.chain) · \(Self.short($0.contract))" }.joined(separator: ", ")
                }
            }()
            var q = quotes[a.id].flatMap { $0.source == s.rawValue ? $0 : nil }
            if q == nil { q = await router.probe(a, provider: s.rawValue, currency: currency) }
            out.append(SourceCandidate(id: s.rawValue, provider: s.rawValue, identity: a, label: label, quote: q,
                                       isCurrent: a.preferredSource == s.rawValue))
        }
        return out
    }

    /// Every market found for the symbol, each quoted by its own provider (long-tail assets).
    func marketCandidates(for a: Asset, currency: String) async -> [SourceCandidate] {
        func ident(_ provider: String, cg: String? = nil, bn: String? = nil, chain: String? = nil, contract: String? = nil, name: String? = nil) -> Asset {
            Asset(id: "\(provider):\(cg ?? bn ?? "\(chain ?? ""):\(contract ?? "")")", symbol: a.symbol, name: name ?? a.name,
                  coingeckoID: cg, binanceSymbol: bn, chain: chain, contractAddress: contract)
        }
        var ids: [(String, Asset)] = []
        if let cg = a.coingeckoID { ids.append(("CoinGecko", ident("CoinGecko", cg: cg))) }
        if let bn = a.binanceSymbol { ids.append(("Binance", ident("Binance", bn: bn))) }
        if let ch = a.chain, let ct = a.contractAddress { ids.append(("DexScreener", ident("DexScreener", chain: ch, contract: ct))) }
        // The canonical id never changes and names the asset's original market. Offer it (and its
        // catalog Binance pair) even after applySource replaced the identifiers with another
        // provider's, so a pick can always be undone without relying on a live search.
        let parts = a.id.split(separator: ":").map(String.init)
        var catalogPair: String?
        if parts.count == 2, parts[0] == "cg" {
            ids.append(("CoinGecko", ident("CoinGecko", cg: parts[1])))
            catalogPair = AssetCatalog.binanceSymbol(forCoinGecko: parts[1])
            if let bn = catalogPair { ids.append(("Binance", ident("Binance", bn: bn))) }
        } else if parts.count == 3, parts[0] == "dex" {
            ids.append(("DexScreener", ident("DexScreener", chain: parts[1], contract: parts[2])))
        }
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
            // A guessed pair that doesn't quote doesn't exist; known pairs stay (maybe just offline).
            if q == nil && p == "Binance" && a.binanceSymbol == nil && i.binanceSymbol != catalogPair { continue }
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

    /// Point the asset at the chosen source. Auto clears the preference; a registry asset only
    /// records the preferred source (its verified identity stays); a long-tail asset switches market.
    /// The internal id never changes, so every transaction keeps its link.
    func applySource(_ c: SourceCandidate) {
        guard let id = sourcePicker?.assetID, let i = doc.assets.firstIndex(where: { $0.id == id }) else { return }
        if c.provider == "Auto" || AssetRegistry.shared.entry(for: doc.assets[i]) != nil {
            doc.assets[i].preferredSource = c.provider == "Auto" ? nil : c.provider
            save()
            sourcePicker = nil
            connectStream()
            recompute()
            message = "✓ \(doc.assets[i].symbol) price source · " + (c.provider == "Auto" ? "auto (live feeds first)" : c.provider.lowercased())
            Task { await refresh(auto: false) }
            return
        }
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

    /// Prices already known for search results (live, polled or cached): no request.
    func knownQuotes(_ results: [Asset]) -> [AssetID: Quote] {
        let cached = cache.quotes(currency: settings.currency)
        return Dictionary(uniqueKeysWithValues: results.compactMap { a in (quotes[a.id] ?? cached[a.id]).map { (a.id, $0) } })
    }

    /// Prices for search results so the user can tell the real market from a lookalike: known
    /// prices first, then a single batched router request for the top results still missing one.
    /// No per-result probes.
    func priceSearchResults(_ results: [Asset]) async -> [AssetID: Quote] {
        var out = knownQuotes(results)
        let missing = results.prefix(5).filter { out[$0.id] == nil }
        guard !missing.isEmpty else { return out }
        let r = await router.quotes(for: missing.map(routed), currency: settings.currency)
        out.merge(r.quotes) { a, _ in a }
        return out
    }
}
