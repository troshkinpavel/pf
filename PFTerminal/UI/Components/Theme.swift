import AppKit
import SwiftUI

/// AppKit-only type metrics (tokens live in Shared/PFTheme.swift, shared with widgets).
extension Theme {
    static func nsMono(_ size: CGFloat) -> NSFont {
        if hasGeist, let f = NSFont(name: "GeistMono-Regular", size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Advance width of one monospace cell.
    static func cell(_ size: CGFloat = 12) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: nsMono(size)]).width
    }
}

// MARK: - Text

/// Terminal text: monospace, tabular, single line.
struct TT: View {
    let s: String
    var size: CGFloat = 12
    var color: Color = Theme.text
    var weight: Font.Weight = .regular
    var tracking: CGFloat = 0

    init(_ s: String, _ size: CGFloat = 12, _ color: Color = Theme.text, weight: Font.Weight = .regular, tracking: CGFloat = 0) {
        self.s = s; self.size = size; self.color = color; self.weight = weight; self.tracking = tracking
    }

    var body: some View {
        Text(s).font(Theme.mono(size, weight)).foregroundStyle(color).tracking(tracking).lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 10.5 caps label, +.08em tracking.
struct CapsLabel: View {
    let s: String
    var color: Color = Theme.t3
    init(_ s: String, color: Color = Theme.t3) { self.s = s; self.color = color }
    var body: some View { TT(s, 10.5, color, tracking: 0.84) }
}

// MARK: - Panel

/// 1px hairline box with the title sitting on the border: ┌─ TITLE ──┐
struct Panel<Content: View>: View {
    let title: String
    var padding = EdgeInsets(top: 16, leading: 14, bottom: 12, trailing: 14)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if !title.isEmpty {
                    TT(title, 10.5, Theme.t2, tracking: 0.84)
                        .padding(.horizontal, 6)
                        .frame(height: 14)
                        .background(Theme.bg)
                        .offset(x: 10, y: -7)
                }
            }
    }
}

// MARK: - Controls

struct TabItem: Identifiable { let id: String; let label: String }

/// Segmented terminal tabs: active = raised box, inactive = dim text.
struct Tabs: View {
    let items: [TabItem]
    let selected: String
    var hPad: CGFloat = 8
    var vPad: CGFloat = 2
    let pick: (String) -> Void

    init(_ labels: [String], selected: String, hPad: CGFloat = 8, vPad: CGFloat = 2, pick: @escaping (String) -> Void) {
        items = labels.map { TabItem(id: $0, label: $0) }
        self.selected = selected; self.hPad = hPad; self.vPad = vPad; self.pick = pick
    }
    init(items: [TabItem], selected: String, hPad: CGFloat = 8, vPad: CGFloat = 2, pick: @escaping (String) -> Void) {
        self.items = items; self.selected = selected; self.hPad = hPad; self.vPad = vPad; self.pick = pick
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { t in
                let on = t.id == selected
                TermButton(action: { pick(t.id) }) {
                    TT(t.label, 11, on ? Theme.t1 : Theme.t3)
                        .padding(.horizontal, hPad).padding(.vertical, vPad)
                        .background(on ? Theme.tabBg : .clear)
                        .overlay(Rectangle().strokeBorder(on ? Theme.overlayBorder : .clear, lineWidth: 1))
                }
            }
        }
        .fixedSize()
    }
}

/// Keyboard shortcut chip.
struct Kbd: View {
    let k: String
    init(_ k: String) { self.k = k }
    var body: some View {
        TT(k, 10, Theme.text)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(Rectangle().strokeBorder(Theme.kbdBorder, lineWidth: 1))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.kbdBottom).frame(height: 1) }
    }
}

/// Plain button with hover feedback and no platform chrome.
struct TermButton<Label: View>: View {
    let action: () -> Void
    var hoverBg: Color? = nil
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label.contentShape(Rectangle())
                .background(hovering ? (hoverBg ?? .clear) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .brightness(hovering && hoverBg == nil ? 0.12 : 0)
        .accessibilityAddTraits(.isButton)
    }
}

/// `[ label ]` action, primary in accent.
struct BracketButton: View {
    let label: String
    var color: Color = Theme.text
    let action: () -> Void
    init(_ label: String, color: Color = Theme.text, action: @escaping () -> Void) { self.label = label; self.color = color; self.action = action }
    var body: some View {
        TermButton(action: action, hoverBg: Theme.tabBg) {
            TT("[ \(label) ]", 12, color).padding(.horizontal, 6).padding(.vertical, 4)
        }
    }
}

struct Hairline: View {
    var color: Color = Theme.border
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// Key/value line used in POSITION, MARKET, RESULT panels.
struct KV: View {
    let k: String
    let v: String
    var c: Color = Theme.t1
    var size: CGFloat = 12
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TT(k, 12, Theme.t3)
            Spacer(minLength: 8)
            TT(v, size, c)
        }
    }
}

/// Selection marker column: amber › on the selected row.
struct RowMark: View {
    let on: Bool
    var body: some View { TT(on ? "›" : " ", 12, Theme.acc).frame(width: 22) }
}
