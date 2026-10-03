import PFCore
import PFCoreUI
import Foundation

// Watchlist (design §05) and watch → position (§06). The list lives in intel.json (this Mac);
// conversion records a real ledger transaction through the normal add-transaction sheet and
// then carries target / note / alert over. ⌘Z undoes both halves.

struct WatchDraft: Equatable {
    var editing: UUID?
    var asset = ""
    var entry = ""
    var target = ""
    var note = ""
}

struct WatchConvertState: Equatable {
    var item: WatchItem
    var carry = WatchConversion.CarryOver()
}

struct ConvertUndo {
    let txID: UUID
    let intelBefore: IntelDocument
    let symbol: String
}

extension AppStore {
    var watchRows: [Watchlist.Row] { Watchlist.rows(intel.watchlist, quotes: valuationQuotes) }

    /// ⚑ fired · ● armed · ○ none (paused rules count as none).
    func alertGlyph(_ id: AssetID) -> String {
        let rules = intel.alerts.filter { $0.subject == .asset(id) && !$0.paused }
        if rules.contains(where: { $0.state == .fired }) { return "⚑" }
        return rules.isEmpty ? "○" : "●"
    }

    func alertSummary(_ id: AssetID) -> String {
        let rules = intel.alerts.filter { $0.subject == .asset(id) }
        guard let r = rules.first(where: { !$0.paused }) ?? rules.first else { return "none · a to set" }
        return "#\(r.number) " + AlertEngine.condition(r, fmt: .current) + (r.paused ? " · paused" : r.state == .fired ? " · fired" : " · armed")
    }

    // MARK: add · edit · remove

    func openWatchAdd(_ symbol: String = "") {
        watchDraft = WatchDraft(asset: symbol)
    }

    func openWatchEdit(_ w: WatchItem) {
        let n = { (d: Decimal?) in d.map { "\($0)" } ?? "" }
        watchDraft = WatchDraft(editing: w.id, asset: w.asset.symbol, entry: n(w.entry), target: n(w.target), note: w.note ?? "")
    }

    /// Resolution for the watch sheet: ledger, watchlist, catalog, unique registry ticker,
    /// else the first registry search hit (shown in the sheet before saving).
    func watchDraftAsset(_ d: WatchDraft) -> Asset? {
        if let id = d.editing, let w = intel.watchlist.first(where: { $0.id == id }) { return w.asset }
        let q = d.asset.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return resolveAsset(q) ?? registrySearch(q).first
    }

    /// nil = valid; else what is wrong.
    func watchDraftProblem(_ d: WatchDraft) -> String? {
        guard watchDraftAsset(d) != nil else { return d.asset.isEmpty ? "type a ticker" : "no asset matches \(d.asset)" }
        for (k, v) in [("entry", d.entry), ("target", d.target)] where !v.isEmpty {
            guard let x = NumberInput.parse(v, style: Fmt.current.style), x > 0 else { return "\(k) must be a positive price" }
        }
        return nil
    }

    func saveWatch() {
        guard let d = watchDraft, watchDraftProblem(d) == nil, let a = watchDraftAsset(d) else { return }
        let entry = NumberInput.parse(d.entry, style: Fmt.current.style), target = NumberInput.parse(d.target, style: Fmt.current.style)
        let note = d.note.trimmingCharacters(in: .whitespaces)
        let ok = updateIntel { doc in
            if let id = d.editing, let i = doc.watchlist.firstIndex(where: { $0.id == id }) {
                doc.watchlist[i].entry = entry; doc.watchlist[i].target = target; doc.watchlist[i].note = note.isEmpty ? nil : note
            } else {
                Watchlist.add(a, price: quotes[a.id]?.price, entry: entry, target: target, note: note, to: &doc, now: Date())
            }
        }
        guard ok else { return }
        watchDraft = nil
        if let i = watchRows.firstIndex(where: { $0.item.assetID == a.id }) { watchSel = i }
        message = "✓ \(a.symbol) " + (d.editing == nil ? "added to the watchlist" : "updated")
        if quotes[a.id] == nil { Task { await refresh(auto: false) } }
    }

    /// ⌫ asks once, ⌫ again removes. Removing deletes the item (convert archives instead).
    func requestRemoveWatch(_ w: WatchItem) {
        if watchConfirmRemove == w.id {
            updateIntel { Watchlist.remove(w.id, from: &$0) }
            watchConfirmRemove = nil
            watchSel = max(0, min(watchSel, watchRows.count - 1))
            message = "✓ \(w.asset.symbol) removed from the watchlist"
        } else {
            watchConfirmRemove = w.id
            message = "⌫ again to remove \(w.asset.symbol) · esc keeps it"
        }
    }

    /// The price at add is unknown until the first quote arrives: fill it once, within a day.
    func backfillWatchPrices() {
        guard !protectedDataWaiting, !intelPrivateDeferred else { return }   // a strict-file write; waits for unlock
        let now = Date()
        let missing = intel.watchlist.filter { $0.isActive && $0.priceAtAdd == nil && now.timeIntervalSince($0.addedAt) < 86400 && quotes[$0.assetID] != nil }
        guard !missing.isEmpty else { return }
        updateIntel { doc in
            for i in doc.watchlist.indices where missing.contains(where: { $0.id == doc.watchlist[i].id }) {
                doc.watchlist[i].priceAtAdd = self.quotes[doc.watchlist[i].assetID]?.price
            }
        }
    }

    // MARK: convert

    func convertWatch(_ w: WatchItem) {
        guard intelReadOnly == nil else { message = "✗ " + (intelReadOnly ?? "read-only"); return }
        let price = (quotes[w.assetID]?.price).map { "\($0)" } ?? w.entry.map { "\($0)" } ?? ""
        openTx(TxDraft(type: .buy, asset: w.asset.symbol, price: price, note: w.note ?? ""))
        converting = WatchConvertState(item: w)
    }

    /// After the buy was recorded: carry-over into intel.json, remember ⌘Z.
    func finishConversion(_ c: WatchConvertState, tx t: Transaction) {
        var before = intel
        updateIntel { doc in before = WatchConversion.apply(c.item, tx: t.id, carry: c.carry, to: &doc, now: Date()) }
        convertUndo = ConvertUndo(txID: t.id, intelBefore: before, symbol: c.item.asset.symbol)
        var carried: [String] = []
        if c.carry.alert, c.item.target != nil { carried.append("1 alert") }
        if c.carry.target, c.item.target != nil { carried.append("1 target") }
        if c.carry.note, c.item.note != nil { carried.append("note") }
        let pf = doc.portfolio(t.portfolioID)?.name ?? "portfolio"
        message = "✓ \(c.item.asset.symbol) watch → \(pf)" + (carried.isEmpty ? "" : " · " + carried.joined(separator: ", ") + " carried") + " · ⌘Z undo"
    }

    func undoConversion() {
        guard let u = convertUndo else { return }
        convertUndo = nil
        if let t = doc.transactions.first(where: { $0.id == u.txID }) {
            do { try doc.removeTransaction(t) } catch {
                message = "✗ cannot undo: a later transaction depends on it"
                return
            }
            save()
            cache.invalidateSnapshots(from: t.timestamp)
        }
        intel = u.intelBefore
        saveIntel()
        recompute()
        go(.watch)
        message = "✓ \(u.symbol) conversion undone · back on the watchlist"
    }

    /// Price at add / planned entry / target / note for Asset Detail CONTEXT.
    func watchContext(_ id: AssetID) -> WatchItem? { Watchlist.history(id, in: intel) }
}
