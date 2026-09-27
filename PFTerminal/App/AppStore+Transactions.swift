import Foundation
import SwiftUI

struct TxPreview {
    struct Row: Identifiable { let id = UUID(); let k: String; let v: String; let c: Color }
    var line: String
    var rows: [Row] = []
    var ok = false
    var tx: Transaction?
    var asset: Asset?
    var assetHint = ""
    var assetHintError = false
    var pricePlaceholder = "3500"
}

extension AppStore {
    func openTx(_ pre: TxDraft? = nil) {
        var d = pre ?? TxDraft()
        if pre == nil, (screen == .asset || screen == .target), let a = asset(assetID) { d.asset = a.symbol }
        if d.portfolioID == nil || doc.portfolio(d.portfolioID!)?.isArchived != false { d.portfolioID = defaultTransactionPortfolio }
        palette = nil
        quickShare = false
        tx = d
        if !d.asset.isEmpty, resolveAsset(d.asset) == nil { draftAssetChanged() }
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
        if q.count < 2 || resolveAsset(q) != nil { tx?.searchResults = []; tx?.searching = false; return }
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

    func preview(_ d: TxDraft) -> TxPreview {
        let f = Fmt.current
        var p = TxPreview(line: d.type.short + " — enter asset, amount, price")
        let a = resolveAsset(d.asset, searchResults: d.searchResults)
        p.asset = a
        if let a {
            let isSearch = !doc.assets.contains(a) && !AssetCatalog.known.contains(a)
            p.assetHint = a.name.lowercased() + (quotes[a.id].map { " · " + f.price($0.price) } ?? "") + (isSearch ? " · " + (a.chain.map { "\($0) token" } ?? "coingecko:\(a.coingeckoID ?? "")") : "")
            if let q = quotes[a.id] ?? d.candidateQuotes[a.id] { p.pricePlaceholder = "market " + f.priceDigits(q.price.double) }
        } else if !d.asset.isEmpty {
            p.assetHint = d.searching ? "searching…" : "no match"
            p.assetHintError = !d.searching
        }
        let amount = NumberInput.parse(d.amount)
        let marketPrice = a.flatMap { quotes[$0.id]?.price ?? d.candidateQuotes[$0.id]?.price }
        let price: Decimal? = d.price.trimmingCharacters(in: .whitespaces).isEmpty ? marketPrice : (d.price.trimmingCharacters(in: .whitespaces) == "0" ? 0 : NumberInput.parse(d.price))
        let fee: Decimal? = d.fee.trimmingCharacters(in: .whitespaces).isEmpty || d.fee == "0" ? 0 : NumberInput.parse(d.fee)
        let date = DateFmt.parseYMD(d.date)
        guard let a, let amount, let price else { return p }
        guard let pid = d.portfolioID, let dest = doc.portfolio(pid), !dest.isArchived else {
            p.rows = [.init(k: "error", v: "choose a portfolio", c: Theme.neg)]; return p
        }
        p.line = "\(d.type.short) \(f.amount(amount)) \(a.symbol) @ \(f.price(price))"
        guard let fee else { p.rows = [.init(k: "error", v: "invalid fee", c: Theme.neg)]; return p }
        guard var date else { p.rows = [.init(k: "error", v: "date must be YYYY-MM-DD", c: Theme.neg)]; return p }
        if DateFmt.ymd(date) == DateFmt.ymd(Date()) { date = min(Date(), date) }
        if date > Date().addingTimeInterval(60) { p.rows = [.init(k: "error", v: "date is in the future", c: Theme.neg)]; return p }
        // Keep the original time of day when editing an unchanged date.
        let old = d.editing.flatMap { id in doc.transactions.first { $0.id == id } }
        if let old, DateFmt.ymd(old.timestamp) == d.date { date = old.timestamp }

        let t = Transaction(id: d.editing ?? UUID(), portfolioID: pid, assetID: a.id, type: d.type, quantity: amount, price: price,
                            currency: settings.currency, timestamp: date, fee: fee, note: d.note.isEmpty ? nil : d.note)
        // Holdings and validation are per destination portfolio: a sell can't use another portfolio's coins.
        let current = doc.transactions.filter { $0.portfolioID == pid }
        var ledger = current.filter { $0.id != d.editing }
        ledger.append(t)
        let before = PortfolioEngine.positions(current)[a.id] ?? Position(assetID: a.id)
        let after = PortfolioEngine.positions(ledger)[a.id] ?? Position(assetID: a.id)
        var errs = PortfolioEngine.validate(ledger)
        // Moving an edited transaction out of its old portfolio must leave that one valid too.
        if let old, old.portfolioID != pid {
            errs += PortfolioEngine.validate(doc.transactions.filter { $0.portfolioID == old.portfolioID && $0.id != old.id })
        }
        if let e = errs.first(where: { if case .oversold = $0 { return true }; return false }) {
            if case let .oversold(_, held, _) = e {
                p.rows = [.init(k: "error", v: "only \(f.amount(held)) \(a.symbol) held at that date", c: Theme.neg)]
            }
            return p
        }
        guard errs.isEmpty else { p.rows = [.init(k: "error", v: errs[0].description, c: Theme.neg)]; return p }

        let pos = "\(f.amount(before.quantity)) → \(f.amount(after.quantity)) \(a.symbol)"
        let avg = "\(f.price(before.averageEntry ?? price)) → \(f.price(after.averageEntry ?? before.averageEntry ?? price))"
        switch d.type {
        case .buy:
            p.rows = [.init(k: "cost", v: f.money(amount * price + fee), c: Theme.t1), .init(k: "position", v: pos, c: Theme.t2), .init(k: "avg entry", v: avg, c: Theme.t1)]
        case .sell:
            let rl = after.realizedPnL - before.realizedPnL
            p.rows = [.init(k: "proceeds", v: f.money(amount * price - fee), c: Theme.t1), .init(k: "position", v: pos, c: Theme.t2),
                      .init(k: "realized pnl", v: f.signed(rl), c: Theme.signColor(rl))]
        case .transferIn:
            p.rows = [.init(k: "cost basis added", v: f.money(amount * price + fee), c: Theme.t1), .init(k: "position", v: pos, c: Theme.t2), .init(k: "avg entry", v: avg, c: Theme.t1)]
        case .transferOut:
            p.rows = [.init(k: "position", v: pos, c: Theme.t2), .init(k: "cost basis removed", v: f.money(before.costBasis - after.costBasis), c: Theme.t1)]
        }
        p.rows.insert(.init(k: "portfolio", v: dest.glyph + " " + dest.name, c: Theme.t2), at: 0)
        if d.editing != nil { p.rows.insert(.init(k: "edit", v: "replaces the original transaction", c: Theme.acc), at: 0) }
        p.ok = true
        p.tx = t
        return p
    }

    /// Commit only after explicit confirmation from the preview.
    func confirmTx() {
        guard let d = tx else { return }
        let p = preview(d)
        guard p.ok, let t = p.tx, let a = p.asset else { return }
        let f = Fmt.current
        let beforeAvg = PortfolioEngine.positions(doc.transactions.filter { $0.portfolioID == t.portfolioID })[a.id]?.averageEntry
        let old = d.editing.flatMap { id in doc.transactions.first { $0.id == id } }
        if !doc.assets.contains(where: { $0.id == a.id }) { doc.assets.append(a) }
        if let i = doc.transactions.firstIndex(where: { $0.id == t.id }) { doc.transactions[i] = t } else { doc.transactions.append(t) }
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
        let ledger = doc.transactions.filter { $0.id != t.id }
        if let e = PortfolioEngine.validate(ledger.filter { $0.portfolioID == t.portfolioID }).first {
            message = "✗ cannot delete: a later transaction depends on it · \(e)"
            return
        }
        doc.transactions = ledger
        // Drop assets no longer referenced.
        doc.assets.removeAll { a in !ledger.contains { $0.assetID == a.id } }
        save()
        cache.invalidateSnapshots(from: t.timestamp)
        recompute()
        txSel = 0
        message = "✓ transaction deleted · \(t.type.short) \(Fmt.current.amount(t.quantity)) \(asset(t.assetID)?.symbol ?? "")"
        if summary.valuation(t.assetID) == nil && screen == .asset { go(.overview) }
    }
}
