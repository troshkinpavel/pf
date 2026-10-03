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

        let realizedClosed = s.closed.count
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // One stat box, two rows: what you hold and made · how it performed.
                VStack(spacing: 0) {
                    Columns(Array(repeating: .fr(1), count: 6)) {
                        stat("VALUE", f.money(s.totalValue, 0), Theme.t1, "\(s.positions.count) positions", first: true)
                        stat("NET CONTRIBUTED", f.money(s.netContributed, 0), Theme.t1, "in − out · \(s.transactionCount) tx")
                        stat("OPEN COST BASIS", f.money(s.costBasis, 0), Theme.t1, "what is still held")
                        stat("UNREALIZED", f.signed(s.unrealized, 0), Theme.signColor(s.unrealized), f.pct(s.unrealizedReturnPct, 1) + " on open cost")
                        stat("REALIZED", f.signed(s.realized, 0), s.realized == 0 ? Theme.t1 : Theme.signColor(s.realized), "\(realizedClosed) closed position\(realizedClosed == 1 ? "" : "s")")
                        stat("TOTAL P&L", f.signed(s.totalPnL, 0), Theme.signColor(s.totalPnL), "realized + unrealized")
                    }
                    Columns(Array(repeating: .fr(1), count: 5)) {
                        stat("TOTAL RETURN", f.pct(s.totalReturnPct, 1), Theme.signColor(s.totalReturnPct), s.isPartial ? "needs every price" : "on \(f.money(s.invested, 0)) invested", first: true)
                        stat("TWR", f.pct(hist.twrPercent, 1), Theme.signColor(hist.twrPercent), hist.twrPercent == nil ? "needs history" : "deposits excluded")
                        stat("MAX DRAWDOWN", all.count > 1 ? f.num(dd.max * 100, 1) + "%" : "—", dd.max < 0 ? Theme.neg : Theme.t1, ddDate.map { DateFmt.ymd($0) + " · twr" } ?? "needs history")
                        stat("BEST", byRet.first.map { $0.asset.symbol + " " + f.pct($0.returnPct, 1) } ?? "—", Theme.signColor(byRet.first?.returnPct), byRet.first.map { f.signed($0.unrealized, 0) + " unrealized" } ?? "")
                        stat("WORST", byRet.count > 1 ? byRet.last!.asset.symbol + " " + f.pct(byRet.last!.returnPct, 1) : "—", Theme.signColor(byRet.last?.returnPct), byRet.count > 1 ? f.signed(byRet.last?.unrealized, 0) + " unrealized" : "")
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                }
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("performance-stats")

                // Performance with its drawdown underneath, beside a full-height allocation.
                Columns([.fr(2), .fr(1)], spacing: 18) {
                    Panel(title: "PERFORMANCE · ALL", fill: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            PortfolioChartView(chart: hist, mode: store.analyticsMode, rows: 12, style: store.settings.chartStyle,
                                               spanMinutes: spanMin, emptyText: "missing historical data") {
                                ChartModeTabs(mode: store.analyticsMode) { store.analyticsMode = $0 }
                            }
                            HStack {
                                TT("DRAWDOWN FROM PEAK · TWR", 10.5, Theme.t2, tracking: 0.84)
                                Spacer()
                                if all.count > 1 {
                                    HStack(spacing: 16) {
                                        HStack(spacing: 0) { TT("max ", 11.5, Theme.t3); TT(f.num(dd.max * 100, 1) + "%", 11.5, Theme.neg); TT(ddDate.map { " · " + DateFmt.ymd($0) } ?? "", 11.5, Theme.t3) }
                                        HStack(spacing: 0) { TT("now ", 11.5, Theme.t3); TT(f.num(dd.current * 100, 1) + "%", 11.5, Theme.text) }
                                    }
                                }
                            }
                            .padding(.top, 10).padding(.bottom, 8).padding(.top, 14)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1).padding(.top, 14) }
                            if all.count > 1 {
                                GeometryReader { geo in
                                    let cw = Theme.cell(12)
                                    let cols = max(10, Int((geo.size.width - 9 * cw) / cw))
                                    let rows = AsciiChart.drawdownRows(AsciiChart.resample(dd.series, to: cols), height: 5) { f.num($0, 1) }
                                    HStack(alignment: .top, spacing: 0) {
                                        chartLines(rows.map(\.axis), Theme.t4).frame(width: 9 * cw)
                                        chartLines(rows.map(\.plot), Theme.neg).opacity(0.75)
                                    }
                                }
                                .frame(height: 60)
                            } else {
                                TT("missing historical data", 11, Theme.t4).frame(height: 60)
                            }
                        }
                    }
                    Panel(title: "ALLOCATION", fill: true) {
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
                            Spacer(minLength: 0)
                            let stable = s.positions.filter(\.asset.isStablecoin)
                            if !stable.isEmpty {
                                let value = stable.compactMap(\.value).reduce(0, +), share = stable.compactMap(\.allocation).reduce(0, +)
                                HStack {
                                    TT("STABLECOINS", 10.5, Theme.t2, tracking: 0.84); Spacer()
                                    TT(f.money(value, 0), 12, Theme.t2); TT(f.num(share, 1) + "%", 12, Theme.text).frame(width: 56, alignment: .trailing)
                                }
                                .padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                            }
                            let top2 = s.positions.prefix(2).compactMap(\.allocation).reduce(0, +)
                            TT("top 2 = \(f.num(top2, 1))% of portfolio · largest \(s.positions.first?.asset.symbol ?? "—") \(f.num(s.positions.first?.allocation ?? 0, 1))%", 11, Theme.t4)
                                .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }

                positions
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

    static let posCols: [Columns.Col] = [.fixed(22), .fixed(70), .fixed(110), .fixed(110), .fixed(110), .fixed(84), .fixed(64), .fr(1)]

    /// Open positions: cost → value, unrealized P&L and return, and each one's share of the move.
    private var positions: some View {
        let f = Fmt.current, s = store.summary
        let rows = s.positions.sorted { ($0.unrealized ?? 0) > ($1.unrealized ?? 0) }
        let gross = rows.reduce(0.0) { $0 + abs($1.unrealized?.double ?? 0) }
        let mx = rows.map { abs($0.unrealized?.double ?? 0) }.max() ?? 1
        return Panel(title: "POSITIONS · P&L", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.posCols) {
                    Color.clear
                    HeadCell("ASSET", align: .leading); HeadCell("COST"); HeadCell("VALUE"); HeadCell("UNREALIZED"); HeadCell("UNRLZD %"); HeadCell("SHARE")
                    HeadCell("CONTRIBUTION", align: .leading).padding(.leading, 28)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14)
                .overlay(alignment: .bottom) { Hairline() }
                ForEach(rows) { v in
                    let u = v.unrealized?.double ?? 0
                    TableRow(selected: false, height: store.settings.rowHeight, onOpen: { store.openAsset(v.asset.id) }) {
                        Columns(Self.posCols) {
                            Color.clear
                            TT(v.asset.symbol, 12, Theme.t1, weight: .medium)
                            Cell(f.money(v.position.costBasis, 0), Theme.t2)
                            Cell(f.money(v.value, 0), Theme.t1)
                            Cell(f.signed(v.unrealized, 0), Theme.signColor(v.unrealized))
                            Cell(f.pct(v.returnPct, 1), Theme.signColor(v.unrealized))
                            Cell(gross > 0 ? f.num(abs(u) / gross * 100, 0) + "%" : "—", Theme.t2)
                            Text(String(repeating: "█", count: max(1, Int((abs(u) / max(mx, 1e-9) * 32).rounded()))))
                                .font(Theme.mono(12)).foregroundStyle(Theme.signColor(v.unrealized)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading).clipped().padding(.leading, 28)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                    }
                }
                Columns(Self.posCols) {
                    TT("Σ", 12, Theme.t4).frame(maxWidth: .infinity)
                    TT("open", 12, Theme.t2)
                    Cell(f.money(s.costBasis, 0), Theme.t2)
                    Cell(f.money(s.totalValue, 0), Theme.t1)
                    Cell(f.signed(s.unrealized, 0), Theme.signColor(s.unrealized))
                    Cell(f.pct(s.unrealizedReturnPct, 1), Theme.signColor(s.unrealized))
                    Cell("100%", Theme.t4)
                    TT("share = |unrealized| / gross unrealized move · realized " + f.signed(s.realized, 0), 11, Theme.t4).padding(.leading, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 28).padding(.leading, 4).padding(.trailing, 14)
            }
        }
    }
}
