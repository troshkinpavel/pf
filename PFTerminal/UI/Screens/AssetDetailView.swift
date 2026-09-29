import PFCore
import PFCoreUI
import SwiftUI

struct AssetDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let v = store.currentAsset {
            content(v)
        } else {
            TT("no asset selected", 12, Theme.t3)
        }
    }

    private func content(_ v: PositionValuation) -> some View {
        let f = Fmt.current, q = v.quote, peg = store.pegCheck(v.asset.id)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        TT(v.asset.name.uppercased() + " / " + store.settings.currency, 12, Theme.t2, tracking: 0.48)
                        TT(v.asset.symbol, 22, Theme.t1, weight: .semibold)
                        if let peg { TT("STABLECOIN · \(peg.peg.currency) PEG", 11, Theme.t3, tracking: 0.44) }
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        action("target", "t") { store.openTarget(v.asset.id) }
                        action("add transaction", "⌘N") { store.openTx(TxDraft(asset: v.asset.symbol)) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        TT(f.price(v.price), 24, Theme.t1, weight: .medium)
                        if let peg { TT(Self.pegLabel(peg.status), 12, Self.pegColor(peg.status)) }
                        else { HStack(spacing: 0) { TT(f.pct(v.change24h) + " ", 12, Theme.signColor(v.change24h)); TT("24h", 12, Theme.t3) } }
                    }
                }
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) { Hairline() }

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        if let peg { pegStatus(peg) } else { chart(v) }   // a price chart of $1.00 says nothing
                        transactions(v)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        Panel(title: "POSITION", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
                            VStack(spacing: 7) {
                                KV(k: "amount", v: f.amount(v.position.quantity) + " " + v.asset.symbol)
                                KV(k: "average entry", v: f.price(v.position.averageEntry))
                                KV(k: "cost basis", v: f.money(v.position.costBasis))
                                KV(k: "current value", v: f.money(v.value))
                                KV(k: "unrealized pnl", v: f.signed(v.unrealized), c: Theme.signColor(v.unrealized))
                                KV(k: "return", v: f.pct(v.returnPct), c: Theme.signColor(v.returnPct))
                                if v.position.realizedPnL != 0 {
                                    KV(k: "realized pnl", v: f.signed(v.position.realizedPnL), c: Theme.signColor(v.position.realizedPnL))
                                }
                                KV(k: "portfolio weight", v: v.allocation.map { f.num($0, 1) + "%" } ?? "—", c: Theme.t2)
                            }
                        }
                        Panel(title: "MARKET", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
                            VStack(spacing: 7) {
                                KV(k: "price", v: f.price(v.price))
                                ForEach([ChangePeriod.h1, .h24, .d7, .d30], id: \.self) { p in
                                    KV(k: p.rawValue.lowercased(), v: f.pct(q?.change[p]), c: Theme.signColor(q?.change[p]))
                                }
                                KV(k: "market cap", v: f.compact(q?.marketCap))
                                KV(k: "24h volume", v: f.compact(q?.volume24h))
                                KV(k: "ATH", v: f.price(q?.ath))
                                KV(k: "distance from ATH", v: q.flatMap { q in q.ath.map { ((q.price / $0) - 1).double * 100 } }.map { f.pct($0) } ?? "—", c: Theme.neg)
                                if let q, (q.volume24h ?? 0) < lowLiquidityVolume {
                                    KV(k: "! low liquidity", v: "price may be unreliable", c: Theme.neg)
                                }
                                TermButton(action: { store.openSourcePicker(v.asset.id) }) {
                                    KV(k: "price source", v: (q.map { $0.source.lowercased() + " · " + DateFmt.hm($0.timestamp) } ?? "—") + "  ‹ change ›", c: Theme.acc)
                                }
                                .accessibilityIdentifier("price-source")
                            }
                        }
                        if peg == nil {   // price targets are meaningless for a pegged coin
                        Panel(title: "IF \(v.asset.symbol) REACHES", padding: .init(top: 12, leading: 6, bottom: 6, trailing: 6)) {
                            VStack(spacing: 0) {
                                if let px = v.price {
                                    ForEach(ScenarioEngine.presets(for: px), id: \.self) { t in
                                        let s = ScenarioEngine.evaluate(target: t, quantity: v.position.quantity, costBasis: v.position.costBasis, currentPrice: px,
                                                                        portfolioTotal: store.summary.totalValue, circulatingSupply: q?.circulatingSupply, ath: q?.ath)
                                        TermButton(action: { store.openTarget(v.asset.id, "\(t)") }, hoverBg: Theme.selected) {
                                            Columns([.fr(1), .fr(1), .fixed(64)]) {
                                                TT(f.level(t), 12, Theme.text).fixedSize()
                                                Cell(f.money(s.positionValue, 0), Theme.t2)
                                                Cell(s.multiple.map { f.num($0, 2) + "x" } ?? "—", Theme.t1)
                                            }
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                        }
                                    }
                                } else {
                                    TT("price unavailable", 11, Theme.t4).padding(8)
                                }
                            }
                        }
                        }
                    }
                    .frame(width: 340)
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private func action(_ label: String, _ key: String, _ a: @escaping () -> Void) -> some View {
        TermButton(action: a, hoverBg: Theme.selected) {
            HStack(spacing: 8) { TT(label, 12, Theme.text); TT(key, 12, Theme.t3) }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Theme.kbdBorder, lineWidth: 1))
        }
    }

    static func pegLabel(_ s: PegStatus) -> String {
        switch s { case .normal: "PEG · NORMAL"; case .depeg: "DEPEG"; case .unchecked: "PEG · NOT CHECKED YET" }
    }
    static func pegColor(_ s: PegStatus) -> Color {
        switch s { case .normal: Theme.pos; case .depeg: Theme.neg; case .unchecked: Theme.acc }
    }

    /// Stablecoins: peg health instead of a price chart. All state comes from PFCore's PegCheck.
    private func pegStatus(_ c: PegCheck) -> some View {
        let f = Fmt.current
        let band = f.num((Stablecoins.tolerance * 100).double, 1)
        return Panel(title: "PEG STATUS", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
            VStack(spacing: 0) {
                KV(k: "status", v: Self.pegLabel(c.status), c: Self.pegColor(c.status))
                KV(k: "market", v: c.market.map { f.money($0, 4) } ?? "—")
                KV(k: "deviation", v: c.deviationPercent.map { f.pct($0) } ?? "—", c: c.status == .depeg ? Theme.neg : Theme.t1)
                KV(k: "checked", v: c.checkedAt.map { DateFmt.age(max(0, Date().timeIntervalSince($0))) + " ago" } ?? "not yet", c: Theme.t2)
                KV(k: "target", v: f.money(c.peg.target) + " ± \(band)%", c: Theme.t2)
                KV(k: "valued at", v: f.money(c.valuationPrice, c.status == .depeg ? 4 : 2) + (c.status == .depeg ? " · market price" : " · peg"),
                   c: c.status == .depeg ? Theme.neg : Theme.t2)
                if c.status == .depeg {
                    TT("! outside ±\(band)% of \(f.money(c.peg.target)): valued at the market price until it returns to peg", 11, Theme.neg)
                        .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func chart(_ v: PositionValuation) -> some View {
        let f = Fmt.current, r = store.assetRange
        var vals = store.assetSeries(v.asset.id, r)?.points.map(\.price) ?? []
        if r == .all, let first = v.position.transactions.first?.timestamp {
            vals = store.assetSeries(v.asset.id, r)?.points.filter { $0.time >= first.addingTimeInterval(-86400 * 3) }.map(\.price) ?? []
        }
        if let p = v.price, !vals.isEmpty { vals.append(p.double) }
        let span: Double = r.seconds.map { $0 / 60 } ?? Date().timeIntervalSince(v.position.transactions.first?.timestamp ?? Date()) / 60
        return Panel(title: "PRICE · \(v.asset.symbol)/\(store.settings.currency)") {
            TerminalChart(values: vals, rows: 19, style: store.settings.chartStyle, spanMinutes: span, endTime: Date(),
                          emptyText: store.loadingHistory.contains(store.seriesKey(v.asset.id, r)) ? "loading history…" : "missing historical data for \(v.asset.symbol)",
                          axis: { f.priceDigits($0) }, value: { f.price($0) },
                          delta: { a, b, _ in ((a >= b ? "+" : "-") + f.price(abs(a - b)) + " (" + f.pct(b != 0 ? (a / b - 1) * 100 : 0) + ")", a - b) }) {
                Tabs(AppStore.assetRanges.map(\.rawValue), selected: r.rawValue) { store.setAssetRange(ChartRange(rawValue: $0)!) }
            }
        }
    }

    static let txCols: [Columns.Col] = [.fixed(22), .fixed(96), .fixed(52), .fr(1.2), .fr(1.1), .fr(1.1), .fr(1.2), .fr(1.1)]

    private func transactions(_ v: PositionValuation) -> some View {
        let f = Fmt.current, txs = store.currentAssetTransactions
        return Panel(title: "TRANSACTIONS · \(txs.count)", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.txCols) {
                    Color.clear
                    HeadCell("DATE", align: .leading); HeadCell("SIDE", align: .leading); HeadCell("AMOUNT"); HeadCell("PRICE")
                    HeadCell("COST"); HeadCell("VALUE NOW"); HeadCell("PNL")
                }
                .frame(height: 24).padding(.trailing, 14)
                .overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(txs.enumerated()), id: \.element.id) { i, t in
                    let now = v.price.map { $0 * t.quantity }
                    let cost = t.quantity * t.price + (t.type.increases ? t.fee : -t.fee)
                    TableRow(selected: i == store.txSel, height: 24, onSelect: { store.txSel = i }, onOpen: { store.editTx(t) }) {
                        Columns(Self.txCols) {
                            RowMark(on: i == store.txSel)
                            TT(DateFmt.ymd(t.timestamp), 12, Theme.t2)
                            TT(t.type.short, 12, t.type == .buy ? Theme.t2 : t.type == .sell ? Theme.acc : Theme.t3)
                            Cell(f.amount(t.quantity))
                            Cell(f.price(t.price), Theme.t2)
                            Cell(f.money(cost), Theme.t2)
                            Cell(t.type.increases ? f.money(now) : "—")
                            Cell(t.type == .buy ? f.signed(now.map { $0 - cost }) : "—", Theme.signColor(now.map { $0 - cost }))
                        }
                        .padding(.trailing, 14)
                    }
                    .contextMenu {
                        Button("Edit…") { store.editTx(t) }
                        Button("Delete…", role: .destructive) { store.requestDelete(t) }
                    }
                }
                HStack(spacing: 0) {
                    TT("avg entry = Σ cost / Σ amount = \(f.money(v.position.costBasis)) / \(f.amount(v.position.quantity)) = ", 11.5, Theme.t3)
                    TT(f.price(v.position.averageEntry), 11.5, Theme.t1)
                    Spacer()
                    TT("e edit · ⌫ delete", 11, Theme.t4)
                }
                .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 6)
            }
        }
    }
}
