import PFCore
import SwiftUI

// App-only shared UI (macOS + iOS apps, not the widgets): one share card design, rendered by
// ShareRenderer (AppKit) on the Mac and ImageRenderer → share sheet on iPhone.

/// Social card. Separately composed per format; renders only what `ShareCardModel` contains.
public struct ShareCardView: View {
    /// `progress` 0…1 animates the card (chart draws in, bars grow, hero fades in); 1 = still.
    /// `time`: seconds into the motion loop, for effects with their own animation (glitch);
    /// nil = a still frame.
    public init(m: ShareCardModel, progress: Double = 1, time: Double? = nil) { self.m = m; self.progress = progress; self.time = time }
    public let m: ShareCardModel
    public let progress: Double
    public let time: Double?

    /// Motion export (design §16): 3 s — 2.2 s of build-up, then the finished card holds.
    public static let motionDuration: Double = 3
    public static func motionProgress(at t: Double) -> Double { min(1, max(0, t / 2.2)) }

    /// Ease-out: fast start, settles at the end.
    private var e: Double { Self.ease(progress) }
    private static func ease(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }

    // MARK: motion styles

    private var animating: Bool { progress < 1 }
    private var style: ShareMotionStyle { m.motionStyle }
    /// Local 0…1 of the overall progress inside [a, b].
    private func win(_ a: Double, _ b: Double) -> Double { min(1, max(0, (progress - a) / (b - a))) }
    /// A soft peak around `at` (glow flash, number landing).
    private func pulse(_ at: Double, width: Double = 0.07) -> Double { animating ? exp(-pow((progress - at) / width, 2)) : 0 }
    private var cursorOn: Bool { Int(progress * ShareCardView.motionDuration * 4) % 2 == 0 }

    /// A string as it reads at this moment: typed (typewriter), counting (count up), or whole.
    private func tx(_ str: String, _ a: Double, _ b: Double, count: Bool = false) -> String {
        guard animating else { return str }
        switch style {
        case .typewriter:
            let k = win(a, b)
            if k >= 1 { return str }
            if k <= 0 { return "" }
            return String(str.prefix(Int(Double(str.count) * k))) + (cursorOn ? "█" : " ")
        case .countUp: return count ? Self.countUp(str, Self.ease(win(a, b))) : str
        case .scan: return str
        }
    }

    /// The first number in `s` (any grouping or decimal separator) at `k` of its value,
    /// written into the same pattern: "+3.51%" → "+1.76%" at k = 0.5.
    public static func countUp(_ s: String, _ k: Double) -> String {
        guard k < 1 else { return s }
        let chars = Array(s)
        guard let start = chars.firstIndex(where: \.isNumber) else { return s }
        var end = start
        while end < chars.count, chars[end].isNumber || ((chars[end] == "," || chars[end] == ".") && end + 1 < chars.count && chars[end + 1].isNumber) { end += 1 }
        let token = chars[start..<end]
        let digits = token.filter(\.isNumber)
        guard let n = Double(String(digits)) else { return s }
        // Decimals: digits after the last separator — unless that's a thousands group (three
        // digits after something other than a lone 0: "1,234" groups, "0.004" is a decimal).
        var decimals = 0
        if let ls = token.lastIndex(where: { !$0.isNumber }) {
            let after = token.distance(from: ls, to: token.endIndex) - 1
            let before = token[token.startIndex..<ls].filter(\.isNumber)
            decimals = after == 3 && !before.allSatisfy({ $0 == "0" }) ? 0 : after
        }
        var v = String(Int((n * k).rounded()))
        if v.count < decimals + 1 { v = String(repeating: "0", count: decimals + 1 - v.count) + v }
        // Fill the token's pattern from the right; drop unused leading digits and separators.
        var out: [Character] = [], vi = v.endIndex
        for c in token.reversed() {
            if c.isNumber {
                guard vi > v.startIndex else { break }
                vi = v.index(before: vi); out.append(v[vi])
            } else if vi > v.startIndex { out.append(c) }
        }
        while vi > v.startIndex { vi = v.index(before: vi); out.append(v[vi]) }
        return String(chars[..<start]) + String(out.reversed()) + String(chars[end...])
    }

    /// Row `i` of a list: count up slides each row in after the previous one.
    private func rowIn(_ i: Int) -> Double {
        guard animating, style == .countUp else { return 1 }
        let a = 0.32 + Double(i) * 0.08
        return Self.ease(win(a, a + 0.25))
    }

    public struct Palette { public let bg, fg, dim, border, pos, neg, bar: Color; public var acc: Color = Color(hex: 0xe0b35a) }
    public struct Layout {
        public init(pad: CGFloat, gap: CGFloat, chartFont: CGFloat, heroValue: CGFloat, heroPct: CGFloat, pctWithValue: CGFloat, moverFont: CGFloat, moverRow: CGFloat, label: CGFloat) { self.pad = pad; self.gap = gap; self.chartFont = chartFont; self.heroValue = heroValue; self.heroPct = heroPct; self.pctWithValue = pctWithValue; self.moverFont = moverFont; self.moverRow = moverRow; self.label = label }
        public let pad, gap, chartFont, heroValue, heroPct, pctWithValue, moverFont, moverRow, label: CGFloat
    }

    public static func palette(_ t: ShareTheme) -> Palette {
        switch t {
        case .terminal: .init(bg: Color(hex: 0x0e0f11), fg: Color(hex: 0xe4e5e7), dim: Color(hex: 0x7a7e85), border: Color(hex: 0x232529), pos: Color(hex: 0x7fcf9a), neg: Color(hex: 0xe8847a), bar: Color(hex: 0x8b8f96))   // fixed: cards never follow the app theme
        case .monochrome: .init(bg: Color(hex: 0xeeeeea), fg: Color(hex: 0x141414), dim: Color(hex: 0x6b6b66), border: Color(hex: 0xcfcfc9), pos: Color(hex: 0x141414), neg: Color(hex: 0x141414), bar: Color(hex: 0x141414), acc: Color(hex: 0x6b6b66))
        case .phosphor: .init(bg: Color(hex: 0x050b07), fg: Color(hex: 0xa6f0b8), dim: Color(hex: 0x5a9a6a), border: Color(hex: 0x14301d), pos: Color(hex: 0xa6f0b8), neg: Color(hex: 0xf0c27a), bar: Color(hex: 0x5a9a6a), acc: Color(hex: 0xf0c27a))
        }
    }

    public static func layout(_ f: ShareFormat) -> Layout {
        switch f {
        case .square: .init(pad: 72, gap: 44, chartFont: 22, heroValue: 96, heroPct: 150, pctWithValue: 44, moverFont: 28, moverRow: 48, label: 22)
        case .landscape: .init(pad: 56, gap: 36, chartFont: 18, heroValue: 68, heroPct: 112, pctWithValue: 34, moverFont: 22, moverRow: 36, label: 17)
        case .portrait: .init(pad: 80, gap: 56, chartFont: 22, heroValue: 104, heroPct: 168, pctWithValue: 48, moverFont: 30, moverRow: 58, label: 24)
        case .story: .init(pad: 96, gap: 72, chartFont: 24, heroValue: 112, heroPct: 184, pctWithValue: 52, moverFont: 32, moverRow: 64, label: 26)
        }
    }

    private var p: Palette { Self.palette(m.theme) }
    private var l: Layout { Self.layout(m.format) }
    private func sc(_ s: Int) -> Color { s > 0 ? p.pos : s < 0 ? p.neg : p.dim }

    public var body: some View {
        let size = m.format.size
        // Glow: a blurred copy blooms behind the card, flashing as the number lands.
        let flash = (m.effect == .glow || m.effect == .crt) ? pulse(0.78) : 0
        let bloom: (r: CGFloat, o: Double) = switch m.effect {
        case .glow: (14 + 10 * flash, 0.75 + 0.6 * flash)
        case .crt: (6 + 6 * flash, 0.45 + 0.5 * flash)
        default: (0, 0)
        }
        let scanK = style == .scan && animating ? Self.ease(win(0, 0.85)) : 1
        let g = m.effect == .glitch ? glitchFrame : nil
        ZStack {
          p.bg
          if bloom.o > 0 { card.blur(radius: bloom.r).opacity(bloom.o).blendMode(m.theme == .monochrome ? .multiply : .plusLighter) }
          if let g {
              // RGB split: red and cyan copies pulled apart.
              let light = m.theme == .monochrome
              card.colorMultiply(Color(red: 1, green: 0.25, blue: 0.25)).offset(x: g.dx, y: g.dy).opacity(g.alpha).blendMode(light ? .multiply : .plusLighter)
              card.colorMultiply(Color(red: 0.2, green: 1, blue: 0.9)).offset(x: -g.dx).opacity(g.alpha * 0.9).blendMode(light ? .multiply : .plusLighter)
          }
          card
          if let g { glitchLayer(g) }
          ShareEffectLayer(effect: m.effect, light: m.theme == .monochrome)
        }
        .frame(width: CGFloat(size.w), height: CGFloat(size.h))
        .mask(alignment: .top) { Rectangle().frame(height: CGFloat(size.h) * scanK + (scanK >= 1 ? 0 : 2)) }
        .overlay(alignment: .top) {
            if scanK < 1 {
                // The scan line and its afterglow.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, p.fg.opacity(0.18)], startPoint: .top, endPoint: .bottom).frame(height: 90)
                    Rectangle().fill(p.fg.opacity(0.9)).frame(height: 3).shadow(color: p.fg, radius: 8)
                }
                .offset(y: CGFloat(size.h) * scanK - 92)
            }
        }
        .background(p.bg)
        .overlay(Rectangle().strokeBorder(p.border, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: m.effect == .crt ? 40 : 0))
        .environment(\.colorScheme, m.theme == .monochrome ? .light : .dark)
    }

    // MARK: glitch (its own animation: bursts at fixed moments of the 3 s loop)

    struct Glitch {
        var dx: CGFloat
        var alpha: Double              // strength of the colour split
        var dy: CGFloat
        var slices: [(y: CGFloat, h: CGFloat, shift: CGFloat)]
        var bars: [(rect: CGRect, color: Int)]
        var bands: [(y: CGFloat, h: CGFloat)]
    }

    /// Deterministic per frame: the same card always exports the same glitch.
    private var glitchFrame: Glitch {
        let size = m.format.size, W = CGFloat(size.w), H = CGFloat(size.h)
        let intensity: Double, seed: UInt64
        if let t = time {
            let burst = [0.22, 1.12, 2.62].map { exp(-pow((t - $0) / 0.06, 2)) }.max() ?? 0
            let flicker = [0.6, 1.7, 2.2].map { exp(-pow((t - $0) / 0.03, 2)) * 0.6 }.max() ?? 0
            intensity = 0.04 + 0.96 * max(burst, flicker)
            seed = UInt64(max(0, t) * 30) &+ 1
        } else {
            intensity = 0.28; seed = 7
        }
        var rng = SplitMix(seed)
        var g = Glitch(dx: CGFloat(1 + 18 * intensity), alpha: 0.3 + 0.55 * intensity, dy: intensity > 0.5 ? CGFloat(rng.next(-3, 3)) : 0, slices: [], bars: [], bands: [])
        if intensity > 0.3 {
            for _ in 0..<Int(2 + intensity * 5) {
                g.slices.append((y: CGFloat(rng.next(0, Double(H))), h: CGFloat(rng.next(6, 48)), shift: CGFloat(rng.next(-1, 1) * (12 + 70 * intensity))))
            }
            for _ in 0..<Int(intensity * 5) {
                g.bars.append((rect: CGRect(x: rng.next(0, Double(W) - 140), y: rng.next(0, Double(H)), width: rng.next(30, 140), height: rng.next(3, 7)), color: Int(rng.next(0, 2.99))))
            }
        }
        for _ in 0..<3 { g.bands.append((y: CGFloat(rng.next(0, Double(H))), h: CGFloat(rng.next(8, 30)))) }
        return g
    }

    @ViewBuilder private func glitchLayer(_ g: Glitch) -> some View {
        let size = m.format.size, W = CGFloat(size.w), H = CGFloat(size.h)
        ZStack(alignment: .topLeading) {
            // Displaced slices: a band of the card, shifted sideways over a bg strip.
            ForEach(Array(g.slices.enumerated()), id: \.offset) { _, sl in
                ZStack(alignment: .topLeading) { p.bg; card.offset(x: sl.shift) }
                    .frame(width: W, height: H)
                    .mask(alignment: .topLeading) { Rectangle().frame(width: W, height: sl.h).offset(y: sl.y) }
            }
            ForEach(Array(g.bands.enumerated()), id: \.offset) { _, b in
                Rectangle().fill(Color.black.opacity(m.theme == .monochrome ? 0.06 : 0.28)).frame(width: W, height: b.h).offset(y: b.y)
            }
            ForEach(Array(g.bars.enumerated()), id: \.offset) { _, b in
                Rectangle().fill([p.neg, p.pos, p.acc][b.color].opacity(0.85)).frame(width: b.rect.width, height: b.rect.height).offset(x: b.rect.minX, y: b.rect.minY)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var card: some View {
        let size = m.format.size
        return VStack(alignment: .leading, spacing: l.gap) {
            HStack {
                caps(tx(m.title, 0, 0.14))
                Spacer()
                HStack(spacing: 14) { caps(m.date); Text("●").font(Theme.mono(l.label)).foregroundStyle(p.pos) }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if m.brand {
                HStack { Spacer(); PFGlyph(size: l.label * 1.4, color: p.dim) }
            }
        }
        .padding(l.pad)
        .frame(width: CGFloat(size.w), height: CGFloat(size.h), alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        if m.bars != nil || (m.chart == nil && m.movers == nil && m.note != nil) {
            barsContent
        } else {
            classicContent
        }
    }

    /// What changed / vs benchmark (design §16): hero, then the bars (and drift, note).
    @ViewBuilder private var barsContent: some View {
        switch m.format {
        case .landscape:
            HStack(alignment: .top, spacing: l.gap * 1.5) {
                VStack(alignment: .leading, spacing: l.gap) { hero; Spacer(minLength: 0); noteView }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: l.gap) { barsList; lists }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        default:
            VStack(alignment: .leading, spacing: l.gap) {
                hero
                Spacer(minLength: 0)
                barsList
                lists
                noteView
            }
        }
    }

    @ViewBuilder private var noteView: some View {
        if let n = m.note { Text(tx(n, 0.7, 0.85)).font(Theme.mono((l.moverFont * 0.75).rounded())).foregroundStyle(p.dim).lineLimit(2).opacity(rowIn(5)) }
    }

    @ViewBuilder private var barsList: some View {
        if let bars = m.bars {
            VStack(alignment: .leading, spacing: 0) {
                if !m.barsTitle.isEmpty {
                    HStack { caps(m.barsTitle); Spacer(); caps(m.barsSub) }
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 2) }
                }
                ForEach(Array(bars.enumerated()), id: \.offset) { i, r in
                    let fs = l.moverFont
                    let tint: Color = switch r.tint { case .sign: sc(r.sign); case .accent: p.acc; case .dim: p.bar }
                    let a = 0.4 + Double(i) * 0.08, k = rowIn(i)
                    let grow = !animating ? 1 : style == .typewriter ? Self.ease(win(a, a + 0.2)) : style == .scan ? 1 : k
                    HStack(spacing: fs * 0.6) {
                        Text(tx(r.symbol, a, a + 0.06)).fontWeight(.medium).foregroundStyle(r.tint == .accent ? p.acc : p.fg).frame(width: fs * 4.4, alignment: .leading)
                        GeometryReader { g in
                            Rectangle().fill(tint).frame(width: max(fs * 0.3, g.size.width * r.fraction) * grow, height: fs * 0.62)
                                .frame(maxHeight: .infinity)
                        }
                        if !r.extra.isEmpty { Text(tx(r.extra, a + 0.1, a + 0.2, count: true)).font(Theme.mono(fs * 0.7)).foregroundStyle(p.dim) }
                        Text(tx(r.value, a + 0.06, a + 0.2, count: true)).foregroundStyle(sc(r.sign)).frame(minWidth: fs * 4.6, alignment: .trailing)
                    }
                    .opacity(k).offset(x: (1 - k) * 40)
                    .font(Theme.mono(fs)).lineLimit(1)
                    .frame(height: l.moverRow)
                    .overlay(alignment: .bottom) { if !m.barsTitle.isEmpty { Rectangle().fill(p.border).frame(height: 1) } }
                }
            }
        }
    }

    @ViewBuilder private var classicContent: some View {
        switch m.format {
        case .landscape:
            HStack(alignment: .top, spacing: l.gap) {
                VStack(alignment: .leading, spacing: l.gap) {
                    hero
                    Spacer(minLength: 0)
                    lists
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
                chart.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: (CGFloat(m.format.size.w) - 2 * l.pad - l.gap) * 1.2 / 2.2)
            }
        default:
            VStack(alignment: .leading, spacing: l.gap) {
                hero
                chart.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(-1)
                lists
            }
        }
    }

    private func caps(_ s: String) -> some View {
        Text(s).font(Theme.mono(l.label)).tracking(l.label * 0.14).foregroundStyle(p.dim).lineLimit(1)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Count up: the numbers tick to their value.
            if let v = m.value {
                Text(tx(v, 0.05, 0.72, count: true)).font(Theme.mono(l.heroValue, .medium)).tracking(-l.heroValue * 0.02).foregroundStyle(p.fg).lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.trailing, l.heroValue * 0.08)
            }
            if let pct = m.pct {
                let s = m.value == nil ? l.heroPct : l.pctWithValue
                // Trailing room: with negative tracking the "%" glyph overhangs its box and was clipped.
                Text(tx(pct, 0.08, 0.72, count: true)).font(Theme.mono(s, .medium)).tracking(-s * 0.03).foregroundStyle(sc(m.pctSign)).lineLimit(1).minimumScaleFactor(0.4)
                    .padding(.trailing, s * 0.12)
            }
            if let pnl = m.pnl {
                Text(tx(pnl, 0.3, 0.72, count: true)).font(Theme.mono((l.pctWithValue * 0.55).rounded())).foregroundStyle(sc(m.pnlSign)).lineLimit(1)
            }
            if let sub = m.sub {
                Text(tx(sub, 0.34, 0.46)).font(Theme.mono((l.pctWithValue * 0.55).rounded())).foregroundStyle(p.dim).lineLimit(1)
            }
        }
        .opacity(style == .countUp && animating ? min(1, progress * 6) : 1)
    }

    @ViewBuilder private var chart: some View {
        if let rows = m.chart {
            Canvas { ctx, size in
                // Shrink to fit when other sections leave less room than the design size.
                let fs = min(l.chartFont, size.height / CGFloat(max(rows.count, 1)))
                let top = max(0, (size.height - CGFloat(rows.count) * fs) / 2)
                for (i, r) in rows.enumerated() {
                    let k = style == .typewriter ? win(0.45, 0.8) : style == .scan ? 1 : e
                    let shown = animating ? String(r.prefix(Int((Double(r.count) * k).rounded(.up)))) : r
                    ctx.draw(Text(shown).font(Theme.mono(fs)).foregroundColor(sc(m.pctSign)), at: CGPoint(x: 0, y: top + CGFloat(i) * fs + fs / 2), anchor: .leading)
                }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var lists: some View {
        listsBody
    }

    @ViewBuilder private var listsBody: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let movers = m.movers {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { caps(m.moversTitle); Spacer(); caps(m.moversSub) }
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 2) }
                    ForEach(Array(movers.enumerated()), id: \.offset) { i, r in
                        let fs = l.moverFont
                        let a = 0.4 + Double(i) * 0.08, k = rowIn(i)
                        HStack(spacing: 0) {
                            Text(tx(r.rank, a, a + 0.04)).foregroundStyle(p.dim).frame(width: fs * 2.4, alignment: .leading)
                            Text(tx(r.symbol, a + 0.03, a + 0.08)).fontWeight(.medium).foregroundStyle(p.fg).frame(width: fs * 4.4, alignment: .leading)
                            Text(tx(r.bar, a + 0.06, a + 0.14)).foregroundStyle(sc(r.sign)).frame(maxWidth: .infinity, alignment: .leading).clipped()
                            if !r.extra.isEmpty { Text(tx(r.extra, a + 0.08, a + 0.16)).font(Theme.mono(fs * 0.7)).foregroundStyle(p.dim).padding(.leading, fs * 0.6) }
                            Text(tx(r.main, a + 0.06, a + 0.2, count: true)).foregroundStyle(sc(r.sign)).frame(minWidth: fs * 5.6, alignment: .trailing)
                        }
                        .opacity(k).offset(x: (1 - k) * 40)
                        .font(Theme.mono(fs)).lineLimit(1)
                        .frame(height: l.moverRow)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
                    }
                }
            }
            if let alloc = m.alloc {
                VStack(alignment: .leading, spacing: 8) {
                    caps(m.allocTitle).padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 2) }
                    ForEach(Array(alloc.enumerated()), id: \.offset) { i, a in
                        let fs = (l.moverFont * 0.8).rounded()
                        let w0 = 0.5 + Double(i) * 0.06, k = rowIn(i + 1)
                        let grow = !animating ? 1 : style == .typewriter ? Self.ease(win(w0, w0 + 0.2)) : style == .scan ? 1 : k
                        HStack(spacing: 0) {
                            Text(a.symbol).foregroundStyle(p.fg).frame(width: fs * 4.4, alignment: .leading)
                            if let fr = a.fraction {
                                // Across the row: the share of the whole, not a fixed-length string.
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(p.border)
                                        Rectangle().fill(p.bar).frame(width: g.size.width * min(1, max(0, fr)) * grow)
                                    }
                                    .frame(height: fs * 0.62).frame(maxHeight: .infinity)
                                }
                            } else {
                                Text(a.bar).foregroundStyle(p.bar).frame(maxWidth: .infinity, alignment: .leading).clipped()
                            }
                            Text(tx(a.pct, w0, w0 + 0.2, count: true)).foregroundStyle(p.dim).frame(width: fs * 4, alignment: .trailing)
                        }
                        .font(Theme.mono(fs)).lineLimit(1)
                        .opacity(k).offset(x: (1 - k) * 40)
                    }
                }
            }
        }
    }
}


// MARK: - Effects (design §16): drawn over the finished card, content untouched.

/// Glow under the content (glow, and softer for crt).
public struct ShareGlow: ViewModifier {
    public init(effect: ShareEffect, color: Color) { self.effect = effect; self.color = color }
    let effect: ShareEffect
    let color: Color
    public func body(content: Content) -> some View {
        switch effect {
        case .glow: content.background(content.blur(radius: 5).opacity(0.9)).shadow(color: color.opacity(0.3), radius: 10)
        case .crt: content.background(content.blur(radius: 3).opacity(0.6))
        case .glitch:
            content
                .background(content.colorMultiply(Color(red: 1, green: 0.25, blue: 0.25)).offset(x: 2).blendMode(.plusLighter))
                .background(content.colorMultiply(Color(red: 0.2, green: 1, blue: 0.9)).offset(x: -2).blendMode(.plusLighter))
        default: content
        }
    }
}

/// Scanlines, dither dots, CRT lines + vignette. Pure drawing: identical in preview and export.
public struct ShareEffectLayer: View {
    public init(effect: ShareEffect, light: Bool) { self.effect = effect; self.light = light }
    let effect: ShareEffect
    let light: Bool

    public var body: some View {
        let ink = light ? Color.black : Color.black
        switch effect {
        case .none, .glow, .glitch:
            Color.clear
        case .scanlines:
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.5)), with: .color(ink.opacity(light ? 0.07 : 0.32))); y += 4 }
            }
            .allowsHitTesting(false)
        case .dither:
            Canvas { ctx, size in
                // An ordered 2×2 dot pattern, light enough to read as texture.
                var y: CGFloat = 0, row = 0
                while y < size.height {
                    var x: CGFloat = row % 2 == 0 ? 0 : 2
                    while x < size.width { ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color((light ? Color.black : Color.white).opacity(light ? 0.10 : 0.07))); x += 4 }
                    y += 2; row += 1
                }
            }
            .allowsHitTesting(false)
        case .crt:
            ZStack {
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(ink.opacity(light ? 0.06 : 0.28))); y += 3 }
                }
                RadialGradient(colors: [.clear, .black.opacity(light ? 0.18 : 0.55)], center: .center, startRadius: 220, endRadius: 820)
            }
            .allowsHitTesting(false)
        }
    }
}


/// Small seeded PRNG (SplitMix64): repeatable glitch frames.
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
}
