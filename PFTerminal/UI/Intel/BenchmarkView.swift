import PFCore
import PFCoreUI
import SwiftUI

/// Analytics › benchmark (design §10): the stat box stays, this replaces the content below.
/// Portfolio TWR vs BTC / ETH buy-and-hold, chart for the chosen range, every range in the table.
struct BenchmarkPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let f = Fmt.current
        let r = store.benchmark(store.benchmarkRange)
        let name = store.contextName.uppercased()
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                AnalyticsModeTabs(benchmark: true)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(Benchmark.Range.allCases, id: \.self) { x in
                        RangeTab(label: x.rawValue, on: x == store.benchmarkRange) { store.setBenchmarkRange(x) }
                    }
                }
            }
            Columns([.fr(2), .fr(1)], spacing: 18) {
                Panel(title: "CUMULATIVE RETURN · \(r.range.rawValue) · TWR VS BUY-AND-HOLD", fill: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 22) {
                            legend("━ " + name, r.portfolio, Theme.t1, f)
                            legend("━ BTC", r.btc, Theme.acc, f)
                            legend("┅ ETH", r.eth, Theme.t3, f)
                            Spacer()
                        }
                        BenchmarkChart(result: r)
                            .frame(height: 240)
                        HStack {
                            TT(DateFmt.ymd(r.start), 11, Theme.t4)
                            Spacer()
                            TT("now", 11, Theme.t4)
                        }
                        .padding(.leading, 56)
                        let missing = [r.portfolio.missing, r.btc.missing, r.eth.missing].compactMap { $0 }
                        if store.historyPending { TT("loading price history…", 11, Theme.t3) }
                        else if !missing.isEmpty { TT(missing.joined(separator: " · "), 11, Theme.warning) }
                    }
                }
                VStack(spacing: 18) {
                    Panel(title: "RELATIVE · PERCENTAGE POINTS", fill: true) {
                        VStack(spacing: 0) {
                            row(["", name, "BTC", "ETH", "vs BTC", "vs ETH"], header: true)
                            ForEach(Benchmark.Range.allCases, id: \.self) { x in
                                let b = store.benchmark(x)
                                TermButton(action: { store.setBenchmarkRange(x) }, hoverBg: Theme.hover) {
                                    HStack(spacing: 0) {
                                        TT(x == store.benchmarkRange ? "›" : " ", 12, Theme.acc).frame(width: 12)
                                        TT(x.rawValue, 12, Theme.t1).frame(width: 40, alignment: .leading)
                                        cell(f.pct(b.portfolio.returnPct, 1), Theme.t1)
                                        cell(f.pct(b.btc.returnPct, 1), Theme.t2)
                                        cell(f.pct(b.eth.returnPct, 1), Theme.t2)
                                        cell(pp(b.vsBTC, f), Theme.signColor(b.vsBTC))
                                        cell(pp(b.vsETH, f), Theme.signColor(b.vsETH))
                                    }
                                    .padding(.vertical, 6)
                                    .background(x == store.benchmarkRange ? Theme.selected : .clear)
                                }
                                .accessibilityIdentifier("benchmark-row-" + x.rawValue)
                            }
                        }
                    }
                    Panel(title: "METHOD") {
                        VStack(alignment: .leading, spacing: 6) {
                            method(name, "time-weighted return. Deposits and withdrawals excluded.")
                            method("BTC · ETH", "buy-and-hold price return in \(store.settings.currency), same start.")
                            method("pp", "= \(name) − benchmark, simple difference of cumulative returns.")
                            TT("ALL starts " + (store.summary.firstDate.map(DateFmt.ymd) ?? "—") + ", first transaction.", 11, Theme.t4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { store.loadBenchmarkHistory() }
    }

    private func pp(_ v: Double?, _ f: Fmt) -> String {
        guard let v else { return "—" }
        return (v >= 0 ? "+" : "−") + f.num(abs(v), 1) + "pp"
    }

    private func legend(_ label: String, _ s: Benchmark.Side, _ c: Color, _ f: Fmt) -> some View {
        HStack(spacing: 6) {
            TT(label, 11.5, c)
            TT(s.returnPct.map { f.pct($0, 1) } ?? "—", 11.5, Theme.signColor(s.returnPct))
        }
    }

    private func row(_ cols: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 12)
            TT(cols[0], 10.5, Theme.t3).frame(width: 40, alignment: .leading)
            ForEach(1..<cols.count, id: \.self) { i in cell(cols[i], Theme.t3, size: 10.5) }
        }
        .padding(.bottom, 6)
    }

    private func cell(_ s: String, _ c: Color, size: CGFloat = 12) -> some View {
        TT(s, size, c).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func method(_ k: String, _ v: String) -> some View {
        (Text(k + " ").foregroundColor(Theme.t1) + Text(v).foregroundColor(Theme.t3))
            .font(Theme.mono(11)).fixedSize(horizontal: false, vertical: true)
    }
}

/// overview · benchmark  b — the two modes of the Analytics tab.
struct AnalyticsModeTabs: View {
    @Environment(AppStore.self) private var store
    let benchmark: Bool
    var body: some View {
        HStack(spacing: 4) {
            RangeTab(label: "overview", on: !benchmark) { if benchmark { store.toggleBenchmark() } }
            RangeTab(label: "benchmark", on: benchmark) { if !benchmark { store.toggleBenchmark() } }
            Kbd("b").padding(.leading, 6)   // the key that toggles, as a key chip
        }
    }
}

struct RangeTab: View {
    let label: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        TermButton(action: action, hoverBg: Theme.hover) {
            TT(label, 12, on ? Theme.t1 : Theme.t3)
                .padding(.horizontal, 10).frame(height: 24)
                .background(on ? Theme.selected : .clear)
                .overlay { if on { Rectangle().stroke(Theme.border, lineWidth: 1) } }
        }
    }
}

/// Three cumulative-return lines over a zero line: portfolio solid, BTC accent, ETH dashed.
struct BenchmarkChart: View {
    let result: Benchmark.Result

    var body: some View {
        let paths = [result.portfolio.path, result.btc.path, result.eth.path]
        let all: [Double] = paths.flatMap { $0 } + [0]
        let hi = all.max() ?? 1, lo = all.min() ?? -1
        let span = max(hi - lo, 1)
        let f = Fmt.current
        HStack(spacing: 8) {
            VStack(alignment: .trailing) {
                TT(f.pct(hi, 0), 10.5, Theme.t4)
                Spacer()
                TT(f.pct(lo, 0), 10.5, Theme.t4)
            }
            .frame(width: 48)
            GeometryReader { g in
                let y = { (v: Double) in g.size.height * CGFloat((hi - v) / span) }
                ZStack {
                    Path { p in p.move(to: CGPoint(x: 0, y: y(0))); p.addLine(to: CGPoint(x: g.size.width, y: y(0))) }
                        .stroke(Theme.border, lineWidth: 1)
                    line(result.eth.path, g.size, y).stroke(Theme.t3, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    line(result.btc.path, g.size, y).stroke(Theme.acc, lineWidth: 1.3)
                    line(result.portfolio.path, g.size, y).stroke(Theme.t1, lineWidth: 1.6)
                }
            }
            .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
        }
        .accessibilityIdentifier("benchmark-chart")
    }

    private func line(_ pts: [Double], _ size: CGSize, _ y: (Double) -> CGFloat) -> Path {
        Path { p in
            guard pts.count > 1 else { return }
            for (i, v) in pts.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(pts.count - 1), y: y(v))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }
}
