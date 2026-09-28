import PFCore
import PFCoreUI
import SwiftUI

/// Separates "moved the most in %" from "moved the portfolio the most in $".
struct MoversView: View {
    @Environment(AppStore.self) private var store
    static let cols: [Columns.Col] = [.fixed(22), .fixed(36), .fixed(70), .fixed(130), .fixed(100), .fixed(120), .fixed(370), .fr(1)]

    var body: some View {
        let f = Fmt.current, r = store.moversRange
        let items = store.movers
        let abs = store.moversMode == .abs
        let key: (Mover) -> Double = abs ? { $0.impact?.double ?? 0 } : { $0.changePct ?? 0 }
        let mx = items.map { Swift.abs(key($0)) }.max() ?? 1
        let net = items.reduce(0.0) { $0 + ($1.impact?.double ?? 0) }
        let drv = items.filter { $0.impact != nil }.max { Swift.abs($0.impact!.double) < Swift.abs($1.impact!.double) }
        let netPct: Double? = r == .all ? store.summary.returnPct
            : MoversEngine.performance(summary: store.summary, transactions: store.contextTransactions, quotes: store.quotes,
                                       series: [:], range: r, now: store.now)?.percent
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TT("MOVERS / \(r.rawValue)", 15, Theme.t1, weight: .semibold, tracking: 0.6)
                    Spacer()
                    HStack(spacing: 18) {
                        HStack(spacing: 2) {
                            Tabs(items: [TabItem(id: "pct", label: "% change"), TabItem(id: "abs", label: "$ impact")], selected: store.moversMode.rawValue, hPad: 10, vPad: 3) {
                                store.moversMode = MoversMode(rawValue: $0)!
                            }
                            TT("p", 11, Theme.t4).padding(.horizontal, 6)
                        }
                        Tabs(AppStore.moverRanges.map(\.rawValue), selected: r.rawValue, hPad: 10, vPad: 3) {
                            store.moversRange = ChartRange(rawValue: $0)!; store.loadMoversHistory()
                        }
                    }
                }
                .padding(.bottom, 14).overlay(alignment: .bottom) { Hairline() }

                HStack(spacing: 28) {
                    HStack(spacing: 0) { TT("net ", 12, Theme.t3); TT(f.signed(net) + " " + f.pct(netPct), 12, Theme.signColor(net)) }
                    if let d = drv {
                        HStack(spacing: 0) {
                            TT("driver ", 12, Theme.t3); TT(d.valuation.asset.symbol + " " + f.signed(d.impact, 0), 12, Theme.t1)
                            TT(" · " + (net != 0 ? f.num(Swift.abs(d.impact!.double / net) * 100, 1) + "%" : "—") + " of move", 12, Theme.t3)
                        }
                    }
                    TT("\(items.filter { ($0.changePct ?? 0) > 0 }.count) up · \(items.filter { ($0.changePct ?? 0) < 0 }.count) down", 12, Theme.t3)
                }

                VStack(spacing: 0) {
                    Columns(Self.cols) {
                        Color.clear; HeadCell("#", align: .leading); HeadCell("ASSET", align: .leading); Color.clear
                        HeadCell("CHANGE" + (!abs ? (store.moversDesc ? " ▼" : " ▲") : ""), c: abs ? Theme.t3 : Theme.t1)
                        HeadCell("IMPACT" + (abs ? (store.moversDesc ? " ▼" : " ▲") : ""), c: abs ? Theme.t1 : Theme.t3)
                        HeadCell("← − · CONTRIBUTION · + →", align: .center)
                        HeadCell("WEIGHT")
                    }
                    .frame(height: 24).padding(.leading, 4)
                    .overlay(alignment: .bottom) { Hairline() }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                        let bars = AsciiChart.diverging(key(m), max: mx, half: 18)
                        TableRow(selected: i == store.msel, height: store.settings.rowHeight, onSelect: { store.msel = i }, onOpen: { store.openAsset(m.valuation.asset.id) }) {
                            Columns(Self.cols) {
                                RowMark(on: i == store.msel)
                                TT(String(format: "%02d", i + 1), 12, Theme.t4)
                                TT(m.valuation.asset.symbol, 12, Theme.t1, weight: .medium)
                                TT(m.valuation.asset.name.lowercased(), 12, Theme.t4)
                                Cell(f.pct(m.changePct), Theme.signColor(m.changePct))
                                Cell(f.signed(m.impact), Theme.signColor(m.changePct))
                                HStack(spacing: 0) { TT(bars.left, 12, Theme.neg); TT("│", 12, Theme.track); TT(bars.right, 12, Theme.pos) }
                                    .frame(maxWidth: .infinity)
                                Cell(m.valuation.allocation.map { f.num($0, 1) + "%" } ?? "—", Theme.t2)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                Text("sorted by \(abs ? "dollar impact on the portfolio" : "percentage change") · bar length = \(abs ? "$ contribution" : "% move") relative to the largest mover · impact is net of buys/sells in the period · p toggles · ←→ range")
                    .font(Theme.mono(11)).foregroundStyle(Theme.t4).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 1020, alignment: .leading)
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
        .onAppear { store.loadMoversHistory() }
    }
}
