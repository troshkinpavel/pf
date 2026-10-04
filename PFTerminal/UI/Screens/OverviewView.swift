import PFCore
import PFCoreUI
import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store

    static let cols: [Columns.Col] = [.fixed(22), .fixed(118), .fixed(100), .fixed(78), .fixed(116), .fixed(116), .fixed(104), .fixed(108), .fixed(84), .fr(1)]

    var body: some View {
        let s = store.summary
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                MetricStrip()
                WhatMovedBand()
                PerformancePanel()
                if store.isAll { AllPortfoliosPanel() }
                PositionsPanel()
            }
            .padding(.top, 7)
        }
        .scrollIndicators(.never)
        // TWR · ALL needs the full history, not just the chart's range.
        .onAppear { store.loadHistory(store.assetsHeld(during: .all), .all) }
    }
}

private struct MetricStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.summary, f = Fmt.current
        let dc = Theme.signColor(s.change24h)
        Columns([.fr(1.45), .fr(1), .fr(1), .fr(1), .fr(1.15)]) {
            cell(first: true) {
                CapsLabel(store.isAll ? "ALL PORTFOLIOS" : "NET VALUE")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let total = s.totalParts(f)
                    TT(total.value, 28, Theme.t1, weight: .medium, tracking: -0.28).minimumScaleFactor(0.6)
                    if let note = total.note { TT("· " + note, 11, Theme.neg) }
                }
                // Rolling 24h (as the menu bar, widgets and the 24H column); "today" is the WHAT MOVED band.
                HStack(spacing: 14) { TT(f.signed(s.change24h) + " 24h", 12, dc); TT(f.pct(s.change24hPct), 12, dc) }
            }
            cell {
                CapsLabel("TOTAL PNL")
                TT(f.signed(s.totalPnL), 18, Theme.signColor(s.totalPnL), weight: .medium)
                HStack(spacing: 0) { TT(f.pct(s.totalReturnPct) + " ", 12, Theme.signColor(s.totalPnL)); TT("total return", 12, Theme.t3) }
                    .help("realized + unrealized P&L over everything ever invested · unrealized \(f.signed(s.unrealized, 0)) · realized \(f.signed(s.realized, 0))")
            }
            cell {
                CapsLabel("COST BASIS")
                TT(f.money(s.costBasis), 18, Theme.t1, weight: .medium)
                TT(store.isAll ? "\(store.doc.livePortfolios.count) portfolios · \(s.transactionCount) tx" : "\(s.positions.count) assets · \(s.transactionCount) tx", 12, Theme.t3)
            }
            cell {
                // 0.7: the 24h driver moved into the WHAT MOVED band; TWR comes over from Analytics.
                let twr = store.portfolioHistory(.all, points: 121).twrPercent
                CapsLabel("TWR · ALL")
                TT(f.pct(twr, 1), 18, Theme.signColor(twr), weight: .medium)
                TT(twr == nil ? "needs history" : "deposits excluded", 12, Theme.t3)
            }
            VStack(alignment: .leading, spacing: 5) {
                rank("best", s.best, 1)
                rank("worst", s.worst, 1)
                rank("24h ▲", s.best24, 2)
                rank("24h ▼", s.worst24, 2)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
        }
        .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
    }

    /// Label at the top, sub-line at the bottom, value between: the card's content fills its height (design §02).
    private func cell<C: View>(first: Bool = false, @ViewBuilder _ c: () -> C) -> some View {
        SpreadV(minSpacing: 6) { c() }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { if !first { Rectangle().fill(Theme.border).frame(width: 1) } }
    }

    private func rank(_ k: String, _ r: Ranked?, _ dp: Int) -> some View {
        Columns([.fixed(48), .fr(1), .fixed(70)], spacing: 8) {
            TT(k, 12, Theme.t3)
            TT(r?.symbol ?? "—", 12, Theme.t1)
            Cell(r.map { Fmt.current.pct($0.value, dp) } ?? "—", Theme.signColor(r?.value))
        }
    }
}

/// Vertical stack whose children spread over the available height: first at the top, last at the
/// bottom, never closer than `minSpacing`.
struct SpreadV: Layout {
    var minSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let minH = sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * minSpacing
        let h = proposal.height.map { $0.isFinite ? max($0, minH) : minH } ?? minH
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        let total = sizes.reduce(0) { $0 + $1.height }
        let gap = subviews.count > 1 ? max(minSpacing, (bounds.height - total) / CGFloat(subviews.count - 1)) : 0
        var y = bounds.minY
        for (v, s) in zip(subviews, sizes) {
            v.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: s.height))
            y += s.height + gap
        }
    }
}

/// TODAY · WHAT MOVED (design §02): market move and flows kept apart, the top three by $ impact,
/// the entry to What Changed (d). Same numbers as What Changed › today.
private struct WhatMovedBand: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        // One row, never truncated: the fullest variant that fits (least important parts drop first).
        ViewThatFits(in: .horizontal) {
            ForEach(0..<4) { level in row(level) }
        }
        .padding(.horizontal, 16).frame(height: 38)
        .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { store.changesUsesMovers = false; store.go(.changes) }
        .accessibilityIdentifier("what-moved")
    }

    /// 0 everything · 1 short flows label · 2 top 2 · 3 top 1.
    private func row(_ level: Int) -> some View {
        let f = Fmt.current
        let r = store.attribution(.today)
        return HStack(spacing: 0) {
          HStack(spacing: 18) {
            TT("TODAY · WHAT MOVED", 10.5, Theme.t2, tracking: 0.84)
            if let r, r.complete, !r.assets.isEmpty {
                divider
                HStack(spacing: 8) { TT("market move", 12, Theme.t3); TT(f.signed(r.marketMove, 0), 12, Theme.signColor(r.marketMove)) }
                divider
                HStack(spacing: 8) {
                    TT(level < 1 ? "flows · not performance" : "flows", 12, Theme.t3)
                    TT(r.flows == 0 ? f.money(Decimal(0), 0) : f.signed(r.flows, 0), 12, Theme.t2)
                    if r.buys + r.sells > 0 { TT("\(r.buys + r.sells) trade\(r.buys + r.sells == 1 ? "" : "s")", 11, Theme.t4) }
                }
                let top = Array(r.byImpact.prefix(level >= 3 ? 1 : level == 2 ? 2 : 3))
                let mx = max(top.map { abs($0.contribution.double) }.max() ?? 1, .leastNormalMagnitude)   // all-zero movers: 0/0 = NaN traps Int()
                divider
                HStack(spacing: 18) {
                    ForEach(top, id: \.id) { a in
                        HStack(spacing: 6) {
                            TT(store.asset(a.id)?.symbol ?? a.id, 12, Theme.t1, weight: .medium)
                            TT(f.signed(a.contribution, 0), 12, Theme.signColor(a.contribution))
                            TT(String(repeating: "█", count: max(1, Int((abs(a.contribution.double) / mx * 6).rounded()))), 10, Theme.signColor(a.contribution).opacity(0.7))
                        }
                    }
                }
            } else {
                TT(r == nil ? "no transactions yet" : "needs start-of-day prices", 12, Theme.t4)
            }
          }
          .fixedSize()   // never truncated: ViewThatFits measures this at full size
          Spacer(minLength: 16)
          divider.padding(.trailing, 18)
          HStack(spacing: 6) { TT("details", 11, Theme.t2); Kbd("d") }.fixedSize()   // like the title bar shortcuts
        }
    }

    /// Full-height separator between the band's parts (design §02).
    private var divider: some View { Rectangle().fill(Theme.innerBorder).frame(width: 1, height: 38) }
}

private struct PerformancePanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let r = store.overviewRange
        Panel(title: "PERFORMANCE") {
            PortfolioChartView(chart: store.portfolioHistory(r), mode: store.overviewMode, rows: store.isAll ? 7 : 13, style: store.settings.chartStyle,
                               spanMinutes: spanMinutes(r),
                               emptyText: store.loadingHistory.isEmpty ? "missing historical data · chart fills in as snapshots are recorded" : "loading history…") {
                HStack(spacing: 14) {
                    ChartModeTabs(mode: store.overviewMode) { store.overviewMode = $0 }
                    Tabs(AppStore.overviewRanges.map(\.rawValue), selected: r.rawValue) { store.setOverviewRange(ChartRange(rawValue: $0)!) }
                }
            }
        }
    }

    private func spanMinutes(_ r: ChartRange) -> Double {
        if let s = r.seconds { return s / 60 }
        return Date().timeIntervalSince(r.start(now: Date(), firstTransaction: store.summary.firstDate)) / 60
    }
}

private struct PositionsPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.summary, f = Fmt.current
        Panel(title: "POSITIONS · \(s.positions.count)", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(OverviewView.cols) {
                    Color.clear
                    HeadCell("ASSET", align: .leading); HeadCell("PRICE"); HeadCell("24H"); HeadCell("AMOUNT"); HeadCell("VALUE")
                    HeadCell("AVG ENTRY"); HeadCell("UNREALIZED"); HeadCell("UNRLZD %"); HeadCell("ALLOCATION", align: .leading).padding(.leading, 28)
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14)
                .overlay(alignment: .bottom) { Hairline() }

                ForEach(Array(s.positions.enumerated()), id: \.element.id) { i, v in
                    // In ALL the keyboard selection belongs to the portfolios table above.
                    let on = !store.isAll && i == store.sel
                    TableRow(selected: on, height: store.settings.rowHeight,
                             onSelect: { if !store.isAll { store.sel = i } }, onOpen: { store.openAsset(v.asset.id) }) {
                        Columns(OverviewView.cols) {
                            RowMark(on: on)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                TT(v.asset.symbol, 12, Theme.t1, weight: .medium)
                                TT(v.asset.name.lowercased(), 11, Theme.t4)
                                if v.asset.isStablecoin {
                                    let depeg = store.pegCheck(v.asset.id)?.status == .depeg
                                    TT(depeg ? "DEPEG" : "STABLE", 10, depeg ? Theme.neg : Theme.t3, tracking: 0.4)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).clipped()
                            Cell(f.price(v.price))
                            Cell(f.pct(v.change24h), Theme.signColor(v.change24h))
                            Cell(f.amount(v.position.quantity), Theme.t2)
                            Cell(f.money(v.value), v.value == nil ? Theme.t3 : Theme.t1)
                            Cell(f.price(v.position.averageEntry), Theme.t2)
                            Cell(f.signed(v.unrealized), Theme.signColor(v.unrealized))
                            Cell(f.pct(v.returnPct, 1), Theme.signColor(v.unrealized))
                            let over = (v.allocation ?? 0) > (store.targetWeight(v.asset.id) ?? .infinity)
                            AllocationCell(fraction: (v.allocation ?? 0) / 100, label: (v.allocation.map { f.num($0, 1) + "%" } ?? "—") + (over ? " ▲" : ""))
                                .help(over ? "above its Base scenario target weight \(f.num(store.targetWeight(v.asset.id) ?? 0, 0))%" : "")
                                .padding(.leading, 28)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                    }
                    .contextMenu {
                        Button("Open \(v.asset.symbol)") { store.openAsset(v.asset.id) }
                        Button("Add Transaction…") { store.openTx(TxDraft(asset: v.asset.symbol)) }
                        Divider()
                        Button("Remove Position…", role: .destructive) { store.requestRemovePosition(v.asset.id) }
                            .disabled(store.isAll)
                    }
                }

                Columns(OverviewView.cols) {
                    TT("Σ", 12, Theme.t4).frame(maxWidth: .infinity)
                    TT("total", 12, Theme.t2).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                    Cell(f.pct(s.change24hPct), Theme.signColor(s.change24h))
                    Color.clear
                    Cell(f.money(s.totalValue), Theme.t1)
                    Cell(f.money(s.costBasis), Theme.t2)
                    Cell(f.signed(s.unrealized, 0), Theme.signColor(s.unrealized))
                    Cell(f.pct(s.returnPct, 1), Theme.signColor(s.unrealized))
                    TT(s.realized != 0 ? "100.0% · realized " + f.signed(s.realized, 0) : "100.0%", 12, Theme.t4).padding(.leading, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 28).padding(.leading, 4).padding(.trailing, 14)
            }
        }
    }
}

/// ASCII allocation bar that shortens (never truncates with "…") when the column is narrow.
struct AllocationCell: View {
    let fraction: Double
    let label: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach([20, 16, 12, 8, 5], id: \.self) { w in
                HStack(spacing: 10) {
                    TT(AsciiChart.bar(fraction, width: w), 12, Theme.bar).fixedSize()
                    TT(label, 12, Theme.text).fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
