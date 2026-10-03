import PFCore
import PFCoreUI
import SwiftUI

/// Watchlist (design §05): assets followed but not held, sorted by distance to entry.
struct WatchView: View {
    @Environment(AppStore.self) private var store

    static let cols: [Columns.Col] = [.fixed(22), .fixed(70), .fixed(110), .fixed(110), .fixed(76), .fixed(150), .fixed(100), .fixed(96), .fixed(100), .fixed(56), .fr(1)]

    var body: some View {
        let rows = store.watchRows
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                TT("WATCHLIST", 15, Theme.t1, weight: .semibold, tracking: 0.6)
                TT("\(rows.count) asset\(rows.count == 1 ? "" : "s") · not held · shared across portfolios · on this Mac", 12, Theme.t3)
                Spacer()
                BracketButton("+ watch asset  n", color: Theme.acc) { store.openWatchAdd() }
                    .accessibilityIdentifier("watch-add")
            }
            .padding(.bottom, 12).overlay(alignment: .bottom) { Hairline() }
            if rows.isEmpty {
                empty
            } else {
                table(rows)
                if let r = rows[safe: min(store.watchSel, rows.count - 1)] { selected(r) }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private func table(_ rows: [Watchlist.Row]) -> some View {
        let f = Fmt.current
        return Panel(title: "WATCHING · \(rows.count) · SORTED BY DISTANCE TO ENTRY", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.cols) {
                    Color.clear; HeadCell("ASSET", align: .leading); Color.clear
                    HeadCell("PRICE"); HeadCell("24H"); HeadCell("SINCE ADDED"); HeadCell("ENTRY"); HeadCell("TO ENTRY"); HeadCell("TARGET")
                    HeadCell("ALERT", align: .center); HeadCell("NOTE", align: .leading)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14).overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(rows.enumerated()), id: \.element.item.id) { i, r in
                    let w = r.item, sel = i == store.watchSel
                    TableRow(selected: sel, height: store.settings.rowHeight, onSelect: { store.watchSel = i },
                             onOpen: { store.openWatchEdit(w) }, divider: i < rows.count - 1) {
                        Columns(Self.cols) {
                            RowMark(on: sel)
                            TT(w.asset.symbol, 12, Theme.t1, weight: .medium)
                            TT(w.asset.name.lowercased(), 12, Theme.t4).lineLimit(1)
                            Cell(r.price.map { f.price($0) } ?? "—", Theme.text)
                            Cell(f.pct(r.change24h, 1), Theme.signColor(r.change24h))
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                TT(f.pct(r.sinceAdded, 1), 12, Theme.signColor(r.sinceAdded))
                                TT("  " + String(DateFmt.ymd(w.addedAt).dropFirst(5)), 11, Theme.t4)
                            }
                            Cell(w.entry.map { f.price($0) } ?? "—", w.entry == nil ? Theme.t4 : Theme.t2)
                            Cell(r.atEntry ? "at entry" : r.toEntry.map { f.num($0, 1) + "%" } ?? "—", r.atEntry ? Theme.acc : r.toEntry == nil ? Theme.t4 : Theme.t2)
                            Cell(w.target.map { f.price($0) } ?? "—", w.target == nil ? Theme.t4 : Theme.t2)
                            let g = store.alertGlyph(w.assetID)
                            Cell(g, g == "⚑" ? Theme.acc : g == "●" ? Theme.t2 : Theme.t4, align: .center)
                            TT(w.note ?? "—", 12, w.note == nil ? Theme.t4 : Theme.t3).lineLimit(1).padding(.leading, 14)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                    }
                    .accessibilityIdentifier("watch-row-" + w.asset.symbol)
                }
            }
        }
        .accessibilityIdentifier("watch-table")
    }

    private func selected(_ r: Watchlist.Row) -> some View {
        let f = Fmt.current, w = r.item
        let days = Int(Date().timeIntervalSince(w.addedAt) / 86400)
        return Columns([.fr(1.4), .fr(1)], spacing: 18) {
            Panel(title: "\(w.asset.symbol) · SELECTED", fill: true) {
                VStack(alignment: .leading, spacing: 7) {
                    kv("added", DateFmt.ymd(w.addedAt) + " · \(days)d ago" + (w.priceAtAdd.map { " · at " + f.price($0) } ?? ""))
                    kv("since added", f.pct(r.sinceAdded, 1), Theme.signColor(r.sinceAdded))
                    kv("entry / target", (w.entry.map { f.price($0) } ?? "—") + " / " + (w.target.map { f.price($0) } ?? "—")
                       + (r.atEntry ? " · at entry" : ""), r.atEntry ? Theme.acc : Theme.t2)
                    kv("alert", store.alertSummary(w.assetID))
                    kv("note", w.note ?? "—", w.note == nil ? Theme.t4 : Theme.t2)
                }
            }
            Panel(title: "ACTIONS", fill: true) {
                VStack(alignment: .leading, spacing: 2) {
                    action("convert to position…", "⌘↵", Theme.acc) { store.convertWatch(w) }
                    action("edit entry · target · note", "e") { store.openWatchEdit(w) }
                    action("set alert", "a") { store.openAlertSetup(subject: .asset(w.assetID)) }
                    action(store.watchConfirmRemove == w.id ? "⌫ again to remove" : "remove from watchlist", "⌫",
                           store.watchConfirmRemove == w.id ? Theme.neg : Theme.t2) { store.requestRemoveWatch(w) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var empty: some View {
        Panel(title: "NOTHING WATCHED YET") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Follow an asset without buying it: the price since you added it, how far it is from your entry, an alert when it gets there. Converting it later records a normal buy.")
                    .font(Theme.mono(12)).foregroundStyle(Theme.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                TT("try   ⌘K watch tao entry 320 target 520", 12, Theme.t3)
                HStack(spacing: 6) {
                    BracketButton("+ watch asset  n", color: Theme.acc) { store.openWatchAdd() }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .accessibilityIdentifier("watch-empty")
    }

    private func kv(_ k: String, _ v: String, _ c: Color = Theme.t2) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            TT(k, 12, Theme.t3).frame(width: 130, alignment: .leading)
            TT(v, 12, c).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func action(_ label: String, _ key: String, _ c: Color = Theme.t2, _ run: @escaping () -> Void) -> some View {
        TermButton(action: run, hoverBg: Theme.selected) {
            HStack { TT(label, 12, c); Spacer(); TT(key, 11, Theme.t4) }
                .padding(.horizontal, 6).frame(height: 26)
        }
    }
}

/// n / e on the watchlist: ticker, planned entry, target, note.
struct WatchSheet: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focus: Field?
    enum Field { case asset, entry, target, note }

    var body: some View {
        let d = store.watchDraft ?? WatchDraft()
        let a = store.watchDraftAsset(d)
        let problem = store.watchDraftProblem(d)
        let f = Fmt.current
        let price = a.flatMap { store.quotes[$0.id]?.price }
        VStack(spacing: 0) {
            HStack {
                TT(d.editing == nil ? "WATCH ASSET" : "EDIT WATCH · \(a?.symbol ?? "")", 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT("tab next · ↵ save · esc cancel", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            VStack(alignment: .leading, spacing: 12) {
                row("asset") {
                    HStack(spacing: 10) {
                        prompt
                        if d.editing == nil { field("TAO", \.asset, .asset, width: 120, upper: true) } else { TT(a?.symbol ?? "", 13, Theme.t1).frame(width: 120, alignment: .leading) }
                        TT(a.map { $0.name.lowercased() + (price.map { " · " + f.price($0) } ?? "") } ?? "", 12, Theme.t3)
                    }
                }
                row("entry") { HStack(spacing: 10) { prompt; field("buy at or below · optional", \.entry, .entry) } }
                row("target") { HStack(spacing: 10) { prompt; field("optional", \.target, .target) } }
                row("note") { HStack(spacing: 10) { prompt; field("optional", \.note, .note) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            HStack {
                if let problem, !d.asset.isEmpty { TT(problem, 11, Theme.neg) } else { TT("not a transaction · nothing is bought", 11, Theme.t4) }
                Spacer()
                BracketButton("cancel", color: Theme.t2) { store.watchDraft = nil }
                BracketButton(d.editing == nil ? "watch ↵" : "save ↵", color: problem == nil ? Theme.acc : Theme.faint) { store.saveWatch() }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("watch-save")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(width: 560)
        .onAppear { focus = d.editing == nil && d.asset.isEmpty ? .asset : .entry }
    }

    private var prompt: some View { TT(">", 12, Theme.acc) }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 0) { TT(label, 12, Theme.t3).frame(width: 90, alignment: .leading); c() }
    }

    private func field(_ placeholder: String, _ kp: WritableKeyPath<WatchDraft, String>, _ f: Field, width: CGFloat? = nil, upper: Bool = false) -> some View {
        TextField(placeholder, text: Binding(
            get: { store.watchDraft?[keyPath: kp] ?? "" },
            set: { v in store.watchDraft?[keyPath: kp] = upper ? v.uppercased() : v }))
            .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
            .focused($focus, equals: f)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : width)
            .accessibilityIdentifier("watch-\(f)")
    }
}

/// The carry-over block of the add-transaction sheet while converting a watch item (§06).
struct ConvertCarryOver: View {
    @Environment(AppStore.self) private var store
    let c: WatchConvertState

    var body: some View {
        let w = c.item, f = Fmt.current
        HStack(alignment: .top, spacing: 0) {
            TT("carry over", 12, Theme.t3).frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let t = w.target { check(\.target, "target \(f.price(t)) → Base scenario") }
                if let n = w.note { check(\.note, "note → transaction note · \(n)") }
                if w.target != nil { check(\.alert, "alert → target alert above \(f.price(w.target!)) · entry alerts paused") }
                check(\.keepWatching, "keep on watchlist")
            }
        }
    }

    private func check(_ kp: WritableKeyPath<WatchConversion.CarryOver, Bool>, _ label: String) -> some View {
        let on = c.carry[keyPath: kp]
        return TermButton(action: {
            store.converting?.carry[keyPath: kp].toggle()
            if kp == \WatchConversion.CarryOver.note { store.tx?.note = on ? "" : (c.item.note ?? "") }
        }, hoverBg: Theme.selected) {
            HStack(spacing: 8) {
                TT(on ? "[x]" : "[ ]", 12, on ? Theme.acc : Theme.t4)
                TT(label, 12, on ? Theme.t2 : Theme.t4).lineLimit(1)
            }
        }
    }
}
