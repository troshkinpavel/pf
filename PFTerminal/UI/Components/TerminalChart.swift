import PFCore
import PFCoreUI
import SwiftUI

/// A horizontal price level drawn over the plot (average entry, alert thresholds).
struct ChartLevel: Identifiable {
    var id: String { label }
    let value: Double
    let color: Color
    let label: String
}

/// ASCII line/block chart with y-axis, time axis, hover crosshair and a readout header.
/// Column count follows the available width, so wider windows show more detail.
struct TerminalChart<Trailing: View>: View {
    let values: [Double]
    let rows: Int
    let style: AsciiChart.Style
    let spanMinutes: Double
    let endTime: Date
    var showLoHi = false
    var emptyText = "no price history available"
    var axis: (Double) -> String
    var value: (Double) -> String
    /// (v, v0, position 0…1 of the hovered point) → text + sign for colour.
    var delta: (Double, Double, Double) -> (String, Double)
    /// Overrides the line colour's sign (e.g. P&L change when the plotted value includes deposits).
    var trend: Double? = nil
    /// Dashed horizontal levels, drawn when inside the plotted range.
    var levels: [ChartLevel] = []
    /// Dotted vertical markers at 0…1 of the time span (e.g. buys).
    var markers: [Double] = []
    @ViewBuilder var trailing: Trailing

    @State private var hoverCol: Int?
    private let lineH: CGFloat = 12
    private var height: CGFloat { 16 + 12 + CGFloat(rows) * lineH + 6 + 12 }

    var body: some View {
        GeometryReader { geo in
            let cw = Theme.cell(12)
            let axisChars = 12
            let cols = max(8, Int((geo.size.width - CGFloat(axisChars) * cw) / cw))
            let vals = values.count >= 2 ? AsciiChart.resample(values, to: style == .line ? cols + 1 : cols) : []
            let plot = vals.isEmpty ? [] : AsciiChart.render(vals, height: rows, style: style, label: axis)
            VStack(alignment: .leading, spacing: 0) {
                header(vals, cols: cols).frame(height: 16).padding(.bottom, 12)
                if plot.isEmpty {
                    TT(emptyText, 11, Theme.t4)
                        .frame(maxWidth: .infinity, minHeight: CGFloat(rows) * lineH + 18, alignment: .center)
                } else {
                    HStack(spacing: 0) {
                        lines(plot.map(\.axis), color: Theme.t4).frame(width: CGFloat(axisChars) * cw, alignment: .leading)
                        lines(plot.map(\.plot), color: Theme.signColor(trend ?? (vals.last ?? 0) - (vals.first ?? 0)))
                            .opacity(style == .line ? 1 : 0.6)
                            .frame(width: CGFloat(cols) * cw, alignment: .leading)
                            .overlay { overlays(vals) }
                            .overlay(alignment: .topLeading) {
                                if let h = hoverCol {
                                    Rectangle().fill(Theme.chartGrid).frame(width: 1)
                                        .offset(x: (CGFloat(h) + 0.5) * cw)
                                }
                            }
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(p): hoverCol = max(0, min(cols - 1, Int(p.x / cw)))
                                case .ended: hoverCol = nil
                                }
                            }
                    }
                    .frame(height: CGFloat(rows) * lineH, alignment: .top)
                    TT(AsciiChart.timeAxis(cols: cols, spanMinutes: spanMinutes), 11, Theme.t4)
                        .padding(.top, 6)
                }
            }
        }
        .frame(height: height)
    }

    /// Same scale as AsciiChart.render: row j shows max − j/(rows−1) · range.
    private func overlays(_ vals: [Double]) -> some View {
        Canvas { ctx, size in
            guard let mn = vals.min(), let mx = vals.max() else { return }
            let rg = mx - mn == 0 ? 1 : mx - mn
            for m in markers where (0...1).contains(m) {
                var p = Path(); p.move(to: CGPoint(x: m * size.width, y: 0)); p.addLine(to: CGPoint(x: m * size.width, y: size.height))
                ctx.stroke(p, with: .color(Theme.chartGrid), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            for l in levels where l.value >= mn && l.value <= mx {
                let y = CGFloat((mx - l.value) / rg * Double(rows - 1)) * lineH + lineH / 2
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(l.color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ctx.draw(Text(l.label).font(Theme.mono(10)).foregroundColor(l.color), at: CGPoint(x: 4, y: y - 7), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func lines(_ rows: [String], color: Color) -> some View {
        Canvas { ctx, _ in
            for (i, r) in rows.enumerated() {
                ctx.draw(Text(r).font(Theme.mono(12)).foregroundColor(color), at: CGPoint(x: 0, y: CGFloat(i) * lineH + lineH / 2), anchor: .leading)
            }
        }
    }

    @ViewBuilder private func header(_ vals: [Double], cols: Int) -> some View {
        HStack(spacing: 16) {
            if let first = vals.first, vals.count >= 2 {
                let idx = hoverCol.map { style == .line ? $0 + 1 : $0 } ?? vals.count - 1
                let v = vals[min(idx, vals.count - 1)]
                let ago = Double(vals.count - 1 - idx) / Double(vals.count - 1) * spanMinutes
                let d = endTime.addingTimeInterval(-ago * 60)
                TT(hoverCol == nil ? "now" : DateFmt.ago(minutes: ago) + " · " + DateFmt.ymd(d) + " " + DateFmt.hm(d), 11.5, Theme.t3)
                let dl = delta(v, first, Double(idx) / Double(vals.count - 1))
                TT(value(v), 11.5, Theme.t1)
                TT(dl.0, 11.5, Theme.signColor(dl.1))
                if showLoHi, hoverCol == nil, let lo = vals.min(), let hi = vals.max() {
                    TT("lo \(value(lo)) · hi \(value(hi))", 11.5, Theme.t3)
                }
            }
            Spacer(minLength: 8)
            trailing.fixedSize().layoutPriority(1)   // controls keep their size; the readout truncates
        }
    }
}

extension TerminalChart where Trailing == EmptyView {
    init(values: [Double], rows: Int, style: AsciiChart.Style, spanMinutes: Double, endTime: Date, showLoHi: Bool = false,
         emptyText: String = "no price history available",
         axis: @escaping (Double) -> String, value: @escaping (Double) -> String, delta: @escaping (Double, Double, Double) -> (String, Double), trend: Double? = nil) {
        self.init(values: values, rows: rows, style: style, spanMinutes: spanMinutes, endTime: endTime, showLoHi: showLoHi, emptyText: emptyText,
                  axis: axis, value: value, delta: delta, trend: trend, trailing: { EmptyView() })
    }
}
