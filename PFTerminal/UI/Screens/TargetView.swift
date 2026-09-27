import SwiftUI

struct TargetView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focused: Bool

    static let cols: [Columns.Col] = [.fixed(22), .fixed(120), .fixed(120), .fixed(140), .fixed(150), .fixed(110), .fixed(120), .fr(1)]

    var body: some View {
        @Bindable var store = store
        let f = Fmt.current
        if let v = store.targetValuation, let px = v.price {
            let presets = ScenarioEngine.presets(for: px)
            let tv = NumberInput.target(store.targetInput, current: px)
            let eval = { (t: Decimal) in
                ScenarioEngine.evaluate(target: t, quantity: v.position.quantity, costBasis: v.position.costBasis, currentPrice: px,
                                        portfolioTotal: store.summary.totalValue, circulatingSupply: v.quote?.circulatingSupply, ath: v.quote?.ath)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            TT("TARGET PRICE", 15, Theme.t1, weight: .semibold, tracking: 0.6)
                            TT("scenario for current holdings · not a prediction · nothing is saved", 12, Theme.t3)
                        }
                        Spacer()
                        Tabs(items: store.summary.positions.map { TabItem(id: $0.asset.id, label: $0.asset.symbol) }, selected: v.asset.id, hPad: 10, vPad: 3) { id in
                            store.openTarget(id)
                        }
                    }
                    .padding(.bottom, 14).overlay(alignment: .bottom) { Hairline() }

                    HStack(alignment: .top, spacing: 18) {
                        Panel(title: "\(v.asset.symbol) · INPUT", padding: .init(top: 20, leading: 20, bottom: 18, trailing: 20)) {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack(alignment: .top, spacing: 24) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        TT("current", 12, Theme.t3)
                                        TT(f.price(px), 28, Theme.t2).frame(height: 36)
                                    }
                                    .frame(width: 200, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 8) {
                                        TT("target", 12, Theme.t3)
                                        HStack(spacing: 10) {
                                            TT(">", 28, Theme.acc)
                                            TextField("", text: $store.targetInput)
                                                .textFieldStyle(.plain).font(Theme.mono(28)).foregroundStyle(Theme.t1).tint(Theme.acc)
                                                .focused($focused)
                                                .accessibilityIdentifier("target-input")
                                        }
                                        .frame(height: 36)
                                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.kbdBottom).frame(height: 1) }
                                        .frame(maxWidth: 360)
                                        TT("0.1 · .1 · $0.10 · 25x · 150k — ↑↓ step through presets", 11, Theme.t4)
                                    }
                                }
                                HStack(spacing: 6) {
                                    ForEach(presets, id: \.self) { p in
                                        let on = tv.map { abs(($0 - p).double) < 1e-12 * max(1, p.double) } ?? false
                                        TermButton(action: { store.targetInput = "\(p)" }, hoverBg: Theme.tabBg) {
                                            TT("[ \(f.level(p)) ]", 12, on ? Theme.acc : Theme.t2).fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(on ? Theme.tabBg : .clear)
                                        }
                                    }
                                }
                                if let tv, let sc = AsciiChart.targetScale(current: px.double, target: tv.double, presets: presets.map(\.double), fmt: { f.level($0) }) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 0) {
                                            TT(sc.left, 13, Theme.t2); TT(sc.before, 13, sc.reachesUp ? Theme.acc : Theme.neg)
                                            TT("●", 13, Theme.acc); TT(sc.after, 13, Theme.track); TT(sc.right, 13, Theme.t2)
                                        }
                                        .fixedSize()
                                        TT(sc.caret, 13, Theme.acc).fixedSize()
                                        TT(sc.label, 13, Theme.t1).fixedSize()
                                        TT("log scale · ┼ presets", 11, Theme.t4).padding(.top, 6)
                                    }
                                    .padding(.top, 6)
                                } else {
                                    TT(store.targetInput.isEmpty ? "enter a target price" : "can't read that target · try 0.1, 150k or 25x", 12, Theme.t3)
                                }
                            }
                        }
                        Panel(title: "RESULT", padding: .init(top: 16, leading: 16, bottom: 12, trailing: 16)) {
                            VStack(spacing: 8) {
                                if let tv {
                                    let s = eval(tv)
                                    KV(k: "target price", v: f.level(tv))
                                    KV(k: "change from current", v: f.pct(s.deltaPct), c: Theme.signColor(s.deltaPct))
                                    KV(k: "position value", v: f.money(s.positionValue), size: 18)
                                    KV(k: "profit", v: f.signed(s.profit), c: Theme.signColor(s.profit))
                                    KV(k: "return", v: f.pct(s.returnPct, 1), c: Theme.signColor(s.returnPct))
                                    KV(k: "investment multiple", v: s.multiple.map { f.num($0, 2) + "x" } ?? "—")
                                    sep
                                    KV(k: "current market cap", v: f.compact(v.quote?.marketCap), c: Theme.t2)
                                    KV(k: "implied market cap", v: s.impliedMarketCap.map { f.compact($0) } ?? "— no supply data")
                                    if let ath = v.quote?.ath { KV(k: "vs ATH " + f.price(ath), v: s.vsATH.map { f.num($0, 2) + "x" } ?? "—", c: Theme.t2) }
                                    sep
                                    KV(k: "portfolio value", v: f.money(s.portfolioValue, 0))
                                    KV(k: "\(v.asset.symbol) share of portfolio", v: f.num(s.shareOfPortfolio, 1) + "%", c: Theme.t2)
                                } else {
                                    KV(k: "target price", v: "—", c: Theme.t3)
                                }
                            }
                        }
                        .frame(width: 400)
                    }

                    Panel(title: "SCENARIOS · \(v.asset.symbol) · \(f.amount(v.position.quantity)) \(v.asset.symbol)", padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
                        VStack(spacing: 0) {
                            Columns(Self.cols) {
                                Color.clear
                                HeadCell("TARGET", align: .leading); HeadCell("Δ PRICE"); HeadCell("POSITION"); HeadCell("PROFIT")
                                HeadCell("MULTIPLE"); HeadCell("IMPLIED MCAP"); HeadCell("PORTFOLIO")
                            }
                            .frame(height: 24).padding(.leading, 4).padding(.trailing, 14)
                            .overlay(alignment: .bottom) { Hairline() }
                            ForEach(Array(([px] + presets).enumerated()), id: \.offset) { i, t in
                                let s = eval(t)
                                let on = tv.map { abs(($0 - t).double) < 1e-12 * max(1, t.double) } ?? false
                                TableRow(selected: on, height: 26, onSelect: { store.targetInput = "\(t)" }) {
                                    Columns(Self.cols) {
                                        RowMark(on: on)
                                        TT(i == 0 ? f.price(t) + " now" : f.level(t), 12, Theme.t1)
                                        Cell(i == 0 ? "—" : f.pct(s.deltaPct, 0), Theme.t2)
                                        Cell(f.money(s.positionValue, 0))
                                        Cell(f.signed(s.profit, 0), Theme.signColor(s.profit))
                                        Cell(s.multiple.map { f.num($0, 2) + "x" } ?? "—", Theme.t1)
                                        Cell(s.impliedMarketCap.map { f.compact($0) } ?? "—", Theme.t2)
                                        Cell(f.money(s.portfolioValue, 0))
                                    }
                                    .padding(.leading, 4).padding(.trailing, 14)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
            .scrollIndicators(.never)
            .onAppear { focused = true }
        } else {
            TT("no priced position to simulate · add a transaction or wait for market data", 12, Theme.t3)
        }
    }

    private var sep: some View { Rectangle().fill(Theme.innerBorder).frame(height: 1).padding(.vertical, 2) }
}
