import PFCore
import PFCoreUI
import SwiftUI

struct AnalyticsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.summary, f = Fmt.current
        let hist = store.portfolioHistory(.all, points: 121)
        let all = hist.twr
        let start = ChartRange.all.start(now: Date(), firstTransaction: s.firstDate)
        let spanMin = Date().timeIntervalSince(start) / 60
        let dd = PortfolioHistoryEngine.drawdown(all)
        let ddDate = all.count > 1 ? start.addingTimeInterval(Double(dd.maxIndex) / Double(all.count - 1) * spanMin * 60) : nil
        // Stablecoins are cash: not ranked as best/worst.
        let byRet = s.positions.filter { $0.returnPct != nil && !$0.asset.isStablecoin }.sorted { $0.returnPct! > $1.returnPct! }

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // PORTFOLIO PERFORMANCE: what was made, on what, and how the market did (TWR).
                Columns(Array(repeating: .fr(1), count: 7)) {
                    stat("VALUE", f.money(s.totalValue, 0), Theme.t1, "\(s.positions.count) positions", first: true)
                    stat("NET CONTRIBUTED", f.money(s.netContributed, 0), Theme.t1, "in − out · \(s.transactionCount) tx")
                    stat("UNREALIZED", f.signed(s.unrealized, 0), Theme.signColor(s.unrealized), f.pct(s.unrealizedReturnPct, 1) + " on open cost")
                    stat("REALIZED", f.signed(s.realized, 0), Theme.signColor(s.realized), "\(s.closed.count) closed position\(s.closed.count == 1 ? "" : "s")")
                    stat("TOTAL P&L", f.signed(s.totalPnL, 0), Theme.signColor(s.totalPnL), "realized + unrealized")
                    stat("TOTAL RETURN", f.pct(s.totalReturnPct, 1), Theme.signColor(s.totalReturnPct), s.isPartial ? "needs every price" : "on \(f.money(s.invested, 0)) invested")
                    stat("TWR", f.pct(hist.twrPercent, 1), Theme.signColor(hist.twrPercent), hist.twrPercent == nil ? "needs history" : "deposits excluded")
                }
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("performance-stats")
                Columns(Array(repeating: .fr(1), count: 4)) {
                    stat("OPEN COST BASIS", f.money(s.costBasis, 0), Theme.t1, "what is still held", first: true)
                    stat("BEST", byRet.first.map { $0.asset.symbol + " " + f.pct($0.returnPct, 1) } ?? "—", Theme.signColor(byRet.first?.returnPct), f.signed(byRet.first?.unrealized, 0) + " unrealized")
                    stat("WORST", byRet.count > 1 ? byRet.last!.asset.symbol + " " + f.pct(byRet.last!.returnPct, 1) : "—", Theme.signColor(byRet.last?.returnPct), byRet.count > 1 ? f.signed(byRet.last?.unrealized, 0) + " unrealized" : "")
                    stat("MAX DRAWDOWN", all.count > 1 ? f.num(dd.max * 100, 1) + "%" : "—", Theme.neg, ddDate.map { DateFmt.ymd($0) + " · twr" } ?? "needs history")
                }
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))

                Columns([.fr(2), .fr(1)], spacing: 18) {
                    Panel(title: "PERFORMANCE · ALL") {
                        PortfolioChartView(chart: hist, mode: store.analyticsMode, rows: 12, style: store.settings.chartStyle,
                                           spanMinutes: spanMin, emptyText: "missing historical data") {
                            ChartModeTabs(mode: store.analyticsMode) { store.analyticsMode = $0 }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    Panel(title: "ALLOCATION") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(s.positions) { v in
                                VStack(spacing: 3) {
                                    HStack { TT(v.asset.symbol, 12, Theme.t1); Spacer(); TT(f.money(v.value, 0), 12, Theme.t2) }
                                    HStack(spacing: 8) {
                                        Text(AsciiChart.bar((v.allocation ?? 0) / 100, width: 32)).font(Theme.mono(12)).foregroundStyle(Theme.bar).lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading).clipped()
                                        TT(v.allocation.map { f.num($0, 1) + "%" } ?? "—", 12, Theme.text)
                                    }
                                }
                            }
                            let stable = s.positions.filter(\.asset.isStablecoin)
                            if !stable.isEmpty {
                                let value = stable.compactMap(\.value).reduce(0, +), share = stable.compactMap(\.allocation).reduce(0, +)
                                HStack {
                                    TT("STABLECOINS", 12, Theme.t1, tracking: 0.48); Spacer()
                                    TT(f.money(value, 0), 12, Theme.t2); TT(f.num(share, 1) + "%", 12, Theme.text).frame(width: 64, alignment: .trailing)
                                }
                                .padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                            }
                            let top2 = s.positions.prefix(2).compactMap(\.allocation).reduce(0, +)
                            TT("top 2 = \(f.num(top2, 1))% of portfolio · largest \(s.positions.first?.asset.symbol ?? "—") \(f.num(s.positions.first?.allocation ?? 0, 1))%", 11, Theme.t4)
                                .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }

                Columns([.fr(1), .fr(1), .fr(1)], spacing: 18) {
                    contribution.frame(maxHeight: .infinity, alignment: .top)
                    costValue.frame(maxHeight: .infinity, alignment: .top)
                    Panel(title: "DRAWDOWN FROM PEAK · TWR") {
                        VStack(alignment: .leading, spacing: 10) {
                            if all.count > 1 {
                                GeometryReader { geo in
                                    let cw = Theme.cell(12)
                                    let cols = max(10, Int((geo.size.width - 9 * cw) / cw))
                                    let rows = AsciiChart.drawdownRows(AsciiChart.resample(dd.series, to: cols), height: 8) { f.num($0, 1) }
                                    HStack(alignment: .top, spacing: 0) {
                                        chartLines(rows.map(\.axis), Theme.t4).frame(width: 9 * cw)
                                        chartLines(rows.map(\.plot), Theme.neg).opacity(0.75)
                                    }
                                }
                                .frame(height: 96)
                                HStack {
                                    HStack(spacing: 0) { TT("max ", 12, Theme.t3); TT(f.num(dd.max * 100, 1) + "%", 12, Theme.neg) }
                                    Spacer(); TT(ddDate.map(DateFmt.ymd) ?? "", 12, Theme.t3); Spacer()
                                    HStack(spacing: 0) { TT("now ", 12, Theme.t3); TT(f.num(dd.current * 100, 1) + "%", 12, Theme.text) }
                                }
                            } else {
                                TT("missing historical data", 11, Theme.t4).frame(height: 96)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.top, 7)
        }
        .scrollIndicators(.never)
        .onAppear { store.loadHistory(store.assetsHeld(during: .all), .all) }
    }

    private func chartLines(_ rows: [String], _ c: Color) -> some View {
        Canvas { ctx, _ in
            for (i, r) in rows.enumerated() {
                ctx.draw(Text(r).font(Theme.mono(12)).foregroundColor(c), at: CGPoint(x: 0, y: CGFloat(i) * 12 + 6), anchor: .leading)
            }
        }
    }

    private func stat(_ k: String, _ v: String, _ c: Color, _ sub: String, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CapsLabel(k)
            TT(v, 15, c).minimumScaleFactor(0.7)
            TT(sub, 11, Theme.t4)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { if !first { Rectangle().fill(Theme.innerBorder).frame(width: 1) } }
    }

    /// Total P&L (realized + unrealized) per asset, including closed positions.
    private var contribution: some View {
        let f = Fmt.current, s = store.summary
        // On-peg stablecoins are cash: their cents of peg noise aren't a contribution. A depeg is.
        let cash: (AssetID) -> Bool = { id in store.asset(id)?.isStablecoin == true && store.pegCheck(id)?.status != .depeg }
        var rows: [(String, Decimal)] = s.positions.filter { !cash($0.asset.id) }.map { ($0.asset.symbol, ($0.unrealized ?? 0) + $0.position.realizedPnL) }
        rows += s.closed.filter { !cash($0.assetID) }.map { p in (store.asset(p.assetID)?.symbol ?? "?", p.realizedPnL) }
        rows.sort { $0.1 > $1.1 }
        let total = rows.reduce(Decimal(0)) { $0 + $1.1 }
        let mx = rows.map { abs($0.1.double) }.max() ?? 1
        return Panel(title: "CONTRIBUTION TO PNL") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { r in
                    Columns([.fixed(44), .fixed(96), .fr(1), .fixed(48)]) {
                        TT(r.0, 12, Theme.t1)
                        TT(f.signed(r.1, 0), 12, Theme.signColor(r.1))
                        Text(String(repeating: "█", count: max(1, Int((abs(r.1.double) / max(mx, 1e-9) * 18).rounded()))))
                            .font(Theme.mono(12)).foregroundStyle(Theme.signColor(r.1)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).clipped()
                        Cell(total != 0 ? f.num((r.1 / total).double * 100, 0) + "%" : "—", Theme.t2)
                    }
                }
            }
        }
    }

    private var costValue: some View {
        let f = Fmt.current, s = store.summary
        let mx = s.positions.map { max($0.value?.double ?? 0, $0.position.costBasis.double) }.max() ?? 1
        let n = { (x: Double) in max(1, Int((x / max(mx, 1e-9) * 22).rounded())) }
        return Panel(title: "COST BASIS → VALUE") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.positions) { v in
                    HStack(alignment: .top, spacing: 0) {
                        TT(v.asset.symbol, 12, Theme.t1).frame(width: 44, alignment: .leading)
                        VStack(spacing: 1) {
                            HStack(spacing: 0) {
                                Text(String(repeating: "▒", count: n(v.position.costBasis.double))).font(Theme.mono(12)).foregroundStyle(Theme.faint).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).clipped()
                                Cell(f.money(v.position.costBasis, 0), Theme.t3).frame(width: 84)
                            }
                            HStack(spacing: 0) {
                                Text(String(repeating: "█", count: n(v.value?.double ?? 0))).font(Theme.mono(12)).foregroundStyle(Color(hex: 0xa9acb1)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).clipped()
                                Cell(f.money(v.value, 0)).frame(width: 84)
                            }
                        }
                    }
                }
            }
        }
    }
}
