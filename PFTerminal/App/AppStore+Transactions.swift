import PFCore
import PFCoreUI
import Foundation
import SwiftUI

extension TxPreview.Row {
    var c: Color {
        switch tone {
        case .primary: Theme.t1; case .secondary: Theme.t2; case .accent: Theme.acc; case .negative: Theme.neg
        case let .sign(v): Theme.signColor(v)
        }
    }
}

extension AppStore {
    func openTx(_ pre: TxDraft? = nil) {
        var d = pre ?? TxDraft()
        if pre == nil, (screen == .asset || screen == .target), let a = asset(assetID) { d.asset = a.symbol }
        if d.portfolioID == nil || doc.portfolio(d.portfolioID!)?.isArchived != false { d.portfolioID = defaultTransactionPortfolio }
        palette = nil
        quickShare = false
        tx = d
        if !d.asset.isEmpty { draftAssetChanged() }
    }

    func editTx(_ t: Transaction) {
        guard let a = asset(t.assetID) else { return }
        tx = TxDraft(editing: t.id, portfolioID: t.portfolioID, type: t.type, asset: a.symbol, amount: "\(t.quantity)", price: "\(t.price)",
                     date: DateFmt.ymd(t.timestamp), fee: t.fee > 0 ? "\(t.fee)" : "", note: t.note ?? "")
    }

    /// Ledger assets first (the user's own identities), then the bundled catalog, then an
    /// unambiguous registry symbol, then the picked search hit. A ticker the registry lists more
    /// than once is never auto-selected.
    func resolveAsset(_ text: String, searchResults: [Asset] = []) -> Asset? {
        AssetCatalog.resolve(text, in: doc.assets) ?? AssetCatalog.resolve(text, in: AssetCatalog.known)
            ?? registryUnique(text) ?? searchResults[safe: tx?.pick ?? 0] ?? searchResults.first
    }

    /// The registry asset for an exact ticker, only when exactly one record has it.
    func registryUnique(_ text: String) -> Asset? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return nil }
        let hits = AssetRegistry.shared.entries(symbol: t)
        return hits.count == 1 ? AssetRegistry.shared.asset(for: hits[0]) : nil
    }

    /// Local registry search (instant, offline), as ledger assets.
    func registrySearch(_ q: String) -> [Asset] {
        AssetRegistry.shared.search(q, limit: 8).map { AssetRegistry.shared.asset(for: $0) }
    }

    func draftAssetChanged() {
        searchTask?.cancel()
        guard let d = tx else { return }
        let q = d.asset.trimmingCharacters(in: .whitespaces)
        if let a = resolveAsset(q) {
            tx?.searchResults = []; tx?.searching = false
            fetchDraftQuote(a)
            return
        }
        if q.count < 2 { tx?.searchResults = []; tx?.searching = false; return }
        // 1. Registry results immediately (offline, no request).
        let local = registrySearch(q)
        tx?.searchResults = local
        tx?.pick = 0
        tx?.candidateQuotes = knownQuotes(local)
        tx?.searching = local.isEmpty
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            // 2. Long tail only: online discovery when the registry knows nothing (respects backoff).
            var results = local
            if local.isEmpty {
                results = await router.search(q)
                guard !Task.isCancelled, tx?.asset.trimmingCharacters(in: .whitespaces) == q else { return }
                tx?.searchResults = results
                tx?.pick = 0
            }
            tx?.searching = false
            // 3. One batched price request for results with no known price (exchanges first).
            let qs = await priceSearchResults(results)
            if tx?.asset.trimmingCharacters(in: .whitespaces) == q { tx?.candidateQuotes.merge(qs) { _, b in b } }
        }
    }

    /// A known asset the portfolio doesn't hold isn't in the refresh set, so it has no quote yet:
    /// fetch one for the price placeholder. No quote → the field stays empty ("no market price").
    func fetchDraftQuote(_ a: Asset) {
        guard quotes[a.id] == nil, tx?.candidateQuotes[a.id] == nil else { return }
        tx?.searching = true
        searchTask = Task {
            let q = await router.quotes(for: [a], currency: settings.currency).quotes[a.id]
            guard !Task.isCancelled, let d = tx, resolveAsset(d.asset)?.id == a.id else { return }
            if let q { tx?.candidateQuotes[a.id] = q }
            tx?.searching = false
        }
    }

    func preview(_ d: TxDraft) -> TxPreview {
        TransactionPlanner.preview(d, doc: doc, quotes: valuationQuotes, currency: settings.currency,
                                   resolve: { resolveAsset($0, searchResults: $1) })
    }

    /// Commit only after explicit confirmation from the preview.
    func confirmTx() {
        guard let d = tx else { return }
        let p = preview(d)
        guard p.ok, let t = p.tx, let a = p.asset else { return }
        let f = Fmt.current
        let beforeAvg = PortfolioEngine.positions(doc.transactions.filter { $0.portfolioID == t.portfolioID })[a.id]?.averageEntry
        let old = d.editing.flatMap { id in doc.transactions.first { $0.id == id } }
        doc.upsert(t, asset: a)
        save()
        cache.invalidateSnapshots(from: min(t.timestamp, old?.timestamp ?? t.timestamp))
        tx = nil
        recompute()
        let afterAvg = PortfolioEngine.positions(doc.transactions.filter { $0.portfolioID == t.portfolioID })[a.id]?.averageEntry
        if context != .all { context = .portfolio(t.portfolioID); persistContext(); recompute() }
        message = "✓ \(p.line) \(old == nil ? "recorded" : "updated")" + (t.type == .buy ? " · avg entry \(f.price(beforeAvg ?? t.price)) → \(f.price(afterAvg))" : "")
        if summary.valuation(a.id) != nil { openAsset(a.id) } else { go(.overview) }
        Task { await refresh(auto: false) }
    }

    func requestDelete(_ t: Transaction) { pendingDelete = t }

    func deleteTx(_ t: Transaction) {
        pendingDelete = nil
        do { try doc.removeTransaction(t) } catch {
            message = "✗ cannot delete: a later transaction depends on it · \(error)"
            return
        }
        save()
        cache.invalidateSnapshots(from: t.timestamp)
        recompute()
        txSel = 0
        message = "✓ transaction deleted · \(t.type.short) \(Fmt.current.amount(t.quantity)) \(asset(t.assetID)?.symbol ?? "")"
        if summary.valuation(t.assetID) == nil && screen == .asset { go(.overview) }
    }
}
