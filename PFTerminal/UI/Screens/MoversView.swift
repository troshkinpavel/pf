import PFCore
import PFCoreUI
import SwiftUI

/// Separates "moved the most in %" from "moved the portfolio the most in $".
struct MoversView: View {
    @Environment(AppStore.self) private var store
    static let cols: [Columns.Col] = [.fixed(22), .fixed(36), .fixed(70), .fixed(130), .fixed(100), .fixed(120), .fixed(370), .fr(1)]   // design: 22 36 70 130 100 120 240–370 1fr

    var body: some View {
        let f = Fmt.current, r = store.moversRange
        let items = store.movers
        let abs = store.moversMode == .abs
        let key: (Mover) -> Double = abs ? { $0.impact?.double ?? 0 } : { $0.changePct ?? 0 }
        let mx = items.map { Swift.abs(key($0)) }.max() ?? 1
        let net = items.reduce(0.0) { $0 + ($1.impact?.double ?? 0) }
        let drv = items.filter { $0.impact != nil }.max { Swift.abs($0.impact!.double) < Swift.abs($1.impact!.double) }
        let netPct: Double? = r == .all ? store.summary.totalReturnPct
            : MoversEngine.performance(summary: store.summary, transactions: store.contextTransactions, quotes: store.valuationQuotes,
                                       series: [:], range: r, now: store.now)?.percent
        let up = items.filter { ($0.changePct ?? 0) > 0 }.count, down = items.filter { ($0.changePct ?? 0) < 0 }.count
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // Metric strip, like Overview: net · driver · breadth · controls.
                Columns([.fr(1), .fr(1), .fr(0.8), .fixed(250)]) {
                    StripCell(first: true) {
                        CapsLabel("NET / \(r.rawValue)")
                        TT(f.signed(net), 18, Theme.signColor(net), weight: .medium)
                        TT(f.pct(netPct), 12, Theme.signColor(net))
                    }
                    StripCell {
                        CapsLabel("DRIVER")
                        TT(drv.map { $0.valuation.asset.symbol + " " + f.signed($0.impact, 0) } ?? "—", 18, Theme.t1, weight: .medium)
                        TT(drv.map { _ in (net != 0 ? f.num(Swift.abs(drv!.impact!.double / net) * 100, 1) + "%" : "—") + " of move" } ?? "no moves", 12, Theme.t3)
                    }
                    StripCell {
                        CapsLabel("BREADTH")
                        TT("\(up) up · \(down) down", 13, Theme.text)
                    }
                    VStack(alignment: .trailing, spacing: 10) {
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
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                }
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))

                Panel(title: "MOVERS / \(r.rawValue)", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
                    VStack(spacing: 0) {
                        Columns(Self.cols) {
                            Color.clear; HeadCell("#", align: .leading); HeadCell("ASSET", align: .leading); Color.clear
                            HeadCell("CHANGE" + (!abs ? (store.moversDesc ? " ▼" : " ▲") : ""), c: abs ? Theme.t3 : Theme.t1)
                            HeadCell("IMPACT" + (abs ? (store.moversDesc ? " ▼" : " ▲") : ""), c: abs ? Theme.t1 : Theme.t3)
                            HeadCell("← − · CONTRIBUTION · + →", align: .center)
                            HeadCell("WEIGHT")
                        }
                        .frame(height: 26).padding(.leading, 4).padding(.trailing, 14)
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
                                    Cell(f.signed(m.impact), Theme.signColor(m.impact))
                                    HStack(spacing: 0) { TT(bars.left, 12, Theme.neg); TT("│", 12, Theme.track); TT(bars.right, 12, Theme.pos) }
                                        .frame(maxWidth: .infinity)
                                    Cell(m.valuation.allocation.map { f.num($0, 1) + "%" } ?? "—", Theme.t2)
                                }
                                .padding(.leading, 4).padding(.trailing, 14)
                            }
                        }
                        Text("sorted by \(abs ? "dollar impact on the portfolio" : "percentage change") · bar length = \(abs ? "$ contribution" : "% move") relative to the largest mover · impact is net of buys and sells in the period · p toggles · ←→ range")
                            .font(Theme.mono(11)).foregroundStyle(Theme.t4).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 6)
                    }
                }
            }
            .padding(.top, 7)
        }
        .scrollIndicators(.never)
        .onAppear { store.loadMoversHistory() }
    }
}
