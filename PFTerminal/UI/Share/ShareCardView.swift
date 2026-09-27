import AppKit
import SwiftUI

/// Social card. Separately composed per format; renders only what `ShareCardModel` contains.
struct ShareCardView: View {
    let m: ShareCardModel

    struct Palette { let bg, fg, dim, border, pos, neg, bar: Color }
    struct Layout {
        let pad, gap, chartFont, heroValue, heroPct, pctWithValue, moverFont, moverRow, label: CGFloat
    }

    static func palette(_ t: ShareTheme) -> Palette {
        switch t {
        case .terminal: .init(bg: Color(hex: 0x0e0f11), fg: Color(hex: 0xe4e5e7), dim: Color(hex: 0x7a7e85), border: Color(hex: 0x232529), pos: Theme.pos, neg: Theme.neg, bar: Color(hex: 0x8b8f96))
        case .monochrome: .init(bg: Color(hex: 0xeeeeea), fg: Color(hex: 0x141414), dim: Color(hex: 0x6b6b66), border: Color(hex: 0xcfcfc9), pos: Color(hex: 0x141414), neg: Color(hex: 0x141414), bar: Color(hex: 0x141414))
        case .phosphor: .init(bg: Color(hex: 0x050b07), fg: Color(hex: 0xa6f0b8), dim: Color(hex: 0x5a9a6a), border: Color(hex: 0x14301d), pos: Color(hex: 0xa6f0b8), neg: Color(hex: 0xf0c27a), bar: Color(hex: 0x5a9a6a))
        }
    }

    static func layout(_ f: ShareFormat) -> Layout {
        switch f {
        case .square: .init(pad: 72, gap: 44, chartFont: 22, heroValue: 96, heroPct: 150, pctWithValue: 44, moverFont: 28, moverRow: 48, label: 22)
        case .landscape: .init(pad: 56, gap: 36, chartFont: 18, heroValue: 68, heroPct: 112, pctWithValue: 34, moverFont: 22, moverRow: 36, label: 17)
        case .portrait: .init(pad: 80, gap: 56, chartFont: 22, heroValue: 104, heroPct: 168, pctWithValue: 48, moverFont: 30, moverRow: 58, label: 24)
        }
    }

    private var p: Palette { Self.palette(m.theme) }
    private var l: Layout { Self.layout(m.format) }
    private func sc(_ s: Int) -> Color { s > 0 ? p.pos : s < 0 ? p.neg : p.dim }

    var body: some View {
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

/// Dedicated export pipeline: renders the card offscreen at its exact pixel size,
/// independent of window size or display scale.
@MainActor
enum ShareRenderer {
    static func image(_ m: ShareCardModel) -> NSImage? {
        let r = ImageRenderer(content: ShareCardView(m: m))
        r.scale = 1
        r.isOpaque = true
        guard let cg = r.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func png(_ m: ShareCardModel) -> Data? {
        let r = ImageRenderer(content: ShareCardView(m: m))
        r.scale = 1
        r.isOpaque = true
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ img: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(tiff, forType: .tiff)
        } else {
            pb.writeObjects([img])
        }
    }

    static func save(_ m: ShareCardModel, suggestedName: String, done: @escaping (URL?) -> Void) {
        guard let data = png(m) else { done(nil); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { done(nil); return }
        do { try data.write(to: url, options: .atomic); done(url) } catch { done(nil) }
    }

    private static var pickerDelegate: PickerDelegate?

    static func presentPicker(_ m: ShareCardModel, from view: NSView, chosen: @escaping (String) -> Void) {
        guard let data = png(m) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-portfolio-card.png")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        let picker = NSSharingServicePicker(items: [url])
        let d = PickerDelegate(chosen)
        pickerDelegate = d
        picker.delegate = d
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    final class PickerDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        let chosen: (String) -> Void
        init(_ c: @escaping (String) -> Void) { chosen = c }
        func sharingServicePicker(_ p: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if let s = service { chosen(s.title) }
        }
    }
}

/// Captures an NSView for anchoring the native share picker.
struct ViewAnchor: NSViewRepresentable {
    let set: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { set(v) }; return v }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
