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

    /// Ledger assets first (the user's own identities), then the bundled catalog, then search hits.
    func resolveAsset(_ text: String, searchResults: [Asset] = []) -> Asset? {
        AssetCatalog.resolve(text, in: doc.assets) ?? AssetCatalog.resolve(text, in: AssetCatalog.known)
            ?? searchResults[safe: tx?.pick ?? 0] ?? searchResults.first
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
        tx?.searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let r = await router.search(q)
            guard !Task.isCancelled, tx?.asset.trimmingCharacters(in: .whitespaces) == q else { return }
            tx?.searchResults = r
            tx?.pick = 0
            tx?.searching = false
            let qs = await probeSearchResults(r)
            if tx?.asset.trimmingCharacters(in: .whitespaces) == q { tx?.candidateQuotes = qs }
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
        TransactionPlanner.preview(d, doc: doc, quotes: quotes, currency: settings.currency,
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
