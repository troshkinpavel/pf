import PFCore
import PFCoreUI
import SwiftUI

/// What Changed (design §03): reads top to bottom as an answer: five numbers, one sentence,
/// then the evidence. change = market move + flows; flows are never coloured as gain or loss.
struct ChangesView: View {
    @Environment(AppStore.self) private var store
    static let impactCols: [Columns.Col] = [.fixed(22), .fixed(36), .fixed(70), .fixed(130), .fixed(90), .fixed(80), .fixed(110), .fixed(84), .fr(1)]

    var body: some View {
        let p = store.wcPeriod, f = Fmt.current
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                header(p)
                if let r = store.attribution(p), r.complete, r.startValue > 0 || r.flows != 0 {
                    let twr = store.periodTWR(p)
                    kpis(r, twr: twr)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        TT("› ", 12, Theme.acc)
                        Text(Attribution.summary(r, twr: twr, period: p, symbol: symbol, fmt: f))
                            .font(Theme.mono(12)).foregroundStyle(Theme.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("changes-summary")
                    Columns([.fr(1.15), .fr(1)], spacing: 18) {
                        Panel(title: "BRIDGE · START → NOW", fill: true) { bridge(r) }
                        Panel(title: "ALLOCATION DRIFT", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0), fill: true) { drift(r) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    impact(r)
                } else {
                    empty(store.attribution(p))
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
        .onAppear { store.loadAttributionHistory() }
    }

    private func symbol(_ id: AssetID) -> String { store.asset(id)?.symbol ?? id }

    private func header(_ p: Attribution.Period) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                TT("WHAT CHANGED", 15, Theme.t1, weight: .semibold, tracking: 0.6)
                TT(since(p), 12, Theme.t3)
            }
            Spacer()
            HStack(spacing: 14) {
                Tabs(items: Attribution.Period.allCases.map { TabItem(id: $0.rawValue, label: $0.rawValue) }, selected: p.rawValue, hPad: 10, vPad: 3) {
                    store.wcPeriod = Attribution.Period(rawValue: $0)!; store.wcSel = 0; store.loadAttributionHistory()
                }
                TT("← → range · m movers", 11, Theme.t4)
            }
        }
        .padding(.bottom, 14).overlay(alignment: .bottom) { Hairline() }
    }

    private func since(_ p: Attribution.Period) -> String {
        let start = p.start(now: Date(), dayStartHour: store.settings.dayStartHour)
        guard let r = store.attribution(p) else { return "since " + DateFmt.ymd(start) }
        var s = p == .today ? "since \(String(format: "%02d:00", store.settings.dayStartHour)) local" : "since " + DateFmt.ymd(start)
        if r.buys > 0 { s += " · \(r.buys) buy\(r.buys == 1 ? "" : "s")" }
        if r.sells > 0 { s += " · \(r.sells) sell\(r.sells == 1 ? "" : "s")" }
        return s
    }

    private func kpis(_ r: Attribution.Result, twr: Double?) -> some View {
        let f = Fmt.current
        let flowNote: String = {
            var p: [String] = []
            if r.moneyIn != 0 { p.append("in " + f.money(r.moneyIn, 0)) }
            if r.moneyOut != 0 { p.append("out " + f.money(abs(r.moneyOut), 0)) }
            return p.isEmpty ? "no buys or sells" : p.joined(separator: " · ")
        }()
        return Columns(Array(repeating: .fr(1), count: 5)) {
            stat("CHANGE", f.signed(r.change, 0), Theme.signColor(r.change), f.money(r.startValue, 0) + " → " + f.money(r.endValue, 0), first: true)
            stat("MARKET MOVE", f.signed(r.marketMove, 0), Theme.signColor(r.marketMove), "price effect on holdings")
            stat("FLOWS · EXCLUDED", r.flows == 0 ? f.money(Decimal(0), 0) : f.signed(r.flows, 0), Theme.t1, flowNote)
            stat("REALIZED P&L", r.realized == 0 ? f.money(Decimal(0), 0) : f.signed(r.realized, 0), r.realized == 0 ? Theme.t1 : Theme.signColor(r.realized),
                 r.sells == 0 ? "no sells" : "\(r.sells) sell\(r.sells == 1 ? "" : "s") · inside market move")
            stat("TWR", f.pct(twr ?? r.performancePct, 1), Theme.signColor(twr ?? r.performancePct), twr == nil ? "flow-adjusted · history loading" : "deposits excluded")
        }
        .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("changes-kpis")
    }

    private func stat(_ k: String, _ v: String, _ c: Color, _ sub: String, first: Bool = false) -> some View {
        StripCell(first: first) {
            CapsLabel(k)
            TT(v, 18, c, weight: .medium)
            TT(sub, 11, Theme.t4)
        }
    }

    // MARK: bridge

    private struct Step { let label: String; let value: Decimal; let flow: Bool }

    /// A text waterfall on a zoomed axis: top 3 contributors under the market move, the rest
    /// folded into "others", then flows (▒, neutral) — excluded from return.
    private func bridge(_ r: Attribution.Result) -> some View {
        let f = Fmt.current
        let moves = r.assets.filter { $0.contribution != 0 }.sorted { $0.contribution > $1.contribution }
        let top = Set(moves.sorted { abs($0.contribution.double) > abs($1.contribution.double) }.prefix(3).map(\.id))
        var steps = moves.filter { top.contains($0.id) }.map { Step(label: "  " + symbol($0.id), value: $0.contribution, flow: false) }
        let rest = moves.filter { !top.contains($0.id) }
        if !rest.isEmpty { steps.append(Step(label: "  \(rest.count) other\(rest.count == 1 ? "" : "s")", value: rest.reduce(0) { $0 + $1.contribution }, flow: false)) }
        if r.moneyIn != 0 { steps.append(Step(label: "money in · excluded", value: r.moneyIn, flow: true)) }
        if r.moneyOut != 0 { steps.append(Step(label: "money out · excluded", value: r.moneyOut, flow: true)) }
        var cum = r.startValue.double, marks = [cum]
        var spans: [(Double, Double)] = []
        for s in steps { let a = cum; cum += s.value.double; spans.append((a, cum)); marks.append(cum) }
        let mm = r.marketMove.double
        marks.append(r.startValue.double + mm)
        let lo0 = marks.min() ?? 0, hi0 = marks.max() ?? 1, pad = max((hi0 - lo0) * 0.06, 1)
        let lo = lo0 - pad, hi = hi0 + pad, W = 40.0
        let X = { (v: Double) in Int(((v - lo) / max(hi - lo, 1e-9) * W).rounded()) }
        func line(_ a: Double, _ b: Double, _ ch: String) -> String {
            String(repeating: " ", count: min(X(a), X(b))) + String(repeating: ch, count: max(1, abs(X(b) - X(a))))
        }
        return VStack(alignment: .leading, spacing: 4) {
            row("start", String(repeating: " ", count: X(r.startValue.double)) + "┃", Theme.t1, f.money(r.startValue, 0), Theme.t1, Theme.t3)
            row("market move", line(r.startValue.double, r.startValue.double + mm, "─"), Theme.t5, f.signed(r.marketMove, 0), Theme.signColor(r.marketMove), Theme.t1)
                .padding(.top, 3).overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                row(s.label, line(spans[i].0, spans[i].1, s.flow ? "▒" : "█"), s.flow ? Theme.t3 : Theme.signColor(s.value),
                    f.signed(s.value, 0), s.flow ? Theme.t1 : Theme.signColor(s.value), s.flow ? Theme.t3 : Theme.text)
            }
            row("now", String(repeating: " ", count: X(r.endValue.double)) + "┃", Theme.t1, f.money(r.endValue, 0), Theme.t1, Theme.t1)
                .padding(.top, 3).overlay(alignment: .top) { Rectangle().fill(Theme.kbdBorder).frame(height: 1) }
            TT("█ price effect · ▒ money in / out (excluded from twr) · ┃ total · realized p&l sits inside market move", 11, Theme.t4)
                .padding(.top, 8)
        }
        .accessibilityIdentifier("changes-bridge")
    }

    private func row(_ label: String, _ bar: String, _ bc: Color, _ v: String, _ vc: Color, _ lc: Color) -> some View {
        HStack(spacing: 10) {
            TT(label, 12, lc).frame(width: 168, alignment: .leading)
            Text(bar).font(Theme.mono(12)).foregroundStyle(bc).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).clipped()
            TT(v, 12, vc).frame(width: 96, alignment: .trailing)
        }
    }

    // MARK: drift

    private func drift(_ r: Attribution.Result) -> some View {
        let f = Fmt.current
        let rows = r.assets.filter { $0.weightStart > 0.05 || $0.weightEnd > 0.05 }.sorted { abs($0.weightDelta) > abs($1.weightDelta) }
        let cols: [Columns.Col] = [.fixed(22), .fixed(70), .fixed(120), .fixed(76), .fr(1)]
        return VStack(spacing: 0) {
            Columns(cols) { Color.clear; HeadCell("ASSET", align: .leading); HeadCell("START → NOW"); HeadCell("Δ"); HeadCell("CAUSE", align: .leading).padding(.leading, 18) }
                .frame(height: 26).padding(.trailing, 14).overlay(alignment: .bottom) { Hairline() }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, a in
                Columns(cols) {
                    Color.clear
                    TT(symbol(a.id), 12, Theme.t1, weight: .medium)
                    Cell(f.num(a.weightStart, 1) + " → " + f.num(a.weightEnd, 1), Theme.t2)
                    Cell(pp(a.weightDelta), abs(a.weightDelta) >= 2 ? Theme.t1 : Theme.t3)
                    TT(Attribution.cause(a, result: r, fmt: f), 12, Theme.t3).padding(.leading, 18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: store.settings.rowHeight).padding(.trailing, 14)
                .overlay(alignment: .bottom) { if i < rows.count - 1 { Rectangle().fill(Theme.rowBorder).frame(height: 1) } }
            }
        }
    }

    private func pp(_ v: Double) -> String { (abs(v) < 0.05 ? "±" : v < 0 ? "−" : "+") + Fmt.current.num(abs(v), 1) + "pp" }

    // MARK: impact

    private func impact(_ r: Attribution.Result) -> some View {
        let f = Fmt.current, rows = r.byImpact
        let mx = rows.map { abs($0.contribution.double) }.max() ?? 1
        return Panel(title: "MOVERS BY PORTFOLIO IMPACT · \(store.wcPeriod.label)", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.impactCols) {
                    Color.clear; HeadCell("#", align: .leading); HeadCell("ASSET", align: .leading); Color.clear
                    HeadCell("PRICE Δ"); HeadCell("WEIGHT"); HeadCell("IMPACT $"); HeadCell("IMPACT")
                    HeadCell("← − · CONTRIBUTION · + →", align: .center)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14).overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, a in
                    let bars = AsciiChart.diverging(a.contribution.double, max: mx, half: 16)
                    TableRow(selected: i == store.wcSel, height: store.settings.rowHeight, onSelect: { store.wcSel = i },
                             onOpen: { store.openAsset(a.id) }, divider: i < rows.count - 1) {
                        Columns(Self.impactCols) {
                            RowMark(on: i == store.wcSel)
                            TT(String(format: "%02d", i + 1), 12, Theme.t4)
                            TT(symbol(a.id), 12, Theme.t1, weight: .medium)
                            TT(store.asset(a.id)?.name.lowercased() ?? "", 12, Theme.t4)
                            Cell(f.pct(a.priceChange, 1), Theme.signColor(a.priceChange))
                            Cell(f.num(a.weightEnd, 1) + "%", Theme.t2)
                            Cell(a.contribution == 0 ? f.money(Decimal(0), 0) : f.signed(a.contribution, 0), Theme.signColor(a.contribution))
                            Cell(r.startValue > 0 ? pp((a.contribution / r.startValue).double * 100) : "—", Theme.signColor(a.contribution))
                            HStack(spacing: 0) { TT(bars.left, 12, Theme.neg); TT("│", 12, Theme.track); TT(bars.right, 12, Theme.pos) }.frame(maxWidth: .infinity)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                    }
                }
            }
        }
        .accessibilityIdentifier("changes-impact")
    }

    // MARK: empty

    /// Says exactly what is missing and when it appears (design §11).
    private func empty(_ r: Attribution.Result?) -> some View {
        let missing = r?.missing.map(symbol) ?? []
        let start = store.wcPeriod.start(now: Date(), dayStartHour: store.settings.dayStartHour)
        let line: String = {
            if r == nil { return "No transactions in this portfolio yet. Add one (⌘N) and its changes appear here." }
            if !missing.isEmpty {
                return "Needs a price for \(missing.joined(separator: ", ")) at \(DateFmt.ymd(start)) \(DateFmt.hm(start)). History is loading; if a source has none, attribution for this range stays unavailable."
            }
            return "Nothing was held at \(DateFmt.ymd(start)) \(DateFmt.hm(start)) and nothing was bought since."
        }()
        return Panel(title: "NOT ENOUGH HISTORY") {
            VStack(alignment: .leading, spacing: 12) {
                Text(line).font(Theme.mono(12)).foregroundStyle(Theme.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                TT("range       " + store.wcPeriod.label.lowercased() + " · since " + DateFmt.ymd(start) + " " + DateFmt.hm(start), 12, Theme.t3)
                if !missing.isEmpty { TT("missing     " + missing.joined(separator: " · ") + (r.map { "  (\($0.assets.count - missing.count) of \($0.assets.count) priced)" } ?? ""), 12, Theme.t3) }
                HStack(spacing: 6) {
                    BracketButton("open movers  m", color: Theme.acc) { store.toggleChangesMode() }
                    BracketButton("load history") { store.loadAttributionHistory() }
                    if store.wcPeriod != .d30 { BracketButton("try 30d") { store.wcPeriod = .d30; store.loadAttributionHistory() } }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .accessibilityIdentifier("changes-empty")
    }
}
