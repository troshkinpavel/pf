import PFCore
import PFCoreUI
import SwiftUI

/// Menu bar companion. Works with the main window closed.
struct MenuBarPopover: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group { if store.locked { lockedBody } else { content } }
            .id(store.themeID)
    }

    /// While locked: no portfolio names, values or positions.
    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { TT("PF · locked", 11, Theme.acc); Spacer() }
            TT("unlock in the main window to see your portfolio", 12, Theme.t2)
            HStack {
                BracketButton("open & unlock", color: Theme.acc) { store.presentMainWindow(); store.unlock() }
                Spacer()
                BracketButton("quit", color: Theme.t2) { NSApp.terminate(nil) }
            }
        }
        .padding(14).frame(width: 340)
        .background(Theme.popover)
    }

    private var portfolioTabs: some View {
        Tabs(items: store.doc.livePortfolios.map { TabItem(id: $0.id.uuidString, label: $0.name.lowercased()) } + [TabItem(id: "all", label: "all")],
             selected: store.context.storageKey, hPad: 6, vPad: 1) { key in
            if let c = PortfolioContext(storageKey: key) { store.setContext(c) }
        }
    }

    @ViewBuilder private var content: some View {
        let s = store.summary, f = Fmt.current, fr = store.freshness
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TT(store.contextGlyph + " " + store.contextName.lowercased() + (store.doc.isDemo(store.context) ? " · demo" : ""), 11, Theme.acc)
                Spacer()
                HStack(spacing: 6) {
                    TT(fr.glyph, 11, fr.color)
                    TT(fr.label.lowercased() + " · " + (store.lastSuccess.map(DateFmt.hm) ?? "—"), 11, Theme.t3)
                }
            }
            if store.hasPortfolio && store.doc.livePortfolios.count > 1 {
                // Many portfolios: the row scrolls instead of widening the popover.
                ViewThatFits(in: .horizontal) {
                    portfolioTabs
                    ScrollView(.horizontal, showsIndicators: false) { portfolioTabs }
                }
                .padding(.top, -4)
            }
            if !store.hasPortfolio || s.isEmpty {
                TT(store.hasPortfolio ? "no positions yet" : "not set up yet", 12, Theme.t2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TT(s.totalLabel(f), 24, Theme.t1, weight: .medium).minimumScaleFactor(0.5).lineLimit(1)
                    HStack {
                        HStack(spacing: 0) { TT(f.signed(s.change24h) + " ", 12, Theme.signColor(s.change24h)); TT("24h", 12, Theme.t3) }
                        Spacer(); TT(f.pct(s.change24hPct), 12, Theme.signColor(s.change24h))
                    }
                    HStack {
                        HStack(spacing: 0) { TT("total p&l ", 12, Theme.t3); TT(f.signed(s.totalPnL, 0), 12, Theme.signColor(s.totalPnL)) }
                        Spacer(); TT(f.pct(s.totalReturnPct, 1), 12, Theme.signColor(s.totalPnL))
                    }
                }
                // Positions with their $ impact on the day (design: menu bar 0.7).
                VStack(spacing: 0) {
                    Columns(Self.cols) {
                        Color.clear; HeadCell("VALUE"); HeadCell("24H"); HeadCell("IMPACT"); Color.clear
                    }
                    .frame(height: 22)
                    ForEach(s.positions.prefix(store.settings.popoverRows)) { v in
                        TermButton(action: { open(); store.openAsset(v.asset.id) }, hoverBg: Theme.hover) {
                            Columns(Self.cols) {
                                TT(v.asset.symbol, 12, Theme.t1)
                                Cell(f.compact(v.value), Theme.t2)
                                Cell(f.pct(v.change24h), Theme.signColor(v.change24h))
                                Cell(v.contribution24h.map { f.signed($0, 0) } ?? "—", Theme.signColor(v.contribution24h))
                                Cell(spark(v), Theme.signColor(v.change24h)).opacity(0.7)
                            }
                            .frame(height: 24)
                        }
                    }
                }
                .padding(.top, 8).overlay(alignment: .top) { Hairline() }
                summaryLines(s)
                    .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Hairline() }
            }
            HStack(spacing: 4) {
                BracketButton("open ↵", color: Theme.acc) { open() }
                BracketButton("details d", color: Theme.acc) { open(); store.changesUsesMovers = false; store.go(.changes) }
                Spacer()
                TermButton(action: { Task { await store.refresh(auto: false) } }) {
                    HStack(spacing: 6) { TT("⟳", 12, Theme.t2); TT("⌘R", 11, Theme.t2) }
                }
                .help("refresh prices")
            }
            .padding(.top, 8).overlay(alignment: .top) { Hairline() }
            HStack {
                TT("⌘, settings", 10.5, Theme.t4); Spacer()
                TermButton(action: { NSApp.terminate(nil) }) { TT("⌘Q quit", 10.5, Theme.t4) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .frame(width: 340)
        .background(Theme.popover)
        .preferredColorScheme(store.colorScheme)
        .onAppear {
            store.popoverOpen = true
            store.loadHistory(store.summary.positions.prefix(store.settings.popoverRows).map(\.asset.id), .h24)
            if Date().timeIntervalSince(store.lastSuccess ?? .distantPast) > 15 { Task { await store.refresh(auto: false) } }
        }
        .onDisappear { store.popoverOpen = false }
    }

    private func spark(_ v: PositionValuation) -> String {
        guard let pts = store.assetSeries(v.asset.id, .h24)?.points, pts.count > 2 else { return "" }
        var vals = pts.map(\.price)
        if let p = v.price { vals.append(p.double) }
        return AsciiChart.sparkline(AsciiChart.resample(vals, to: 8))   // 8 cells fit the 64pt column
    }

    static let cols: [Columns.Col] = [.fixed(52), .fixed(64), .fixed(64), .fixed(64), .fr(1)]

    /// moved · flows · the newest unseen alert (the menu bar title never carries a count).
    private func summaryLines(_ s: PortfolioSummary) -> some View {
        let f = Fmt.current
        let moved = s.positions.filter { ($0.contribution24h ?? 0) != 0 }.sorted { abs($0.contribution24h!.double) > abs($1.contribution24h!.double) }.prefix(3)
        let r = store.attribution(.today)
        let alert = store.settings.alertBadge
            ? store.intel.alerts.filter { $0.unseen && $0.state == .fired && !$0.paused }.max { ($0.firedAt ?? .distantPast) < ($1.firedAt ?? .distantPast) } : nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                TT("moved", 11, Theme.t3).frame(width: 52, alignment: .leading)
                Spacer(minLength: 6)
                ForEach(Array(moved.enumerated()), id: \.offset) { i, v in
                    if i > 0 { TT(" · ", 11, Theme.t4) }
                    TT(v.asset.symbol + " ", 11, Theme.t1); TT(f.signed(v.contribution24h, 0), 11, Theme.signColor(v.contribution24h))
                }
                if moved.isEmpty { TT("—", 11, Theme.t4) }
            }
            HStack(spacing: 0) {
                TT("flows", 11, Theme.t3).frame(width: 52, alignment: .leading)
                Spacer(minLength: 6)
                TT(r.map { $0.flows == 0 ? "none today · twr = market move" : f.signed($0.flows, 0) + " · \($0.buys + $0.sells) trade\($0.buys + $0.sells == 1 ? "" : "s") · excluded" } ?? "—", 11, Theme.t2)
            }
            if let a = alert {
                TermButton(action: { open(); store.go(.alerts) }) {
                    HStack(spacing: 0) {
                        TT("⚑ " + store.alertSubjectLabel(a.subject) + " " + AlertEngine.condition(a, fmt: f).replacingOccurrences(of: "price ", with: ""), 11, Theme.acc).lineLimit(1)
                        Spacer(minLength: 6)
                        TT((a.firedAt.map(DateFmt.hm) ?? "") + (a.subject.assetID.map { store.watchContext($0)?.isActive == true ? " · watch" : "" } ?? ""), 11, Theme.t3)
                    }
                }
                .accessibilityIdentifier("menubar-alert")
            }
        }
    }

    private func open() { store.presentMainWindow() }
}
