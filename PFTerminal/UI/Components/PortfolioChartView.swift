import SwiftUI

/// Portfolio performance chart. VALUE plots market value (steps up on deposits); P&L plots
/// value − net invested, which shows profit and drawdown periods. The header delta is always
/// flow-adjusted: P&L change and money-weighted return over the visible span.
struct PortfolioChartView<Trailing: View>: View {
    let chart: AppStore.PortfolioChart
    let mode: ChartMode
    let rows: Int
    let style: AsciiChart.Style
    let spanMinutes: Double
    let emptyText: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let f = Fmt.current
        let pnl = chart.pnl, pts = chart.points
        TerminalChart(
            values: mode == .value ? chart.value : pnl, rows: rows, style: style, spanMinutes: spanMinutes, endTime: Date(),
            showLoHi: true, emptyText: emptyText,
            axis: { mode == .pnl && $0 > 0 ? "+" + f.num($0, 0) : f.num($0, 0) },
            value: { mode == .value ? f.money($0) : "pnl " + f.signed($0) },
            delta: { _, _, frac in
                guard pnl.count > 1, pts.count == pnl.count else { return ("", 0) }
                let i = min(pnl.count - 1, max(0, Int((frac * Double(pnl.count - 1)).rounded())))
                let d = pnl[i] - pnl[0]
                return (f.signed(d) + " (" + f.pct(PortfolioHistoryEngine.moneyWeightedReturn(from: pts[0], to: pts[i])) + ")", d)
            },
            trend: (pnl.last ?? 0) - (pnl.first ?? 0),
            trailing: { trailing })
    }
}

/// VALUE / P&L switch for portfolio charts.
struct ChartModeTabs: View {
    let mode: ChartMode
    let pick: (ChartMode) -> Void
    var body: some View {
        Tabs(items: [TabItem(id: "value", label: "value"), TabItem(id: "pnl", label: "p&l")], selected: mode.rawValue) {
            pick(ChartMode(rawValue: $0)!)
        }
    }
}
