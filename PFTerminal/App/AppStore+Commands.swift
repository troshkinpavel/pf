import PFCore
import PFCoreUI
import AppKit
import SwiftUI

// MARK: - Command palette

extension AppStore {
    func openPalette(_ q: String = "") {
        tx = nil; quickShare = false
        palette = PaletteState(query: q, sel: 0)
    }

    func paletteItems(_ q: String) -> [PaletteItem] {
        let f = Fmt.current
        var items: [PaletteItem] = []
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        let cmd = CommandParser.parse(trimmed)

        switch cmd {
        case let .trade(type, assetText, amount, price, pfText)?:
            let a = resolveAsset(assetText)
            let amt = NumberInput.parse(amount)
            let px = NumberInput.parse(price) ?? a.flatMap { quotes[$0.id]?.price }
            // "in <portfolio>" picks the destination; otherwise the active one (ALL asks in the preview).
            let dest = pfText.flatMap { doc.resolvePortfolio($0) }
            let draft = TxDraft(portfolioID: dest?.id ?? defaultTransactionPortfolio, type: type, asset: a?.symbol ?? assetText.uppercased(), amount: amount ?? "", price: price ?? "")
            let destLabel = (dest ?? draft.portfolioID.flatMap { doc.portfolio($0) }).map { " → " + $0.glyph + " " + $0.name.lowercased() } ?? ""
            if pfText != nil && dest == nil {
                items.append(PaletteItem(label: "\(type.short) \(assetText.uppercased())", detail: "no portfolio matches \"\(pfText!)\"", hint: "", isCommand: true, run: {}))
            } else if let a {
                items.append(PaletteItem(
                    label: "\(type.short) \(amt.map(f.amount) ?? "…") \(a.symbol) @ \(f.price(px))\(destLabel)",
                    detail: amt.flatMap { a in px.map { (type == .buy ? "cost " : type == .sell ? "proceeds " : "value ") + f.money(a * $0) } } ?? "amount missing",
                    hint: "↵ review", isCommand: true, run: { [weak self] in self?.openTx(draft) }))
            } else {
                items.append(PaletteItem(label: "\(type.short) \(assetText.uppercased())", detail: "unknown asset · search providers", hint: "↵ review",
                                         isCommand: true, run: { [weak self] in self?.openTx(draft) }))
            }
        case let .switchPortfolio(name)?:
            var cands: [(PortfolioContext, String, String)] = []
            let q = name.trimmingCharacters(in: .whitespaces)
            if "all".hasPrefix(q) || "all portfolios".hasPrefix(q) { cands.append((.all, PortfolioGlyphs.aggregate, "ALL PORTFOLIOS")) }
            cands += doc.livePortfolios.map { ($0, Fuzzy.score(q, $0.name)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
                .map { (.portfolio($0.0.id), $0.0.glyph, $0.0.name) }
            for (c, g, n) in cands.prefix(4) {
                let s = summary(for: c)
                items.append(PaletteItem(label: "Switch to \(g) \(n)", detail: s.isEmpty ? "empty" : f.money(s.totalValue, 0) + "  " + f.pct(s.change24hPct),
                                         hint: c == context ? "active" : "↵", isCommand: true, run: { [weak self] in self?.setContext(c) }))
            }
            if cands.isEmpty {
                items.append(PaletteItem(label: "New portfolio \"\(PortfolioDocument.normalizedName(name))\"", detail: "no portfolio matches", hint: "↵",
                                         isCommand: true, run: { [weak self] in self?.openNewPortfolio(name) }))
            }
        case let .newPortfolio(name)?:
            items.append(PaletteItem(label: "New portfolio" + (name.isEmpty ? "" : " \"\(PortfolioDocument.normalizedName(name))\""),
                                     detail: "name · glyph · empty or import", hint: "↵", isCommand: true, run: { [weak self] in self?.openNewPortfolio(name) }))
        case .managePortfolios?:
            items.append(PaletteItem(label: "Manage portfolios", detail: "rename · archive · delete", hint: "↵", isCommand: true, run: { [weak self] in self?.go(.portfolios) }))
        case .openSwitcher?:
            items.append(PaletteItem(label: "Switch portfolio", detail: contextGlyph + " " + contextName.lowercased(), hint: "⌘P", isCommand: true, run: { [weak self] in self?.palette = nil; self?.openSwitcher() }))
        case let .target(assetText, value)?:
            if let v = resolveHeld(assetText), let px = v.price {
                let tv = value.flatMap { NumberInput.target($0, current: px) } ?? ScenarioEngine.presets(for: px).dropFirst(2).first ?? px
                let s = ScenarioEngine.evaluate(target: tv, quantity: v.position.quantity, costBasis: v.position.costBasis, currentPrice: px,
                                                portfolioTotal: summary.totalValue, circulatingSupply: v.quote?.circulatingSupply, ath: v.quote?.ath)
                items.append(PaletteItem(label: "\(v.asset.symbol) → \(f.price(tv))",
                                         detail: f.money(s.positionValue, 0) + (s.multiple.map { " · " + f.num($0, 2) + "x" } ?? ""),
                                         hint: "↵ open scenario", isCommand: true,
                                         run: { [weak self] in self?.openTarget(v.asset.id, value ?? "\(tv)") }))
            }
        case let .share(o)?:
            if !o.isEmpty {
                var eff = share; eff.apply(o)
                items.append(PaletteItem(label: "Share card · \(eff.period.rawValue) · \(eff.privacy.label) · \(eff.format.rawValue)", detail: "quick preview",
                                         hint: "↵ preview", isCommand: true, run: { [weak self] in
                    self?.share.apply(o); self?.palette = nil; self?.quickShare = true
                }))
            } else {
                items.append(PaletteItem(label: "Share portfolio", detail: "last: \(share.period.rawValue) · \(share.privacy.label) · \(share.format.rawValue)",
                                         hint: "⌘⇧S", isCommand: true, run: { [weak self] in self?.go(.share) }))
                items.append(PaletteItem(label: "Quick share · last settings", detail: "then ⌘C", hint: "⌘⇧S", isCommand: true,
                                         run: { [weak self] in self?.palette = nil; self?.quickShare = true }))
            }
        default: break
        }

        // Parsed commands rank first; fuzzy matches are only shown for free text and navigation words.
        let structured: Bool = { guard let c = cmd else { return false }; if case .navigate = c { return false }; return true }()
        let toks = CommandParser.tokens(trimmed)
        if toks.count == 1, toks[0].count >= 2, !structured, cmd == nil, let a = resolveAsset(toks[0]) {
            let q = quotes[a.id]
            items.append(PaletteItem(label: "Open " + a.symbol, detail: q.map { f.price($0.price) + "  " + f.pct($0.change24h) } ?? a.name.lowercased(),
                                     hint: "↵", isCommand: true, run: { [weak self] in self?.openAssetOrAdd(a) }))
        }

        let isOpen = trimmed.lowercased().hasPrefix("open")
        let fq = isOpen ? String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) : trimmed
        var base: [(PaletteItem, String)] = [
            (PaletteItem(label: "Add transaction", hint: "⌘N", run: { [weak self] in self?.openTx() }), "buy sell new tx transfer"),
            (PaletteItem(label: "Share portfolio card", hint: "⌘⇧S", run: { [weak self] in self?.go(.share) }), "share image social export"),
            (PaletteItem(label: "Switch portfolio", hint: "⌘P", run: { [weak self] in self?.palette = nil; self?.openSwitcher() }), "portfolio context session"),
            (PaletteItem(label: "All portfolios", hint: "portfolio all", run: { [weak self] in self?.setContext(.all); self?.go(.overview) }), "aggregate total combined"),
            (PaletteItem(label: "New portfolio", hint: "new portfolio", run: { [weak self] in self?.openNewPortfolio() }), "create add"),
            (PaletteItem(label: "Manage portfolios", hint: "", run: { [weak self] in self?.go(.portfolios) }), "rename archive delete"),
            (PaletteItem(label: "Search asset", hint: "/", run: { [weak self] in self?.palette = PaletteState(query: "open ") }), "find /"),
        ]
        for v in summary.positions {
            base.append((PaletteItem(label: "Open " + v.asset.symbol, detail: v.asset.name.lowercased() + " · " + f.price(v.price) + " " + f.pct(v.change24h),
                                     hint: v.asset.symbol.lowercased(), run: { [weak self] in self?.openAsset(v.asset.id) }), v.asset.name))
        }
        if let top = summary.positions.first {
            base.append((PaletteItem(label: "Set \(top.asset.symbol) target", hint: "target \(top.asset.symbol.lowercased())",
                                     run: { [weak self] in self?.openTarget(top.asset.id) }), "scenario simulate target"))
        }
        base += [
            (PaletteItem(label: "Show portfolio P&L", hint: "pnl", run: { [weak self] in self?.go(.analytics) }), "pnl analytics profit"),
            (PaletteItem(label: "Show allocation", hint: "allocation", run: { [weak self] in self?.go(.analytics) }), "allocation weights"),
            (PaletteItem(label: "Show biggest winners", hint: "movers", run: { [weak self] in
                self?.moversMode = .pct; self?.moversDesc = true; self?.msel = 0; self?.go(.movers) }), "movers gainers"),
            (PaletteItem(label: "Show biggest losers", hint: "movers -", run: { [weak self] in
                self?.moversMode = .pct; self?.moversDesc = false; self?.msel = 0; self?.go(.movers) }), "movers losers"),
            (PaletteItem(label: "Go to portfolio", hint: "⌘1", run: { [weak self] in self?.go(.overview) }), "portfolio overview home positions"),
            (PaletteItem(label: "Refresh market data", hint: "⌘R", run: { [weak self] in self?.palette = nil; Task { await self?.refresh(auto: false) } }), "reload prices"),
            (PaletteItem(label: "Export portfolio", hint: ".json", run: { [weak self] in self?.palette = nil; self?.exportBackup() }), "json backup save"),
            (PaletteItem(label: "Import portfolio", hint: ".json", run: { [weak self] in self?.palette = nil; self?.importBackup() }), "json load restore"),
            (PaletteItem(label: "Open settings", hint: "⌘,", run: { [weak self] in self?.go(.settings) }), "preferences config"),
            (PaletteItem(label: "iCloud sync settings", detail: syncStatusLabel, hint: "sync", run: { [weak self] in self?.go(.settings) }), "sync icloud cloud data"),
        ]
        if doc.portfolios.contains(where: \.isDemo) {
            base.append((PaletteItem(label: "Remove demo data", detail: "restore an empty portfolio", hint: "demo", run: { [weak self] in self?.palette = nil; self?.removeDemo() }), "remove demo clear"))
        } else if doc.transactions.isEmpty {
            base.append((PaletteItem(label: "Load demo portfolio", detail: "sample data, clearly marked", hint: "demo", run: { [weak self] in self?.palette = nil; self?.loadDemo() }), "demo sample"))
        }

        let pool0 = isOpen ? base.filter { $0.0.label.hasPrefix("Open ") && $0.0.label != "Open settings" } : base
        let pool = pool0
        let ranked: [PaletteItem] = structured ? [] : pool.map { ($0.0, max(Fuzzy.score(fq, $0.0.label), Fuzzy.score(fq, $0.1) - 1)) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        let seen = Set(items.map(\.label))
        return Array((items + ranked.filter { !seen.contains($0.label) }).prefix(11))
    }

    private func resolveHeld(_ text: String) -> PositionValuation? {
        guard let a = AssetCatalog.resolve(text, in: summary.positions.map(\.asset)) else { return nil }
        return summary.valuation(a.id)
    }

    func openAssetOrAdd(_ a: Asset) {
        if summary.valuation(a.id) != nil { openAsset(a.id) } else { openTx(TxDraft(asset: a.symbol)) }
    }

    func runPaletteSelection() {
        guard let p = palette else { return }
        let items = paletteItems(p.query)
        guard !items.isEmpty else { return }
        items[min(p.sel, items.count - 1)].run()
    }
}

// MARK: - Keyboard

extension AppStore {
    /// Routes key presses like a TUI. Returns true when consumed. Text editing keeps
    /// its normal shortcuts: plain keys are ignored while an input has focus.
    func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === mainWindow, !locked else { return false }
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        // Physical key (ANSI position) so shortcuts work on any keyboard layout, e.g. ⌘K on Russian.
        let k = Self.latinKey[e.keyCode] ?? e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        let inInput = mainWindow?.firstResponder is NSText
        let isEsc = code == 53, isReturn = code == 36 || code == 76
        let isUp = code == 126, isDown = code == 125, isLeft = code == 123, isRight = code == 124

        if !hasPortfolio {
            guard !cmd, !inInput else { return false }
            switch k {
            case "1": createEmpty(); return true
            case "2": loadDemo(); return true
            case "3": importBackup(); return true
            default: return false
            }
        }
        if cmd && shift && k == "s" { quickShare = true; palette = nil; tx = nil; return true }
        let shareCtx = palette == nil && tx == nil && (quickShare || screen == .share)
        if cmd && !shift && k == "c" && shareCtx && !inInput { copyImage(); return true }
        if cmd && !shift && k == "s" && shareCtx { saveImage(); return true }
        if quickShare && isReturn { go(.share); return true }
        if cmd && k == "k" { if palette != nil { palette = nil } else { openPalette() }; return true }
        if cmd && !shift && k == "p" { openSwitcher(); return true }
        if cmd && k == "n" { openTx(); return true }
        if cmd && k == "r" { Task { await refresh(auto: false) }; return true }
        if cmd, let n = Int(k), (1...4).contains(n) { go([.overview, .movers, .analytics, .settings][n - 1]); return true }
        if cmd && k == "," { go(.settings); return true }
        if isEsc { back(); return true }
        if syncSheet != nil { return true }   // confirmations are mouse-only: nothing toggles sync by accident

        if let sw = switcher {
            let rows = switcherRows(sw.query)
            if isDown { switcher!.sel = min(rows.count - 1, sw.sel + 1); return true }
            if isUp { switcher!.sel = max(0, sw.sel - 1); return true }
            if isReturn { if let r = rows[safe: min(sw.sel, rows.count - 1)] { runSwitcherRow(r) }; return true }
            if !inInput, !cmd, let ch = e.characters, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                switcher!.query += ch; switcher!.sel = 0; return true
            }
            return false
        }
        if newPortfolio != nil {
            if isReturn { createPortfolio(); return true }
            return false
        }
        if manage.renaming != nil {
            if isReturn { commitRename(); return true }
            return false
        }

        if palette != nil {
            let n = paletteItems(palette!.query).count
            if isDown { palette!.sel = min(max(0, n - 1), palette!.sel + 1); return true }
            if isUp { palette!.sel = max(0, palette!.sel - 1); return true }
            if isReturn { runPaletteSelection(); return true }
            // Typed before the field took focus: keep the keystroke instead of dropping it.
            if !inInput, !cmd, let ch = e.characters, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                palette!.query += ch; palette!.sel = 0
                return true
            }
            if !inInput, code == 51, !palette!.query.isEmpty { palette!.query.removeLast(); return true }
            return false
        }
        if let sp = sourcePicker {
            let n = sp.candidates.count
            if isDown, n > 0 { sourcePicker!.sel = min(n - 1, sp.sel + 1); return true }
            if isUp { sourcePicker!.sel = max(0, sp.sel - 1); return true }
            if isReturn, let c = sp.candidates[safe: sp.sel] { applySource(c); return true }
            return true
        }
        if let d = tx {
            // ↑↓ choose between search matches (listed coin vs DEX lookalikes).
            if (isUp || isDown), d.searchResults.count > 1, AssetCatalog.resolve(d.asset, in: doc.assets + AssetCatalog.known) == nil {
                let n = d.searchResults.count
                tx!.pick = ((d.pick + (isDown ? 1 : -1)) % n + n) % n
                return true
            }
            if isReturn && !cmd { confirmTx(); return true }
            return false
        }
        if screen == .target && (isUp || isDown) { stepTarget(up: isUp); return true }
        if cmd || inInput || quickShare { return false }

        if k == "/" { openPalette("open "); return true }
        if k == "[" || k == "]" { cyclePortfolio(k == "]" ? 1 : -1); return true }
        if let n = Int(k), (1...4).contains(n) { go([.overview, .movers, .analytics, .settings][n - 1]); return true }
        if k == "," { go(.settings); return true }

        let n = summary.positions.count
        switch screen {
        case .overview where isAll:
            // ALL: the selection walks the portfolios table; ↵ drills into one.
            let live = doc.livePortfolios, m = live.count
            if isDown, m > 0 { sel = (sel + 1) % m; return true }
            if isUp, m > 0 { sel = (sel - 1 + m) % m; return true }
            if isReturn, let p = live[safe: sel] { setContext(.portfolio(p.id)); return true }
            if isLeft || isRight { setOverviewRange(Self.overviewRanges.cycled(from: overviewRange, by: isRight ? 1 : -1)); return true }
            if k == "v" { overviewMode = overviewMode == .value ? .pnl : .value; return true }
        case .portfolios:
            let list = manageList, m = list.count
            guard m > 0 else { break }
            let id = list[min(manage.sel, m - 1)].id
            if isDown { manage.sel = (manage.sel + 1) % m; manage.confirmDelete = nil; return true }
            if isUp { manage.sel = (manage.sel - 1 + m) % m; manage.confirmDelete = nil; return true }
            if isReturn, doc.portfolio(id)?.isArchived == false { setContext(.portfolio(id)); go(.overview); return true }
            if k == "r" { startRename(id); return true }
            if k == "a" { toggleArchive(id); return true }
            if code == 51 || code == 117 { requestDeletePortfolio(id); return true }
            if k == "n" { openNewPortfolio(); return true }
        case .overview:
            if isDown, n > 0 { sel = (sel + 1) % n; return true }
            if isUp, n > 0 { sel = (sel - 1 + n) % n; return true }
            if isReturn, n > 0 { openAsset(summary.positions[sel].asset.id); return true }
            if isLeft || isRight { setOverviewRange(Self.overviewRanges.cycled(from: overviewRange, by: isRight ? 1 : -1)); return true }
            if k == "v" { overviewMode = overviewMode == .value ? .pnl : .value; return true }
        case .movers:
            if isDown, n > 0 { msel = (msel + 1) % n; return true }
            if isUp, n > 0 { msel = (msel - 1 + n) % n; return true }
            if isReturn, let id = moversOrder[safe: msel] { openAsset(id); return true }
            if k == "p" { moversMode = moversMode == .abs ? .pct : .abs; return true }
            if isLeft || isRight { moversRange = Self.moverRanges.cycled(from: moversRange, by: isRight ? 1 : -1); loadMoversHistory(); return true }
        case .share:
            if isLeft || isRight { share.period = ShareConfig.periods.cycled(from: share.period, by: isRight ? 1 : -1); return true }
            if k == "f" { share.format = ShareFormat.mac.cycled(from: share.format); return true }
            if k == "p" { setPrivacy(SharePrivacy.allCases.cycled(from: share.privacy)); return true }
        case .asset:
            let txs = currentAssetTransactions
            if k == "t", let a = assetID { openTarget(a); return true }
            if isLeft || isRight { setAssetRange(Self.assetRanges.cycled(from: assetRange, by: isRight ? 1 : -1)); return true }
            if isDown, !txs.isEmpty { txSel = (txSel + 1) % txs.count; return true }
            if isUp, !txs.isEmpty { txSel = (txSel - 1 + txs.count) % txs.count; return true }
            if (k == "e" || isReturn), let t = txs[safe: txSel] { editTx(t); return true }
            if code == 51 || code == 117, let t = txs[safe: txSel] { requestDelete(t); return true }
        default: break
        }
        return false
    }

    static let latinKey: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m", 33: "[", 30: "]",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 43: ",", 44: "/",
    ]

    static let overviewRanges: [ChartRange] = [.d1, .w1, .m1, .m3, .y1, .all]
    static let assetRanges: [ChartRange] = [.h1, .h24, .d7, .d30, .y1, .all]
    static let moverRanges: [ChartRange] = [.h24, .d7, .d30, .all]

    func setOverviewRange(_ r: ChartRange) { overviewRange = r; loadHistory(assetsHeld(during: r), r) }
    func setAssetRange(_ r: ChartRange) { assetRange = r; if let a = assetID { loadHistory([a], r) } }
    func loadMoversHistory() { if moversRange.changePeriod == nil || moversRange == .all { return }; loadHistory(summary.positions.map(\.asset.id), moversRange) }

    var currentAssetTransactions: [Transaction] {
        guard let id = currentAsset?.asset.id else { return [] }
        return PortfolioEngine.ordered(contextTransactions.filter { $0.assetID == id })
    }

    var movers: [Mover] {
        let s = Dictionary(summary.positions.compactMap { v in assetSeries(v.asset.id, moversRange).map { (v.asset.id, $0) } }, uniquingKeysWith: { a, _ in a })
        var m = MoversEngine.movers(summary: summary, transactions: contextTransactions, quotes: quotes, series: s, range: moversRange, now: now)
        let key: (Mover) -> Double = moversMode == .abs ? { $0.impact?.double ?? 0 } : { $0.changePct ?? 0 }
        m.sort { moversDesc ? key($0) > key($1) : key($0) < key($1) }
        return m
    }
    var moversOrder: [AssetID] { movers.map(\.valuation.asset.id) }

    // MARK: target

    var targetValuation: PositionValuation? { targetAssetID.flatMap { summary.valuation($0) } ?? summary.positions.first }

    func stepTarget(up: Bool) {
        guard let v = targetValuation, let px = v.price else { return }
        let ps = ScenarioEngine.presets(for: px)
        let tv = NumberInput.target(targetInput, current: px)
        var i = ps.firstIndex { tv != nil && $0 >= tv! * Decimal.of(0.999999) } ?? ps.count
        let exact = tv != nil && i < ps.count && abs((ps[i] - tv!).double) < 1e-12 * max(1, tv!.double)
        if up { i = exact ? min(ps.count - 1, i + 1) : min(ps.count - 1, i) } else { i = max(0, i - 1) }
        if ps.indices.contains(i) { targetInput = "\(ps[i])" }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Share

extension AppStore {
    func setPrivacy(_ p: SharePrivacy) {
        if p == .custom { share.custom = share.fields }
        share.privacy = p
    }

    func toggleField(_ f: ShareField) {
        var c = share.fields
        if c.contains(f) { c.remove(f) } else { c.insert(f) }
        share.custom = c
        share.privacy = .custom
    }

    func shareRange(_ p: ChartRange) -> ChartRange { p == .h24 ? .h24 : p }

    /// Share source: an explicit live portfolio or ALL, else the active context.
    func shareContext(_ c: ShareConfig) -> PortfolioContext {
        guard let src = c.source, let ctx = PortfolioContext(storageKey: src) else { return context }
        if case let .portfolio(id) = ctx, doc.portfolio(id)?.isArchived != false { return context }
        return ctx
    }

    func shareModel(_ c: ShareConfig) -> ShareCardModel {
        let r = c.period, ctx = shareContext(c)
        let sum = ctx == context ? summary : summary(for: ctx)
        let txs = doc.transactions(ctx)
        let s = Dictionary(sum.positions.compactMap { v in assetSeries(v.asset.id, r).map { (v.asset.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let perf = MoversEngine.performance(summary: sum, transactions: txs, quotes: quotes, series: s, range: r, now: now)
        let mv = MoversEngine.movers(summary: sum, transactions: txs, quotes: quotes, series: s, range: r, now: now)
        return ShareCardBuilder.build(config: c, summary: sum, performance: perf, history: portfolioHistory(r, points: 121, in: ctx).twr,
                                      movers: mv, now: now, fmt: Fmt.current, contextName: doc.displayName(ctx))
    }

    func prepareShare() { let c = shareContext(share); loadHistory(assetsHeld(during: share.period, in: c), share.period) }

    func copyImage() {
        guard let img = ShareRenderer.image(shareModel(share)) else { return }
        ShareRenderer.copy(img)
        let s = share.format.size
        showFlash("✓ image copied", "✓ image copied · \(s.w)×\(s.h) png → clipboard")
        if quickShare { Task { try? await Task.sleep(nanoseconds: 700_000_000); quickShare = false } }
    }

    func saveImage() {
        let model = shareModel(share)
        let name = "pf-\(share.period.rawValue.lowercased())-\(DateFmt.ymd(Date())).png"
        ShareRenderer.save(model, suggestedName: name) { [weak self] url in
            guard let url else { return }
            self?.showFlash("✓ portfolio card exported", "✓ portfolio card exported · " + url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
    }

    func shareVia(anchor: NSView?) {
        guard let anchor else { return }
        ShareRenderer.presentPicker(shareModel(share), from: anchor) { [weak self] service in
            self?.showFlash("✓ shared via \(service)", "✓ portfolio card shared via \(service) · macOS share sheet")
        }
    }
}

// MARK: - Import / export

extension AppStore {
    func exportBackup() {
        var d = doc
        d.exportedAt = Date()
        d.settings = settings
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pf-\(DateFmt.ymd(Date())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try d.encoded().write(to: url, options: .atomic)
            message = "✓ exported \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · \(d.transactions.count) transactions"
        } catch { message = "✗ export failed · \(error.localizedDescription)" }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if legacyDataUnreadable { panel.directoryURL = LegacyIdentifiers.dataDirectory }   // the open panel may read it
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImport = try PortfolioDocument.load(Data(contentsOf: url))
        } catch {
            message = "✗ import rejected · \(error) · current portfolio unchanged"
        }
    }

    /// Called only after the user confirms replacing the current portfolio.
    func applyImport() {
        guard let d = pendingImport else { return }
        pendingImport = nil
        doc = d
        doc.exportedAt = nil
        if var s = d.settings { s.onboarded = true; s.primaryProvider = mockMarket ? "Mock" : (s.primaryProvider == "Mock" ? "CoinGecko" : s.primaryProvider); settings = s }
        doc.settings = nil
        context = doc.validContext(context)
        persistContext()
        save()
        cache.invalidateSnapshots(from: .distantPast)
        series = [:]
        quotes = cache.quotes(currency: settings.currency).filter { k, _ in doc.assets.contains { $0.id == k } }
        recompute()
        go(.overview)
        message = "✓ imported \(d.transactions.count) transactions · \(d.assets.count) assets"
        Task { await refresh(auto: false) }
    }
}

// MARK: - Menu bar

extension AppStore {
    /// Menu bar follows the active context unless pinned to ALL in Settings.
    var menuBarContext: PortfolioContext { settings.menuBarContext == "all" ? .all : context }

    func trayText(_ f: MenuBarFormat? = nil) -> String {
        let fm = Fmt.current, s = menuBarContext == context ? summary : summary(for: menuBarContext)
        guard hasPortfolio, !s.isEmpty else { return "PF  —" }
        let up = (s.change24h ?? 0) >= 0
        switch f ?? settings.menuBar {
        case .valueDelta: return "Σ \(fm.money(s.totalValue, 0))  Δ \(fm.signed(s.change24h, 0))"
        case .compact: return "◈ \(fm.compact(s.totalValue)) \(fm.pct(s.change24hPct))"
        case .hidden: return "PF"
        case .valuePct:
            return "PF  \(fm.compact(s.totalValue).uppercased())  \(up ? "▲" : "▼")\(s.change24hPct.map { fm.num(abs($0), 2) } ?? "—")%"
        }
    }
}
