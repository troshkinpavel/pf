import PFCore
import SwiftUI

// App-only shared UI (macOS + iOS apps, not the widgets): one share card design, rendered by
// ShareRenderer (AppKit) on the Mac and ImageRenderer → share sheet on iPhone.

/// Social card. Separately composed per format; renders only what `ShareCardModel` contains.
public struct ShareCardView: View {
    public init(m: ShareCardModel) { self.m = m }
    public let m: ShareCardModel

    public struct Palette { public let bg, fg, dim, border, pos, neg, bar: Color }
    public struct Layout {
        public init(pad: CGFloat, gap: CGFloat, chartFont: CGFloat, heroValue: CGFloat, heroPct: CGFloat, pctWithValue: CGFloat, moverFont: CGFloat, moverRow: CGFloat, label: CGFloat) { self.pad = pad; self.gap = gap; self.chartFont = chartFont; self.heroValue = heroValue; self.heroPct = heroPct; self.pctWithValue = pctWithValue; self.moverFont = moverFont; self.moverRow = moverRow; self.label = label }
        public let pad, gap, chartFont, heroValue, heroPct, pctWithValue, moverFont, moverRow, label: CGFloat
    }

    public static func palette(_ t: ShareTheme) -> Palette {
        switch t {
        case .terminal: .init(bg: Color(hex: 0x0e0f11), fg: Color(hex: 0xe4e5e7), dim: Color(hex: 0x7a7e85), border: Color(hex: 0x232529), pos: Theme.pos, neg: Theme.neg, bar: Color(hex: 0x8b8f96))
        case .monochrome: .init(bg: Color(hex: 0xeeeeea), fg: Color(hex: 0x141414), dim: Color(hex: 0x6b6b66), border: Color(hex: 0xcfcfc9), pos: Color(hex: 0x141414), neg: Color(hex: 0x141414), bar: Color(hex: 0x141414))
        case .phosphor: .init(bg: Color(hex: 0x050b07), fg: Color(hex: 0xa6f0b8), dim: Color(hex: 0x5a9a6a), border: Color(hex: 0x14301d), pos: Color(hex: 0xa6f0b8), neg: Color(hex: 0xf0c27a), bar: Color(hex: 0x5a9a6a))
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
        VStack(alignment: .leading, spacing: l.gap) {
            HStack {
                caps(m.title)
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
        .background(p.bg)
        .overlay(Rectangle().strokeBorder(p.border, lineWidth: 2))
        .clipped()
        .environment(\.colorScheme, m.theme == .monochrome ? .light : .dark)
    }

    @ViewBuilder private var content: some View {
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
            if let v = m.value {
                Text(v).font(Theme.mono(l.heroValue, .medium)).tracking(-l.heroValue * 0.02).foregroundStyle(p.fg).lineLimit(1).minimumScaleFactor(0.5)
            }
            if let pct = m.pct {
                let s = m.value == nil ? l.heroPct : l.pctWithValue
                Text(pct).font(Theme.mono(s, .medium)).tracking(-s * 0.03).foregroundStyle(sc(m.pctSign)).lineLimit(1).minimumScaleFactor(0.4)
            }
            if let pnl = m.pnl {
                Text(pnl).font(Theme.mono((l.pctWithValue * 0.55).rounded())).foregroundStyle(sc(m.pnlSign)).lineLimit(1)
            }
            if let sub = m.sub {
                Text(sub).font(Theme.mono((l.pctWithValue * 0.55).rounded())).foregroundStyle(p.dim).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if let rows = m.chart {
            Canvas { ctx, size in
                // Shrink to fit when other sections leave less room than the design size.
                let fs = min(l.chartFont, size.height / CGFloat(max(rows.count, 1)))
                let top = max(0, (size.height - CGFloat(rows.count) * fs) / 2)
                for (i, r) in rows.enumerated() {
                    ctx.draw(Text(r).font(Theme.mono(fs)).foregroundColor(sc(m.pctSign)), at: CGPoint(x: 0, y: top + CGFloat(i) * fs + fs / 2), anchor: .leading)
                }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var lists: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let movers = m.movers {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { caps(m.moversTitle); Spacer(); caps(m.moversSub) }
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 2) }
                    ForEach(Array(movers.enumerated()), id: \.offset) { _, r in
                        let fs = l.moverFont
                        HStack(spacing: 0) {
                            Text(r.rank).foregroundStyle(p.dim).frame(width: fs * 2.4, alignment: .leading)
                            Text(r.symbol).fontWeight(.medium).foregroundStyle(p.fg).frame(width: fs * 4.4, alignment: .leading)
                            Text(r.bar).foregroundStyle(sc(r.sign)).frame(maxWidth: .infinity, alignment: .leading).clipped()
                            if !r.extra.isEmpty { Text(r.extra).font(Theme.mono(fs * 0.7)).foregroundStyle(p.dim).padding(.leading, fs * 0.6) }
                            Text(r.main).foregroundStyle(sc(r.sign)).frame(minWidth: fs * 5.6, alignment: .trailing)
                        }
                        .font(Theme.mono(fs)).lineLimit(1)
                        .frame(height: l.moverRow)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
                    }
                }
            }
            if let alloc = m.alloc {
                VStack(alignment: .leading, spacing: 8) {
                    caps("ALLOCATION").padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 2) }
                    ForEach(Array(alloc.enumerated()), id: \.offset) { _, a in
                        let fs = (l.moverFont * 0.8).rounded()
                        HStack(spacing: 0) {
                            Text(a.symbol).foregroundStyle(p.fg).frame(width: fs * 4.4, alignment: .leading)
                            Text(a.bar).foregroundStyle(p.bar).frame(maxWidth: .infinity, alignment: .leading).clipped()
                            Text(a.pct).foregroundStyle(p.dim).frame(width: fs * 4, alignment: .trailing)
                        }
                        .font(Theme.mono(fs)).lineLimit(1)
                    }
                }
            }
        }
    }
}
