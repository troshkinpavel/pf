import PFCore
import PFCoreUI
import SwiftUI

/// Grid-template-columns for one row: fixed widths plus fractional (`fr`) columns.
struct Columns: Layout {
    enum Col { case fixed(CGFloat), fr(CGFloat) }
    let cols: [Col]
    var spacing: CGFloat = 0

    init(_ cols: [Col], spacing: CGFloat = 0) { self.cols = cols; self.spacing = spacing }

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let fixed = cols.reduce(CGFloat(0)) { if case let .fixed(w) = $1 { return $0 + w }; return $0 } + spacing * CGFloat(max(0, cols.count - 1))
        let frs = cols.reduce(CGFloat(0)) { if case let .fr(f) = $1 { return $0 + f }; return $0 }
        let rest = max(0, total - fixed)
        return cols.map { if case let .fixed(w) = $0 { return w }; if case let .fr(f) = $0 { return frs > 0 ? rest * f / frs : 0 }; return 0 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let minW = cols.reduce(CGFloat(0)) { if case let .fixed(w) = $1 { return $0 + w }; return $0 }
        let total = proposal.width ?? minW
        let ws = widths(total)
        var h: CGFloat = 0
        for (i, s) in subviews.enumerated() where i < ws.count {
            h = max(h, s.sizeThatFits(ProposedViewSize(width: ws[i], height: proposal.height)).height)
        }
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ws = widths(bounds.width)
        var x = bounds.minX
        for (i, s) in subviews.enumerated() {
            guard i < ws.count else { s.place(at: .zero, proposal: .zero); continue }
            s.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: ws[i], height: bounds.height))
            x += ws[i] + spacing
        }
    }
}

/// Right-aligned table cell text.
struct Cell: View {
    let s: String
    var c: Color = Theme.text
    var align: Alignment = .trailing
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    init(_ s: String, _ c: Color = Theme.text, align: Alignment = .trailing, size: CGFloat = 12, weight: Font.Weight = .regular) {
        self.s = s; self.c = c; self.align = align; self.size = size; self.weight = weight
    }
    var body: some View {
        Text(s).font(Theme.mono(size, weight)).foregroundStyle(c).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: align)
    }
}

/// Table header cell: 10.5 caps, dim.
struct HeadCell: View {
    let s: String
    var align: Alignment = .trailing
    var c: Color = Theme.t3
    init(_ s: String, align: Alignment = .trailing, c: Color = Theme.t3) { self.s = s; self.align = align; self.c = c }
    var body: some View {
        Text(s).font(Theme.mono(10.5)).tracking(0.63).foregroundStyle(c).lineLimit(1).frame(maxWidth: .infinity, alignment: align)
    }
}

/// Selectable table row with hover/selected backgrounds and a hairline bottom border.
struct TableRow<Content: View>: View {
    let selected: Bool
    var height: CGFloat = 26
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(height: height)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowBorder).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { onOpen() }
            .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }
}
