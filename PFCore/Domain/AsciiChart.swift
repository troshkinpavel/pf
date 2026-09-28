import Foundation

/// Text-mode chart rendering shared by the app and share cards. Pure string output.
public enum AsciiChart {
    public enum Style: String, Codable, CaseIterable, Sendable { case line, blocks }

    public struct Row: Hashable, Sendable {
        public init(axis: String, plot: String) { self.axis = axis; self.plot = plot }
        public let axis: String
        public let plot: String
    }

    /// `line` needs n+1 values for n columns; `blocks` uses one value per column.
    public static func render(_ vals: [Double], height H: Int, style: Style, axisWidth: Int = 10, label: (Double) -> String) -> [Row] {
        guard vals.count >= 2, H >= 2 else { return [] }
        let mn = vals.min()!, mx = vals.max()!
        let rg = (mx - mn) == 0 ? 1 : (mx - mn)
        let cols = style == .line ? vals.count - 1 : vals.count
        var g = Array(repeating: Array(repeating: Character(" "), count: cols), count: H)
        if style == .line {
            let r = vals.map { Int((($0 - mn) / rg * Double(H - 1)).rounded()) }
            for x in 0..<cols {
                let a = r[x], b = r[x + 1]
                if a == b { g[a][x] = "─" }
                else if b > a { g[a][x] = "╯"; g[b][x] = "╭"; for y in (a + 1)..<b { g[y][x] = "│" } }
                else { g[a][x] = "╮"; g[b][x] = "╰"; for y in (b + 1)..<a { g[y][x] = "│" } }
            }
        } else {
            let bl = Array(" ▁▂▃▄▅▆▇█")
            for (x, v) in vals.enumerated() {
                let lev = (v - mn) / rg * Double(H - 1) + 1
                for y in 0..<H {
                    let d = lev - Double(y)
                    g[y][x] = d >= 1 ? "█" : d > 0 ? bl[max(1, Int((d * 8).rounded()))] : " "
                }
            }
        }
        return (0..<H).map { j in
            let lab = j % 3 == 0 || j == H - 1
            let v = mx - Double(j) / Double(H - 1) * rg
            let text = lab ? label(v) : ""
            return Row(axis: String(repeating: " ", count: max(0, axisWidth - text.count)) + text + (lab ? " ┤" : " │"),
                       plot: String(g[H - 1 - j]))
        }
    }

    /// Linear resample to exactly `n` values (endpoints preserved).
    public static func resample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count >= 2, n >= 2 else { return v }
        return (0..<n).map { i in
            let x = Double(i) / Double(n - 1) * Double(v.count - 1)
            let lo = Int(x.rounded(.down)), hi = min(v.count - 1, lo + 1)
            return v[lo] + (v[hi] - v[lo]) * (x - Double(lo))
        }
    }

    public static func bar(_ fraction: Double, width w: Int) -> String {
        let n = max(0, min(w, Int((fraction * Double(w)).rounded())))
        return String(repeating: "█", count: n) + String(repeating: "░", count: w - n)
    }

    public static func sparkline(_ v: [Double]) -> String {
        guard let mn = v.min(), let mx = v.max() else { return "" }
        let ch = Array("▁▂▃▄▅▆▇█"), rg = (mx - mn) == 0 ? 1 : (mx - mn)
        return String(v.map { ch[Int((($0 - mn) / rg * 7).rounded())] })
    }

    /// Diverging bar: left half for negatives, right half for positives, each `half` wide.
    public static func diverging(_ value: Double, max: Double, half: Int) -> (left: String, right: String) {
        let n = max > 0 ? Int((abs(value) / max * Double(half)).rounded()) : 0
        let fill = String(repeating: "█", count: n), pad = String(repeating: " ", count: half - n), blank = String(repeating: " ", count: half)
        if value < 0 { return (pad + fill, blank) }
        if value > 0 { return (blank, fill + pad) }
        return (blank, blank)
    }

    /// Time axis: five labels spread across `cols`, last is "now".
    public static func timeAxis(cols: Int, spanMinutes: Double, indent: Int = 12) -> String {
        var arr = Array(repeating: Character(" "), count: max(cols, 1))
        for i in 0..<5 {
            let lab = i == 4 ? "now" : DateFmt.ago(minutes: spanMinutes * (1 - Double(i) / 4))
            var p = Int((Double(i) * Double(cols - 1) / 4).rounded())
            if i == 4 { p = cols - lab.count } else if i > 0 { p -= lab.count / 2 }
            for (j, c) in lab.enumerated() where p + j >= 0 && p + j < cols { arr[p + j] = c }
        }
        return String(repeating: " ", count: indent) + String(arr)
    }

    /// Drawdown area chart (values are ≤ 0 fractions), top row = 0%.
    public static func drawdownRows(_ dd: [Double], height H: Int, label: (Double) -> String) -> [Row] {
        let md = min(dd.min() ?? -0.01, -0.0001)
        return (0..<H).map { j in
            var line = ""
            for d in dd {
                let lev = d / md * Double(H)
                line += lev >= Double(j + 1) ? "█" : lev > Double(j) + 0.5 ? "▀" : " "
            }
            let edge = j == 0 || j == H - 1
            let t = j == 0 ? "0%" : j == H - 1 ? label(md * 100) + "%" : ""
            return Row(axis: String(repeating: " ", count: max(0, 7 - t.count)) + t + (edge ? " ┤" : " │"), plot: line)
        }
    }

    /// Log-scale target ruler for the target simulator.
    public struct Scale: Sendable {
        public init(left: String, before: String, after: String, right: String, caret: String, label: String, reachesUp: Bool) { self.left = left; self.before = before; self.after = after; self.right = right; self.caret = caret; self.label = label; self.reachesUp = reachesUp }
        public let left: String, before: String, after: String, right: String, caret: String, label: String, reachesUp: Bool
    }

    public static func targetScale(current: Double, target: Double, presets: [Double], width W: Int = 52, fmt: (Double) -> String) -> Scale? {
        guard current > 0, target > 0 else { return nil }
        let lo = min(current, target), hi = max(presets.last ?? target, target, current * 1.01)
        let L = log(lo), R = log(hi)
        guard R > L else { return nil }
        func px(_ v: Double) -> Int { Int(((log(v) - L) / (R - L) * Double(W - 1)).rounded()) }
        var arr = Array(repeating: Character("─"), count: W)
        for p in presets where p > lo && p < hi { arr[px(p)] = "┼" }
        let ti = max(0, min(W - 1, px(target)))
        let l = fmt(lo)
        let ll = String(repeating: " ", count: max(0, 10 - l.count)) + l + " ├"
        let lab = fmt(target)
        return Scale(left: ll, before: String(arr[0..<ti]), after: String(arr[(ti + 1)...]), right: "┤ " + fmt(hi),
                     caret: String(repeating: " ", count: ll.count + ti) + "↑",
                     label: String(repeating: " ", count: max(0, ll.count + ti - lab.count / 2)) + lab,
                     reachesUp: target >= current)
    }
}
