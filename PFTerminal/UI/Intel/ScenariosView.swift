import PFCore
import PFCoreUI
import SwiftUI

/// Scenarios (design §09): switcher columns that double as the summary, the selected
/// scenario's targets per asset (edited in place) and a compare table across c · b · u.
struct ScenariosView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var editFocused: Bool
    @FocusState private var renameFocused: Bool

    static let cols: [Columns.Col] = [.fixed(22), .fixed(70), .fixed(110), .fixed(110), .fixed(170), .fixed(80), .fixed(100), .fixed(106), .fixed(100), .fixed(60), .fr(1)]

    var body: some View {
        let list = store.orderedScenarios
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "SCENARIOS", sub: "your targets, not forecasts · " + (store.syncEnabled ? "synced via iCloud" : "saved on this Mac")) {
                    IntelSyncBadge()
                if !list.isEmpty {
                    BracketButton("+ new n", color: Theme.acc) { store.newScenario() }
                    BracketButton("duplicate ⌘D") { store.duplicateScenario() }
                    BracketButton("rename r") { store.scenarioRename = store.currentScenario?.name }
                    BracketButton(store.scenarioConfirmDelete != nil ? "⌫ again" : "delete ⌫", color: store.scenarioConfirmDelete != nil ? Theme.neg : Theme.t2) { store.requestDeleteScenario() }
                }
            }
            if list.isEmpty || store.scenarioHoldings.isEmpty {
                empty(noHoldings: store.scenarioHoldings.isEmpty)
            } else if let cur = store.currentScenario {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        switcher(list, cur)
                        targets(cur)
                        compare(list.filter { $0.key != nil }, cur)
                    }
                    .padding(.top, 8)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, 2)
    }

    // MARK: switcher

    private func switcher(_ list: [PortfolioScenario], _ cur: PortfolioScenario) -> some View {
        let f = Fmt.current, s = store.summary
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                CapsLabel("NOW")
                TT(f.money(s.totalValue, 0), 18, Theme.t1, weight: .medium)
                TT("\(s.positions.count) positions", 11, Theme.t4)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(width: 200, alignment: .leading)
            ForEach(list.prefix(5)) { sc in
                let p = store.projection(sc), on = sc.id == cur.id
                TermButton(action: { store.selectScenario(sc.id) }, hoverBg: Theme.hover) {
                    VStack(alignment: .leading, spacing: 5) {
                        if on, let name = store.scenarioRename {
                            TextField("NAME", text: Binding(get: { name }, set: { store.scenarioRename = $0.uppercased() }))
                                .textFieldStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.t1).tint(Theme.acc)
                                .focused($renameFocused).onAppear { renameFocused = true }
                                .onSubmit { store.commitScenarioRename() }
                        } else {
                            TT((sc.key.map { $0 + " · " } ?? "") + sc.name, 11, on ? Theme.acc : Theme.t3, tracking: 0.6).lineLimit(1)
                        }
                        TT(f.money(p.projected, 0), 18, on ? Theme.t1 : Theme.t2, weight: .medium)
                        HStack(spacing: 8) {
                            TT(f.signed(p.upside, 0), 11, Theme.signColor(p.upside))
                            TT(p.multiple.map { f.num($0, 1) + "×" } ?? "—", 11, Theme.t3)
                            TT("ed " + String(DateFmt.ymd(sc.editedAt).dropFirst(5)), 11, Theme.t4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? Theme.selected : .clear)
                    .overlay(alignment: .top) { if on { Rectangle().fill(Theme.acc).frame(height: 2) } }
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.innerBorder).frame(width: 1) }
                }
                .accessibilityIdentifier("scenario-col-" + (sc.key ?? sc.name))
            }
        }
        .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
    }

    // MARK: targets

    private func targets(_ cur: PortfolioScenario) -> some View {
        let f = Fmt.current, p = store.projection(cur)
        let gain = p.rows.filter { !$0.isStable }.reduce(Decimal(0)) { $0 + $1.upside }
        return Panel(title: cur.name + " · TARGETS PER ASSET · ↵ EDIT TARGET · 30% SETS A WEIGHT", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.cols) {
                    Color.clear; HeadCell("ASSET", align: .leading); HeadCell("AMOUNT"); HeadCell("PRICE"); HeadCell("TARGET"); HeadCell("Δ PRICE")
                    HeadCell("VALUE NOW"); HeadCell("PROJECTED"); HeadCell("UPSIDE"); HeadCell("SHARE"); HeadCell("CONTRIBUTION TO UPSIDE", align: .leading).padding(.leading, 14)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14).overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(p.rows.enumerated()), id: \.element.asset) { i, r in
                    let sel = i == store.scenarioRow, editing = sel && store.scenarioEdit != nil
                    TableRow(selected: sel, height: store.settings.rowHeight, onSelect: { store.scenarioRow = i; store.scenarioEdit = nil },
                             onOpen: { store.scenarioRow = i; store.beginScenarioEdit() }) {
                        Columns(Self.cols) {
                            RowMark(on: sel)
                            TT(store.asset(r.asset)?.symbol ?? r.asset, 12, Theme.t1, weight: .medium)
                            Cell(f.amount(r.quantity), Theme.t2)
                            Cell(f.price(r.price), Theme.text)
                            if editing {
                                HStack(spacing: 4) {
                                    TT(">", 12, Theme.acc)
                                    TextField("3x · 0.02 · 30%", text: Binding(get: { store.scenarioEdit ?? "" }, set: { store.scenarioEdit = $0 }))
                                        .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.t1).tint(Theme.acc)
                                        .multilineTextAlignment(.trailing)
                                        .focused($editFocused).onAppear { editFocused = true }
                                        .onSubmit { store.commitScenarioEdit() }
                                        .accessibilityIdentifier("scenario-target-input")
                                }
                            } else {
                                let w = cur.targets[r.asset]?.weight
                                Cell((r.isStable ? f.price(r.target) + " peg" : r.hasTarget ? f.price(r.target) : "—") + (w.map { " · " + f.num($0, 0) + "%" } ?? ""),
                                     r.isStable ? Theme.t4 : r.hasTarget ? Theme.t1 : Theme.t4)
                            }
                            Cell(f.pct(r.deltaPct, 0), Theme.signColor(r.deltaPct))
                            Cell(f.money(r.valueNow, 0), Theme.t2)
                            Cell(f.money(r.projected, 0), Theme.t1)
                            Cell(r.isStable ? "—" : f.signed(r.upside, 0), Theme.signColor(r.upside))
                            Cell(r.share.map { f.num($0 * 100, 0) + "%" } ?? "—", Theme.t2)
                            let w = gain > 0 && !r.isStable ? max(0, (r.upside / gain).double) : 0
                            GeometryReader { g in
                                Text(AsciiChart.bar(w, width: max(6, Int(g.size.width / Theme.cell(12)))))
                                    .font(Theme.mono(12)).foregroundStyle(Theme.bar).lineLimit(1).fixedSize()
                            }
                            .frame(height: 14).clipped().padding(.leading, 14)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                    }
                }
                Columns(Self.cols) {
                    TT("Σ", 12, Theme.t4); TT("total", 12, Theme.t2); Color.clear; Color.clear; Color.clear
                    Cell(f.pct(p.upsidePct, 0), Theme.signColor(p.upsidePct))
                    Cell(f.money(p.valueNow, 0), Theme.t2); Cell(f.money(p.projected, 0), Theme.t1); Cell(f.signed(p.upside, 0), Theme.signColor(p.upside))
                    Cell("100%", Theme.t3)
                    TT(p.topShare.map { "top asset = \(f.num($0 * 100, 0))% of the upside" } ?? "", 11, Theme.t4).padding(.leading, 14)
                }
                .frame(height: 28).padding(.leading, 4).padding(.trailing, 14)
            }
        }
        .accessibilityIdentifier("scenario-targets")
    }

    // MARK: compare

    private func compare(_ presets: [PortfolioScenario], _ cur: PortfolioScenario) -> some View {
        let f = Fmt.current
        let ids = store.scenarioHoldings.filter { !Stablecoins.isStablecoin($0.asset) }
        let cols: [Columns.Col] = [.fixed(22), .fixed(90)] + presets.map { _ in Columns.Col.fixed(130) } + [.fr(1)]
        return Panel(title: "COMPARE · TARGET PRICE BY SCENARIO", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(cols) {
                    Color.clear; HeadCell("ASSET", align: .leading)
                    ForEach(presets) { HeadCell($0.name) }
                    HeadCell(presets.count > 1 ? "SPREAD · \(presets.first!.name.prefix(4)) → \(presets.last!.name.prefix(4))" : "", align: .leading).padding(.leading, 18)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14).overlay(alignment: .bottom) { Hairline() }
                ForEach(ids, id: \.asset) { h in
                    let t = presets.map { $0.targets[h.asset]?.price }
                    Columns(cols) {
                        Color.clear
                        TT(store.asset(h.asset)?.symbol ?? h.asset, 12, Theme.t1, weight: .medium)
                        ForEach(Array(presets.enumerated()), id: \.offset) { i, s in Cell(t[i].map { f.price($0) } ?? "—", s.id == cur.id ? Theme.t1 : Theme.t3) }
                        let lo = t.first ?? nil, hi = t.last ?? nil
                        TT(lo.flatMap { l in hi.map { h2 in
                            f.num((h2 / l).double, 1) + "× · " + f.pct(((l / h.price) - 1).double * 100, 0) + " → " + f.pct(((h2 / h.price) - 1).double * 100, 0)
                        } } ?? "—", 12, Theme.t3).padding(.leading, 18)
                    }
                    .frame(height: store.settings.rowHeight).padding(.leading, 4).padding(.trailing, 14)
                }
            }
        }
    }

    private func empty(noHoldings: Bool) -> some View {
        Panel(title: noHoldings ? "NOTHING TO PROJECT" : "NO SCENARIOS YET") {
            VStack(alignment: .leading, spacing: 12) {
                Text(noHoldings
                     ? "Scenarios project what you hold to your target prices. This portfolio has no priced positions yet."
                     : "A scenario is a set of target prices, one per asset: what your portfolio would be worth if they were reached. Start from conservative · base · bull at today's prices, then edit the targets.")
                    .font(Theme.mono(12)).foregroundStyle(Theme.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if !noHoldings {
                    HStack(spacing: 6) {
                        BracketButton("create c · b · u", color: Theme.acc) { store.createPresetScenarios() }
                        BracketButton("+ empty scenario n") { store.newScenario() }
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .accessibilityIdentifier("scenarios-empty")
    }
}
