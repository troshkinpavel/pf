import PFCore
import PFCoreUI
import SwiftUI

// MARK: - Switcher (⌘P)

struct PortfolioSwitcherView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        let q = store.switcher?.query ?? ""
        let rows = store.switcherRows(q)
        let sel = min(store.switcher?.sel ?? 0, max(0, rows.count - 1))
        let f = Fmt.current
        let contexts = rows.enumerated().filter { if case .context = $0.element.kind { return true }; return false }
        let actions = rows.enumerated().filter { if case .context = $0.element.kind { return false }; return true }
        let archived = store.doc.portfolios.filter(\.isArchived).count

        VStack(spacing: 0) {
            HStack {
                TT("SWITCH PORTFOLIO", 10.5, Theme.t2, tracking: 0.84)
                Spacer()
                TT("⌘P · [ ] cycle without opening", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 30)
            .overlay(alignment: .bottom) { Hairline(color: Theme.innerBorder) }
            HStack(spacing: 12) {
                TT(">", 15, Theme.acc)
                TextField("filter", text: Binding(get: { store.switcher?.query ?? "" }, set: { store.switcher = SwitcherState(query: $0, sel: 0) }))
                    .textFieldStyle(.plain).font(Theme.mono(15)).foregroundStyle(Theme.t1).tint(Theme.acc)
                    .focused($focused)
                    .accessibilityIdentifier("switcher-input")
            }
            .padding(.horizontal, 16).frame(height: 44)
            .overlay(alignment: .bottom) { Hairline() }

            VStack(spacing: 0) {
                ForEach(contexts, id: \.element.id) { i, r in
                    let isCurrent = { if case let .context(c) = r.kind { return c == store.context }; return false }()
                    let s = r.summary
                    Button { store.runSwitcherRow(r) } label: {
                        Columns([.fixed(18), .fixed(16), .fixed(24), .fr(1), .fixed(110), .fixed(76), .fixed(56)]) {
                            TT(i == sel ? "›" : "", 12, Theme.acc).frame(maxWidth: .infinity)
                            TT(isCurrent ? "●" : "", 12, Theme.pos)
                            TT(r.glyph, 12, Theme.t2)
                            TT(r.name, 12, isCurrent ? Theme.t1 : Theme.muted)
                            Cell(s.map { $0.isEmpty ? "empty" : f.money($0.totalValue, 0) } ?? "", Theme.text)
                            Cell(s.flatMap { $0.isEmpty ? nil : f.pct($0.change24hPct) } ?? "", Theme.signColor(s?.change24h))
                            Cell(r.count, Theme.t4, size: 11)
                        }
                        .padding(.leading, 6).padding(.trailing, 16).frame(height: 30)
                        .background(i == sel ? Theme.paletteSel : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0, store.switcher?.sel != i { store.switcher?.sel = i } }
                    .accessibilityIdentifier("switcher-row-\(r.name)")
                }
            }
            .padding(.vertical, 6)

            VStack(spacing: 0) {
                ForEach(actions, id: \.element.id) { i, r in
                    Button { store.runSwitcherRow(r) } label: {
                        Columns([.fixed(18), .fr(1), .fixed(180)]) {
                            TT(i == sel ? "›" : "", 12, Theme.acc).frame(maxWidth: .infinity)
                            TT(r.name, 12, r.id == "new" ? Theme.acc : Theme.t2)
                            Cell(r.count, Theme.t4, size: 11)
                        }
                        .padding(.leading, 6).padding(.trailing, 16).frame(height: 28)
                        .background(i == sel ? Theme.paletteSel : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0, store.switcher?.sel != i { store.switcher?.sel = i } }
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Hairline() }

            HStack {
                TT("↑↓ select · ↵ switch · type to filter · esc", 11, Theme.t4)
                Spacer()
                TT(archived > 0 ? "\(archived) archived · not shown" : "", 11, Theme.t4)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .accessibilityIdentifier("portfolio-switcher")
    }
}

// MARK: - New portfolio

struct NewPortfolioView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        let d = store.newPortfolio ?? NewPortfolioDraft()
        let name = PortfolioDocument.normalizedName(d.name)
        let err = store.doc.nameError(d.name)
        let ok = err == nil

        VStack(spacing: 0) {
            HStack {
                TT("NEW PORTFOLIO", 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT("↵ create · esc cancel", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }

            VStack(alignment: .leading, spacing: 14) {
                row("name") {
                    HStack(spacing: 10) {
                        TT(">", 12, Theme.acc)
                        TextField("SWING", text: Binding(get: { store.newPortfolio?.name ?? "" }, set: { store.newPortfolio?.name = $0.uppercased() }))
                            .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
                            .focused($focused)
                            .accessibilityIdentifier("new-portfolio-name")
                    }
                }
                row("glyph") {
                    HStack(spacing: 2) {
                        ForEach(PortfolioGlyphs.all, id: \.self) { g in
                            let on = d.glyph == g
                            TermButton(action: { store.newPortfolio?.glyph = g }) {
                                TT(g, 12, on ? Theme.t1 : Theme.t3)
                                    .frame(width: 26, height: 24)
                                    .background(on ? Theme.tabBg : .clear)
                                    .overlay(Rectangle().strokeBorder(on ? Theme.overlayBorder : .clear, lineWidth: 1))
                            }
                        }
                    }
                }
                row("start") {
                    Tabs(items: [TabItem(id: "empty", label: "empty"), TabItem(id: "import", label: "import .json")], selected: d.start.rawValue, hPad: 10, vPad: 3) {
                        store.newPortfolio?.start = NewPortfolioDraft.Start(rawValue: $0)!
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 5) {
                TT(name.isEmpty ? "name required" : "create \(d.glyph) \(name) · " + (d.start == .import ? "then import" : "empty"), 12, Theme.t1)
                if case let .duplicateName(n)? = err { TT("! \(n) already exists", 12, Theme.neg) }
                TT("becomes the active portfolio · everything else stays as is", 11, Theme.t4)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(Theme.overlayBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .padding(.horizontal, 16)

            HStack {
                BracketButton("cancel", color: Theme.t2) { store.newPortfolio = nil }
                Spacer()
                BracketButton("create portfolio ↵", color: ok ? Theme.acc : Theme.faint) { store.createPortfolio() }
                    .disabled(!ok)
                    .accessibilityIdentifier("new-portfolio-create")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(width: 520)
        .onAppear { focused = true }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 0) { TT(label, 12, Theme.t3).frame(width: 80, alignment: .leading); c() }
    }
}

// MARK: - Manage (/ portfolios)

struct PortfoliosView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var renameFocused: Bool

    static let cols: [Columns.Col] = [.fixed(22), .fixed(26), .fixed(220), .fixed(60), .fixed(60), .fixed(130), .fixed(90), .fixed(110), .fixed(100), .fr(1)]

    var body: some View {
        @Bindable var store = store
        let f = Fmt.current
        let list = store.manageList
        let armed = store.manage.confirmDelete.flatMap { store.doc.portfolio($0) }

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "PORTFOLIOS", sub: "local contexts · switch with ⌘P or [ ]") {
                    BracketButton("+ new portfolio n", color: Theme.acc) { store.openNewPortfolio() }
                        .accessibilityIdentifier("manage-new")
                }

                Panel(title: "", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
                    VStack(spacing: 0) {
                        Columns(Self.cols) {
                            Color.clear; Color.clear
                            HeadCell("NAME", align: .leading); HeadCell("POS"); HeadCell("TX"); HeadCell("VALUE"); HeadCell("24H")
                            HeadCell("CREATED", align: .leading).padding(.leading, 24)
                            HeadCell("STATUS", align: .leading); HeadCell("ACTIONS")
                        }
                        .frame(height: 26).padding(.leading, 4).padding(.trailing, 14)
                        .overlay(alignment: .bottom) { Hairline() }

                        ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                            let s = store.summary(for: .portfolio(p.id))
                            let on = i == store.manage.sel
                            TableRow(selected: on, height: store.settings.rowHeight, onSelect: { store.manage.sel = i },
                                     onOpen: { if !p.isArchived { store.setContext(.portfolio(p.id)); store.go(.overview) } },
                                     divider: i < list.count - 1) {
                                Columns(Self.cols) {
                                    RowMark(on: on)
                                    TT(p.glyph, 12, Theme.t2)
                                    if store.manage.renaming == p.id {
                                        HStack(spacing: 8) {
                                            TT(">", 12, Theme.acc)
                                            TextField("", text: $store.manage.renameText)
                                                .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.t1).tint(Theme.acc)
                                                .focused($renameFocused)
                                                .frame(width: 170)
                                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.kbdBottom).frame(height: 1).offset(y: 2) }
                                                .onAppear { renameFocused = true }
                                                .accessibilityIdentifier("rename-input")
                                        }
                                    } else {
                                        TT(p.name, 12, p.isArchived ? Theme.t3 : Theme.t1, weight: .medium)
                                    }
                                    Cell("\(s.positions.count)", Theme.t2)
                                    Cell("\(store.transactionCount(p.id))", Theme.t2)
                                    Cell(s.isEmpty ? "—" : f.money(s.totalValue, 0), Theme.t1)
                                    Cell(s.isEmpty ? "—" : f.pct(s.change24hPct), Theme.signColor(s.change24h))
                                    TT(DateFmt.ymd(p.createdAt), 12, Theme.t3).padding(.leading, 24)
                                    TT(p.isArchived ? "archived" : store.context == .portfolio(p.id) ? "● active" : "", 12, p.isArchived ? Theme.t3 : Theme.acc)
                                    HStack(spacing: 12) {
                                        action("rename r", Theme.t3) { store.startRename(p.id) }
                                        action((p.isArchived ? "restore" : "archive") + " a", Theme.t3) { store.toggleArchive(p.id) }
                                        action(store.manage.confirmDelete == p.id ? "confirm delete ⌫" : "delete ⌫",
                                               store.manage.confirmDelete == p.id ? Theme.neg : Theme.t3) { store.requestDeletePortfolio(p.id) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .padding(.leading, 4).padding(.trailing, 14)
                            }
                        }
                    }
                }

                TT(armed.map { "press ⌫ again to delete \($0.name) and its \(store.transactionCount($0.id)) transactions · esc cancel" } ?? " ", 12, Theme.neg)
                    .frame(minHeight: 16)
                Text("archive hides a portfolio from the switcher, ALL, the menu bar and widgets; its data stays on disk. delete removes it and its transactions from this Mac.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.t4).lineSpacing(4).frame(maxWidth: 760, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private func action(_ label: String, _ c: Color, _ a: @escaping () -> Void) -> some View {
        TermButton(action: a) { TT(label, 11, c).fixedSize() }
    }
}

// MARK: - Empty portfolio

struct EmptyPortfolioView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: store.contextGlyph + " " + store.contextName) {
                TT("0 positions · \(store.contextTransactions.count) transactions · [ ] to switch", 12, Theme.t3)
            }

            Panel(title: "EMPTY PORTFOLIO", padding: .init(top: 24, leading: 22, bottom: 20, trailing: 22)) {
                VStack(alignment: .leading, spacing: 14) {
                    TT("No transactions yet. Add one, type it as a command, or import an export file.", 12, Theme.t2)
                    HStack(spacing: 6) {
                        BracketButton("add transaction ⌘N", color: Theme.acc) { store.openTx() }
                        if let id = store.defaultTransactionPortfolio {
                            BracketButton("import .json") { store.importIntoPortfolio(id) }
                        }
                        if store.doc.transactions.isEmpty && store.doc.portfolios.count == 1 {
                            BracketButton("load demo portfolio", color: Theme.t2) { store.loadDemo() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TT("⌘K  buy btc 0.05 @ 91000", 12, Theme.t4)
                        TT("⌘K  buy eth 0.5 @ 3500", 12, Theme.t4)
                    }
                    .padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - ALL: portfolios drill-in table

struct AllPortfoliosPanel: View {
    @Environment(AppStore.self) private var store
    static let cols: [Columns.Col] = [.fixed(22), .fixed(26), .fixed(150), .fixed(70), .fixed(130), .fixed(90), .fixed(100), .fixed(110), .fixed(84), .fr(1)]

    var body: some View {
        let f = Fmt.current
        let live = store.doc.livePortfolios
        let total = store.summary.totalValue.double
        Panel(title: "PORTFOLIOS · \(live.count) · ↵ drill in", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.cols) {
                    Color.clear; Color.clear
                    HeadCell("NAME", align: .leading); HeadCell("POS"); HeadCell("VALUE"); HeadCell("24H"); HeadCell("24H $")
                    HeadCell("TOTAL PNL"); HeadCell("TOTAL RET"); HeadCell("WEIGHT", align: .leading).padding(.leading, 28)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14)
                .overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(live.enumerated()), id: \.element.id) { i, p in
                    let s = store.summary(for: .portfolio(p.id))
                    let w = total > 0 ? s.totalValue.double / total : 0
                    TableRow(selected: i == store.sel, height: store.settings.rowHeight, onSelect: { store.sel = i },
                             onOpen: { store.setContext(.portfolio(p.id)) }, divider: i < live.count - 1) {
                        Columns(Self.cols) {
                            RowMark(on: i == store.sel)
                            TT(p.glyph, 12, Theme.t2)
                            TT(p.name, 12, Theme.t1, weight: .medium)
                            Cell("\(s.positions.count)", Theme.t2)
                            Cell(f.money(s.totalValue), Theme.t1)
                            Cell(s.isEmpty ? "—" : f.pct(s.change24hPct), Theme.signColor(s.change24h))
                            Cell(s.isEmpty ? "—" : f.signed(s.change24h, 0), Theme.signColor(s.change24h))
                            Cell(s.isEmpty ? "—" : f.signed(s.totalPnL, 0), Theme.signColor(s.totalPnL))
                            Cell(s.isEmpty ? "—" : f.pct(s.totalReturnPct, 1), Theme.signColor(s.totalPnL))
                            AllocationCell(fraction: w, label: f.num(w * 100, 1) + "%").padding(.leading, 28)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                    }
                }
            }
        }
    }
}

// MARK: - Price source picker

struct SourcePickerView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let sp = store.sourcePicker ?? SourcePickerState(assetID: "")
        let a = store.asset(sp.assetID)
        let f = Fmt.current
        VStack(spacing: 0) {
            HStack {
                TT("PRICE SOURCE · \(a?.symbol ?? "")", 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT(a.flatMap { AssetRegistry.shared.entry(for: $0) } != nil ? "verified markets only · auto = live feeds first"
                   : "same ticker, different markets · pick the one you trade", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }

            Columns([.fixed(18), .fixed(96), .fr(1), .fixed(110), .fixed(76), .fixed(90), .fixed(58)]) {
                Color.clear; HeadCell("SOURCE", align: .leading); HeadCell("MARKET", align: .leading)
                HeadCell("PRICE"); HeadCell("24H"); HeadCell("24H VOL"); Color.clear
            }
            .padding(.leading, 6).padding(.trailing, 16).frame(height: 26)
            .overlay(alignment: .bottom) { Hairline(color: Theme.innerBorder) }

            VStack(spacing: 0) {
                if sp.loading {
                    TT("checking sources…", 11, Theme.t4).padding(14)
                } else if sp.candidates.isEmpty {
                    TT("no markets found for \(a?.symbol ?? "")", 11, Theme.t4).padding(14)
                }
                ForEach(Array(sp.candidates.enumerated()), id: \.element.id) { i, c in
                    let thin = (c.quote?.volume24h ?? 0) < lowLiquidityVolume
                    Button { store.applySource(c) } label: {
                        Columns([.fixed(18), .fixed(96), .fr(1), .fixed(110), .fixed(76), .fixed(90), .fixed(58)]) {
                            TT(i == sp.sel ? "›" : "", 12, Theme.acc).frame(maxWidth: .infinity)
                            TT(c.provider.lowercased(), 12, Theme.t1)
                            TT(c.label, 11, Theme.t3)
                            Cell(c.quote.map { f.price($0.price) } ?? "no quote", c.quote == nil ? Theme.t4 : Theme.t1)
                            Cell(f.pct(c.quote?.change24h), Theme.signColor(c.quote?.change24h))
                            Cell(f.compact(c.quote?.volume24h), thin && c.quote != nil ? Theme.neg : Theme.t2)
                            Cell(c.isCurrent ? "● set" : "", Theme.acc, size: 11)
                        }
                        .padding(.leading, 6).padding(.trailing, 16).frame(height: 28)
                        .background(i == sp.sel ? Theme.paletteSel : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { store.sourcePicker?.sel = i } }
                }
            }
            .padding(.vertical, 6)

            HStack {
                TT("↑↓ select · ↵ use this source · esc", 11, Theme.t4)
                Spacer()
                TT("red volume = thin market, price unreliable", 11, Theme.t4)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: 720)
    }
}
