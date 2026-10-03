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
                // Design §04: name · pair, then the symbol with the market line beside it.
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        TT(v.asset.name.uppercased() + " · " + v.asset.symbol + "/" + store.settings.currency, 12, Theme.t2, tracking: 0.48)
                        HStack(alignment: .firstTextBaseline, spacing: 28) {
                            TT(v.asset.symbol, 22, Theme.t1, weight: .semibold).fixedSize()
                            if let peg { TT("STABLECOIN · \(peg.peg.currency) PEG", 11, Theme.t3, tracking: 0.44).fixedSize() }
                            marketLine(v)
                        }
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 6) {
                        action("alert", "a") { store.openAlertSetup(subject: .asset(v.asset.id)) }
                        if peg == nil { action("target", "t") { store.openTarget(v.asset.id) } }
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
                        positionPanel(v)
                        if store.summary.positions.count > 1 { impactPanel(v) }
                        allocationPanel(v)
                        contextPanel(v)
                    }
                    .frame(width: 340)
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    // MARK: 0.7 right column (design §04)

    /// MARKET collapsed to one dim line (design §04); the price source stays one click away, quiet.
    private func marketLine(_ v: PositionValuation) -> some View {
        let f = Fmt.current, q = v.quote
        let ath = q.flatMap { q in q.ath.map { ((q.price / $0) - 1).double * 100 } }
        let rank = AssetRegistry.shared.entry(for: v.asset)?.marketCapRank
        let parts = [q?.marketCap.map { "mcap " + f.compact($0) }, q?.volume24h.map { "vol 24h " + f.compact($0) },
                     rank.map { "rank #\($0)" },
                     q?.ath.map { "ath " + f.price($0) + (ath.map { " " + f.pct($0, 1) } ?? "") }].compactMap { $0 }
        let st = store.sourceState(v.asset.id)
        let bad: Bool = { switch st?.status { case .stale?, .noPrice?, nil: true; default: false } }()
        return HStack(spacing: 10) {
            TT(parts.isEmpty ? "no market data yet" : parts.joined(separator: " · "), 11.5, Theme.t3).lineLimit(1).truncationMode(.tail)
            if let q, (q.volume24h ?? 0) < lowLiquidityVolume { TT("! low liquidity", 11.5, Theme.neg).fixedSize() }
            TermButton(action: { store.openSourcePicker(v.asset.id) }) {
                TT("· " + (st?.status.label.lowercased() ?? "—") + (st?.preferred != nil ? " · pinned" : "") + " ‹›", 11.5, bad ? Theme.neg : Theme.t4).fixedSize()
            }
            .help("price source · change")
            .accessibilityIdentifier("price-source")
        }
    }

    private func positionPanel(_ v: PositionValuation) -> some View {
        let f = Fmt.current, p = v.position
        return Panel(title: "POSITION · P&L", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
            VStack(spacing: 7) {
                KV(k: "amount", v: f.amount(p.quantity) + " " + v.asset.symbol)
                KV(k: "cost · avg " + f.price(p.averageEntry), v: f.money(p.costBasis))
                KV(k: "value", v: f.money(v.value))
                divider
                KV(k: "unrealized", v: f.signed(v.unrealized) + " · " + f.pct(v.returnPct, 1), c: Theme.signColor(v.unrealized))
                let sells = p.transactions.filter { $0.type == .sell }.count
                KV(k: "realized", v: p.realizedPnL == 0 && sells == 0 ? f.money(Decimal(0), 0) + " · no sells" : f.signed(p.realizedPnL), c: p.realizedPnL == 0 ? Theme.t2 : Theme.signColor(p.realizedPnL))
                KV(k: "total p&l", v: f.signed(v.totalPnL) + " · " + f.pct(v.totalReturnPct, 1), c: Theme.signColor(v.totalPnL))
            }
        }
    }

    private func impactPanel(_ v: PositionValuation) -> some View {
        let f = Fmt.current
        let cols: [Columns.Col] = [.fixed(54), .fr(1), .fr(1), .fr(1), .fixed(44)]
        return Panel(title: "PORTFOLIO IMPACT", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
            VStack(spacing: 6) {
                Columns(cols) { Color.clear; HeadCell("PRICE"); HeadCell("$"); HeadCell("PF"); HeadCell("RANK") }
                ForEach(store.assetImpact(v.asset.id), id: \.label) { r in
                    Columns(cols) {
                        TT(r.label, 12, Theme.t3)
                        Cell(f.pct(r.priceChange, 1), Theme.signColor(r.priceChange))
                        Cell(r.contribution.map { f.signed($0, 0) } ?? "—", Theme.signColor(r.contribution))
                        Cell(r.pp.map { (abs($0) < 0.05 ? "±" : $0 < 0 ? "−" : "+") + f.num(abs($0), 1) + "pp" } ?? "—", Theme.signColor(r.pp))
                        Cell(r.rank, Theme.t3)
                    }
                }
            }
        }
        .accessibilityIdentifier("asset-impact")
    }

    private func allocationPanel(_ v: PositionValuation) -> some View {
        let f = Fmt.current
        let w = v.allocation ?? 0, t = store.targetWeight(v.asset.id)
        let dd = store.positionDrawdown(v)
        return Panel(title: "ALLOCATION · DRAWDOWN", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
            VStack(spacing: 7) {
                KV(k: "weight now / target", v: f.num(w, 1) + "%" + (t.map { " / " + f.num($0, 1) + "%" } ?? " / —"), c: Theme.t1)
                // ┃ marks the target; the overweight part is amber.
                let width = 30, cut = t.map { min(width, Int(($0 / 100 * Double(width)).rounded())) }
                let fill = min(width, Int((w / 100 * Double(width)).rounded()))
                HStack(spacing: 0) {
                    if let cut {
                        TT(String(repeating: "█", count: min(fill, cut)), 12, Theme.bar)
                        TT(String(repeating: "░", count: max(0, cut - fill)), 12, Theme.track)
                        TT("┃", 12, Theme.t1)
                        TT(String(repeating: "█", count: max(0, fill - cut)), 12, Theme.acc)
                        TT(String(repeating: "░", count: max(0, width - max(fill, cut))), 12, Theme.track)
                    } else {
                        TT(AsciiChart.bar(w / 100, width: width), 12, Theme.bar)
                    }
                    Spacer(minLength: 0)
                }
                if let t, w > t, let val = v.value {
                    KV(k: "over target", v: "+" + f.num(w - t, 1) + "pp · trim ≈ " + f.money(val * Decimal.of((w - t) / w), 0), c: Theme.acc)
                } else if t == nil {
                    KV(k: "target weight", v: "set in Base scenario · g s", c: Theme.t4)
                }
                if let dd {
                    divider
                    KV(k: "local peak · " + String(DateFmt.ymd(dd.at).dropFirst(5)), v: f.money(Decimal.of(dd.peak), 0), c: Theme.t2)
                    KV(k: "from peak", v: dd.fromPeak > -0.05 ? "at peak" : f.pct(dd.fromPeak, 1) + "  " + f.signed(Decimal.of(dd.fromPeakValue), 0), c: dd.fromPeak < -0.05 ? Theme.neg : Theme.t2)
                }
            }
        }
    }

    /// Separates the groups inside a card (design §04).
    private var divider: some View { Rectangle().fill(Theme.innerBorder).frame(height: 1).padding(.vertical, 3) }

    /// Rows hide when empty, so a fresh position shows only what has data.
    @ViewBuilder
    private func contextPanel(_ v: PositionValuation) -> some View {
        let f = Fmt.current, id = v.asset.id
        let watch = store.watchContext(id)
        let scen = store.orderedScenarios.filter { $0.targets[id] != nil }.prefix(4)
        let rules = store.intel.alerts.filter { $0.subject == .asset(id) }
        if watch != nil || !scen.isEmpty || !rules.isEmpty {
            Panel(title: "CONTEXT", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
                VStack(spacing: 7) {
                    if let w = watch {
                        let firstBuy = v.position.transactions.first { $0.type == .buy }
                        let vs = w.priceAtAdd.flatMap { a in firstBuy.map { ((($0.price / a) - 1).double * 100) } }
                        KV(k: "watched " + String(DateFmt.ymd(w.addedAt).dropFirst(5)), v: (w.priceAtAdd.map { f.price($0) } ?? "—") + (vs.map { " → bought " + f.pct($0, 1) } ?? ""), c: Theme.t2)
                        if let e = w.entry, let b = firstBuy { KV(k: "vs planned entry", v: f.pct(((b.price / e) - 1).double * 100, 1) + " · " + f.price(e), c: Theme.t2) }
                    }
                    if !scen.isEmpty {
                        KV(k: "scenarios", v: scen.map { ($0.key ?? String($0.name.prefix(3)).lowercased()) + " " + f.level($0.targets[id]!.price).replacingOccurrences(of: "$", with: "") }.joined(separator: "  "), c: Theme.t2)
                    }
                    if !rules.isEmpty {
                        let fired = rules.filter { $0.state == .fired && !$0.paused }, armed = rules.filter { $0.state == .armed && !$0.paused }
                        KV(k: "alerts", v: (fired.first.map { "⚑ #\($0.number) fired" + ($0.firedAt.map { " " + DateFmt.hm($0) } ?? "") + " · " } ?? "") + "\(armed.count) armed",
                           c: fired.isEmpty ? Theme.t2 : Theme.acc)
                    }
                }
            }
            .accessibilityIdentifier("asset-context")
        }
    }

    private func action(_ label: String, _ key: String, _ a: @escaping () -> Void) -> some View {
        TermButton(action: a, hoverBg: Theme.selected) {
            HStack(spacing: 8) { TT(label, 12, Theme.text); TT(key, 12, Theme.t3) }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Theme.kbdBorder, lineWidth: 1))
        }
    }

    /// Colors for PriceStatus (labels and rules come from PFCore).
    static func statusColor(_ s: PriceStatus?) -> Color {
        switch s {
        case .live?: Theme.pos
        case .cached?: Theme.t1
        case .delayed?, .fallback?: Theme.acc
        case .stale?, .noPrice?, nil: Theme.neg
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
        // Average entry, armed price alerts (⚑ #n) and buys, as in the design.
        let avg = v.position.averageEntry?.double ?? 0
        var levels = avg > 0 ? [ChartLevel(value: avg, color: Theme.acc, label: "avg " + f.price(v.position.averageEntry))] : []
        for a in store.intel.alerts where a.subject == .asset(v.asset.id) && !a.paused {
            let lv: Double? = switch a.kind {
            case .priceAbove, .priceBelow: a.threshold
            case .target: Scenarios.base(store.intel)?.targets[v.asset.id]?.price.double
            default: nil
            }
            if let lv { levels.append(ChartLevel(value: lv, color: Theme.acc, label: "⚑ #\(a.number) " + f.price(Decimal.of(lv)))) }
        }
        let now = Date()
        let buys = v.position.transactions.filter { $0.type == .buy || $0.type == .transferIn }
            .map { 1 - now.timeIntervalSince($0.timestamp) / (span * 60) }.filter { $0 >= 0 && $0 <= 1 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 0
        let off = levels.dropFirst(avg > 0 ? 1 : 0).filter { !vals.isEmpty && ($0.value < lo || $0.value > hi) }
        let avgOff = vals.isEmpty || avg <= 0 ? "" : avg > hi ? " ↑" : avg < lo ? " ↓" : ""
        return Panel(title: "PRICE · \(v.asset.symbol)/\(store.settings.currency) · \(r.rawValue)") {
            TerminalChart(values: vals, rows: 19, style: store.settings.chartStyle, spanMinutes: span, endTime: Date(),
                          emptyText: store.loadingHistory.contains(store.seriesKey(v.asset.id, r)) ? "loading history…" : "missing historical data for \(v.asset.symbol)",
                          axis: { f.priceDigits($0) }, value: { f.price($0) },
                          delta: { a, b, _ in ((a >= b ? "+" : "-") + f.price(abs(a - b)) + " (" + f.pct(b != 0 ? (a / b - 1) * 100 : 0) + ")", a - b) },
                          levels: levels, markers: buys) {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        if avg > 0 { TT("— — avg entry " + f.price(v.position.averageEntry) + avgOff, 11.5, Theme.t3) }
                        if !buys.isEmpty { TT("· ┊ buys", 11.5, Theme.t3) }
                        ForEach(off) { l in TT("· " + l.label + (l.value > hi ? " ↑" : " ↓"), 11.5, Theme.acc) }
                    }
                    Tabs(AppStore.assetRanges.map(\.rawValue), selected: r.rawValue) { store.setAssetRange(ChartRange(rawValue: $0)!) }
                }
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
                    if let n = t.note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                        TT("↳ " + n, 11, Theme.t3).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26).padding(.trailing, 14).padding(.bottom, 4)
                            .accessibilityIdentifier("tx-note")
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
