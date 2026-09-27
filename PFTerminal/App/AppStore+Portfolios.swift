import AppKit
import Foundation

struct SwitcherState: Equatable {
    var query = ""
    var sel = 0
}

struct NewPortfolioDraft: Equatable {
    enum Start: String { case empty, `import` }
    var name = ""
    var glyph = PortfolioGlyphs.newDefault
    var start: Start = .empty
}

/// Portfolios screen: selection, inline rename, two-step delete.
struct ManageState: Equatable {
    var sel = 0
    var renaming: UUID?
    var renameText = ""
    var confirmDelete: UUID?
}

/// One row of the switcher: ALL, a portfolio, or an action.
struct SwitcherRow: Identifiable {
    enum Kind: Equatable { case context(PortfolioContext), newPortfolio(String), manage }
    let id: String
    let kind: Kind
    let glyph: String
    let name: String
    let summary: PortfolioSummary?
    let count: String
}

extension AppStore {
    static let contextKey = "pf.context.v1"

    func persistContext() { defaults.set(context.storageKey, forKey: Self.contextKey) }

    var contextName: String { doc.displayName(context) }
    var contextGlyph: String { doc.glyph(context) }
    var isAll: Bool { context == .all }

    /// Switch contexts: pure recomputation from cached quotes, no network, no reload.
    func setContext(_ c: PortfolioContext, announce: Bool = true) {
        let next = doc.validContext(c)
        switcher = nil; palette = nil
        let changed = next != context
        context = next
        persistContext()
        sel = 0; msel = 0; txSel = 0
        if screen == .portfolios || screen == .settings { screen = .overview }
        recompute()
        if changed { loadHistory(assetsHeld(during: overviewRange), overviewRange) }
        if announce { message = "→ \(contextName.lowercased()) · \(summary.positions.count) positions" }
    }

    /// `[` / `]`: previous / next live portfolio, then ALL.
    func cyclePortfolio(_ d: Int) {
        let ids: [PortfolioContext] = doc.livePortfolios.map { .portfolio($0.id) } + [.all]
        let i = ids.firstIndex(of: context) ?? 0
        setContext(ids[((i + d) % ids.count + ids.count) % ids.count])
    }

    // MARK: switcher

    func openSwitcher() {
        palette = nil; tx = nil; newPortfolio = nil; quickShare = false
        switcher = switcher == nil ? SwitcherState() : nil
    }

    func switcherRows(_ q: String) -> [SwitcherRow] {
        let q = q.trimmingCharacters(in: .whitespaces)
        var rows: [SwitcherRow] = []
        let live = doc.livePortfolios
        let allRow = SwitcherRow(id: "all", kind: .context(.all), glyph: PortfolioGlyphs.aggregate, name: "ALL PORTFOLIOS",
                                 summary: summary(for: .all), count: "\(live.count) pf")
        rows.append(allRow)
        for p in live {
            let s = summary(for: .portfolio(p.id))
            rows.append(SwitcherRow(id: p.id.uuidString, kind: .context(.portfolio(p.id)), glyph: p.glyph, name: p.name, summary: s, count: "\(s.positions.count) pos"))
        }
        if !q.isEmpty { rows = rows.filter { Fuzzy.score(q, $0.name) > 0 } }
        let newLabel = q.isEmpty || !rows.isEmpty ? "+ NEW PORTFOLIO" : "+ NEW PORTFOLIO \"\(PortfolioDocument.normalizedName(q))\""
        rows.append(SwitcherRow(id: "new", kind: .newPortfolio(rows.isEmpty ? q : ""), glyph: "", name: newLabel, summary: nil, count: "↵"))
        rows.append(SwitcherRow(id: "manage", kind: .manage, glyph: "", name: "  MANAGE PORTFOLIOS", summary: nil, count: "rename · archive · delete"))
        return rows
    }

    func runSwitcherRow(_ r: SwitcherRow) {
        switch r.kind {
        case let .context(c): setContext(c)
        case let .newPortfolio(name): openNewPortfolio(name)
        case .manage: switcher = nil; go(.portfolios)
        }
    }

    // MARK: create

    func openNewPortfolio(_ name: String = "") {
        switcher = nil; palette = nil; tx = nil; quickShare = false
        newPortfolio = NewPortfolioDraft(name: name.uppercased())
    }

    func createPortfolio() {
        guard let d = newPortfolio else { return }
        do {
            let p = try doc.createPortfolio(name: d.name, glyph: d.glyph)
            save()
            newPortfolio = nil
            setContext(.portfolio(p.id), announce: false)
            screen = .overview
            message = "✓ created \(p.name)" + (d.start == .import ? " · choose a pf .json to import into it" : " · empty · ⌘N to add a transaction")
            if d.start == .import { importIntoPortfolio(p.id) }
        } catch {
            message = "✗ \(error)"
        }
    }

    /// Adds another pf backup's transactions (and asset identities) to one portfolio.
    /// Every imported transaction is re-owned by `id`; nothing else changes.
    func importIntoPortfolio(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let src = try PortfolioDocument.load(Data(contentsOf: url))
            var next = doc
            for a in src.assets where !next.assets.contains(where: { $0.id == a.id }) { next.assets.append(a) }
            next.transactions += src.transactions.map { var t = $0; t.id = UUID(); t.portfolioID = id; return t }
            if let e = next.validationErrors().first { message = "✗ import rejected · \(e) · nothing changed"; return }
            doc = next
            save()
            cache.invalidateSnapshots(from: .distantPast)
            recompute()
            message = "✓ imported \(src.transactions.count) transactions into \(doc.portfolio(id)?.name ?? "")"
            Task { await refresh(auto: false) }
        } catch {
            message = "✗ import rejected · \(error) · nothing changed"
        }
    }

    // MARK: manage

    var manageList: [PortfolioInfo] { doc.livePortfolios + doc.portfolios.filter(\.isArchived) }

    func startRename(_ id: UUID) {
        manage.confirmDelete = nil
        manage.renaming = id
        manage.renameText = doc.portfolio(id)?.name ?? ""
    }

    func commitRename() {
        guard let id = manage.renaming else { return }
        do {
            try doc.renamePortfolio(id, to: manage.renameText)
            save()
            manage.renaming = nil
            message = "✓ renamed → \(doc.portfolio(id)?.name ?? "")"
            scheduleWidgetSnapshot()
        } catch { message = "✗ \(error)" }
    }

    func toggleArchive(_ id: UUID) {
        guard let p = doc.portfolio(id) else { return }
        manage.confirmDelete = nil
        do {
            try doc.setArchived(id, !p.isArchived)
            save()
            if !p.isArchived, context == .portfolio(id) { setContext(doc.validContext(nil), announce: false) } else { recompute() }
            message = p.isArchived ? "✓ restored \(p.name)" : "✓ archived \(p.name) · hidden from switcher, ALL and menu bar · data kept"
            writeWidgetSnapshot()
        } catch { message = "! \(error)" }
    }

    /// First press arms, second press deletes. Never a single keystroke.
    func requestDeletePortfolio(_ id: UUID) {
        guard let p = doc.portfolio(id) else { return }
        guard manage.confirmDelete == id else { manage.renaming = nil; manage.confirmDelete = id; return }
        manage.confirmDelete = nil
        do {
            try doc.deletePortfolio(id)
            save()
            cache.deleteSnapshots(context: id.uuidString)
            if context == .portfolio(id) { setContext(doc.validContext(nil), announce: false) } else { recompute() }
            manage.sel = min(manage.sel, max(0, manageList.count - 1))
            message = "✓ deleted \(p.name)"
            writeWidgetSnapshot()
        } catch { message = "! \(error)" }
    }

    func transactionCount(_ id: UUID) -> Int { doc.transactions.filter { $0.portfolioID == id }.count }

    /// Destination for new transactions: the active portfolio, or the first live one from ALL.
    var defaultTransactionPortfolio: UUID? { context.portfolioID ?? doc.livePortfolios.first?.id }
}
