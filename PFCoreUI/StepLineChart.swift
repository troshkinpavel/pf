import PFCore
import SwiftUI

/// PF Terminal's stepped line (─╯ ╭─) drawn as a vector path so it renders crisply at any
/// widget size. Values are quantised to `levels` rows, like the app's ASCII charts.
public struct StepLineShape: Shape {
    public init(values: [Double], levels: Int = 7, cornerRadius: CGFloat = 3) { self.values = values; self.levels = levels; self.cornerRadius = cornerRadius }
    public let values: [Double]          // any scale; normalised internally
    public var levels = 7
    public var cornerRadius: CGFloat = 3

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2, let mn = values.min(), let mx = values.max() else { return p }
        let rg = mx - mn == 0 ? 1 : mx - mn
        let lv = values.map { Int((($0 - mn) / rg * Double(levels - 1)).rounded()) }
        let cols = CGFloat(values.count - 1)
        let cw = rect.width / cols
        func y(_ l: Int) -> CGFloat { rect.maxY - CGFloat(l) / CGFloat(levels - 1) * rect.height }

        p.move(to: CGPoint(x: rect.minX, y: y(lv[0])))
        for i in 0..<(values.count - 1) where lv[i] != lv[i + 1] {
            let cx = rect.minX + (CGFloat(i) + 0.5) * cw
            let y0 = y(lv[i]), y1 = y(lv[i + 1])
            let r = min(cornerRadius, cw / 2, abs(y1 - y0) / 2)
            let dir: CGFloat = y1 < y0 ? -1 : 1
            p.addLine(to: CGPoint(x: cx - r, y: y0))
            p.addQuadCurve(to: CGPoint(x: cx, y: y0 + dir * r), control: CGPoint(x: cx, y: y0))
            p.addLine(to: CGPoint(x: cx, y: y1 - dir * r))
            p.addQuadCurve(to: CGPoint(x: cx + r, y: y1), control: CGPoint(x: cx, y: y1))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: y(lv[lv.count - 1])))
        return p
    }

    /// Linear resample to `n` points (endpoints kept).
    public static func resample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count >= 2, n >= 2 else { return v }
        return (0..<n).map { i in
            let x = Double(i) / Double(n - 1) * Double(v.count - 1)
            let lo = Int(x.rounded(.down)), hi = min(v.count - 1, lo + 1)
            return v[lo] + (v[hi] - v[lo]) * (x - Double(lo))
        }
    }
}

/// Stepped performance line sized to its container: one step per ~`cell` points of width.
public struct StepLineChart: View {
    public init(values: [Double], color: Color, cell: CGFloat = 7, levels: Int = 7, lineWidth: CGFloat = 1.2) {
        self.values = values; self.color = color; self.cell = cell; self.levels = levels; self.lineWidth = lineWidth
    }
    public let values: [Double]
    public let color: Color
    public var cell: CGFloat = 7
    public var levels = 7
    public var lineWidth: CGFloat = 1.2

    public var body: some View {
        GeometryReader { geo in
            let n = max(8, Int(geo.size.width / cell))
            StepLineShape(values: StepLineShape.resample(values, to: n), levels: levels, cornerRadius: min(3, cell / 2))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(lineWidth)
        }
    }
}
