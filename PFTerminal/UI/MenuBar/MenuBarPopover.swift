import PFCore
import PFCoreUI
import SwiftUI

/// Menu bar companion. Works with the main window closed.
struct MenuBarPopover: View {
    @Environment(AppStore.self) private var store

    var body: some View {
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
                Tabs(items: store.doc.livePortfolios.map { TabItem(id: $0.id.uuidString, label: $0.name.lowercased()) } + [TabItem(id: "all", label: "all")],
                     selected: store.context.storageKey, hPad: 6, vPad: 1) { key in
                    if let c = PortfolioContext(storageKey: key) { store.setContext(c) }
                }
                .padding(.top, -4)
            }
            if !store.hasPortfolio || s.isEmpty {
                TT(store.hasPortfolio ? "no positions yet" : "not set up yet", 12, Theme.t2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TT(f.money(s.totalValue), 24, Theme.t1, weight: .medium)
                    HStack {
                        HStack(spacing: 0) { TT(f.signed(s.change24h) + " ", 12, Theme.signColor(s.change24h)); TT("today", 12, Theme.t3) }
                        Spacer(); TT(f.pct(s.change24hPct), 12, Theme.signColor(s.change24h))
                    }
                    HStack {
                        HStack(spacing: 0) { TT("all time ", 12, Theme.t3); TT(f.signed(s.unrealized, 0), 12, Theme.signColor(s.unrealized)) }
                        Spacer(); TT(f.pct(s.returnPct, 1), 12, Theme.signColor(s.unrealized))
                    }
                }
                VStack(spacing: 0) {
                    ForEach(s.positions.prefix(store.settings.popoverRows)) { v in
                        TermButton(action: { open(); store.openAsset(v.asset.id) }, hoverBg: Theme.tabBg) {
                            Columns([.fixed(44), .fixed(70), .fixed(64), .fr(1)]) {
                                TT(v.asset.symbol, 12, Theme.t1)
                                Cell(f.compact(v.value), Theme.t2)
                                Cell(f.pct(v.change24h), Theme.signColor(v.change24h))
                                Cell(spark(v), Theme.signColor(v.change24h)).opacity(0.7)
                            }
                            .frame(height: 24)
                        }
                    }
                }
                .padding(.top, 8).overlay(alignment: .top) { Hairline() }
                VStack(alignment: .leading, spacing: 3) {
                    rank("best", s.best24)
                    rank("worst", s.worst24)
                }
                .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Hairline() }
            }
            HStack {
                BracketButton("open portfolio", color: Theme.acc) { open() }
                Spacer()
                BracketButton("refresh") { Task { await store.refresh(auto: false) } }
            }
            .padding(.top, 8).overlay(alignment: .top) { Hairline() }
            HStack {
                TT("⌘K commands", 10.5, Theme.t4); Spacer(); TT("⌘, settings", 10.5, Theme.t4); Spacer()
                TermButton(action: { NSApp.terminate(nil) }) { TT("⌘Q quit", 10.5, Theme.t4) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .frame(width: 340)
        .background(Color(hex: 0x141517))
        .preferredColorScheme(.dark)
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
        return AsciiChart.sparkline(AsciiChart.resample(vals, to: 10))
    }

    private func rank(_ k: String, _ r: Ranked?) -> some View {
        Columns([.fixed(52), .fixed(44), .fr(1)]) {
            TT(k, 11.5, Theme.t3); TT(r?.symbol ?? "—", 11.5, Theme.text); TT(r.map { Fmt.current.pct($0.value) } ?? "—", 11.5, Theme.signColor(r?.value))
        }
    }

    private func open() { store.presentMainWindow() }
}
