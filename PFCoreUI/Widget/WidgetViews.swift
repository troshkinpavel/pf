import PFCore
import SwiftUI
import WidgetKit

// PF Terminal widget layouts. Shared (not widget-only) so the app can render them offscreen
// for screenshots and so a future iOS widget target can reuse them unchanged.

// MARK: - Configuration values (AppEnum conformance lives in the widget target)

// Layout options. Each widget extension declares its own App Intents enums (AppEnum must live
// in the widget's module) and maps them here by raw value.
public enum WidgetDisplayOption: String, CaseIterable, Sendable { case valueAnd24h, performanceOnly, valueOnly }
public enum WidgetValueOption: String, CaseIterable, Sendable { case visible, hidden }
public enum WidgetMoversOption: String, CaseIterable, Sendable { case gainers, impact }

/// Immutable per-entry options derived from the intent.
public struct WidgetOptions: Hashable {
    public var display: WidgetDisplayOption = .valueAnd24h
    public var hideValue = false
    public var movers: WidgetMoversOption = .gainers

    public init() {}
    public init(display: WidgetDisplayOption, privacy: WidgetValueOption, movers: WidgetMoversOption) {
        self.display = display; hideValue = privacy == .hidden; self.movers = movers
    }
}

// MARK: - Timeline

public struct PortfolioEntry: TimelineEntry {
    public init(date: Date, snapshot: WidgetPortfolioSnapshot? = nil, options: WidgetOptions) { self.date = date; self.snapshot = snapshot; self.options = options }
    public let date: Date
    public let snapshot: WidgetPortfolioSnapshot?
    public let options: WidgetOptions
}


/// Routes an entry to the family layout. Rendering is read → format → draw: no market data,
/// no portfolio maths, no network here.
public struct PortfolioWidgetView: View {
    public init(entry: PortfolioEntry) { self.entry = entry }
    public let entry: PortfolioEntry
    @Environment(\.widgetFamily) private var family

    public var body: some View {
        Group {
            if let s = entry.snapshot, s.hasPortfolio {
                let m = WidgetModel(s, entry.options, now: entry.date)
                switch family {
                case .systemSmall: SmallWidget(m: m)
                case .systemLarge: LargeWidget(m: m)
                default: MediumWidget(m: m)
                }
            } else {
                EmptyWidget(hasSnapshot: entry.snapshot != nil)
            }
        }
        .font(Theme.mono(11))
        .foregroundStyle(Theme.text)
        .widgetURL(PFLink.portfolio(context: entry.snapshot?.contextID))
    }
}

/// Everything a layout needs, resolved once per entry. Hidden values are nil, not transparent:
/// the view hierarchy never receives them.
public struct WidgetModel {
    public let s: WidgetPortfolioSnapshot
    public let f: Fmt
    public let freshness: WidgetFreshness
    public let value: Decimal?          // nil when hidden by app privacy, widget privacy, or display mode
    public let showValue: Bool
    public let showPerformance: Bool
    public let movers: [WidgetMover]
    public let rows: [WidgetPosition]

    public init(_ s: WidgetPortfolioSnapshot, _ o: WidgetOptions, now: Date) {
        self.s = s
        f = s.fmt
        freshness = .evaluate(s, now: now)
        let valueAllowed = s.showsValuesOnHomeScreen && !o.hideValue
        showValue = valueAllowed && o.display != .performanceOnly
        // "value only" with the value hidden would leave nothing: fall back to performance.
        showPerformance = o.display != .valueOnly || !showValue
        value = showValue ? s.portfolioValue : nil
        movers = o.movers == .impact ? s.impact : s.gainers
        let order = movers.map(\.id)
        rows = o.movers == .impact
            ? s.positions.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
            : s.positions.sorted { ($0.change24h ?? -.infinity) > ($1.change24h ?? -.infinity) }
        hideAmounts = !valueAllowed
        #if os(iOS)
        // The widget asks for its value but PF › Settings › Widgets keeps amounts out of the data.
        valueBlockedByApp = !o.hideValue && o.display != .performanceOnly && !s.showsValuesOnHomeScreen
        #else
        valueBlockedByApp = false
        #endif
    }

    public let valueBlockedByApp: Bool
    /// Caption under a performance-only headline: explains why no value is shown when that is
    /// the app's privacy setting rather than the widget's.
    public func perfCaption(_ normal: String) -> String { valueBlockedByApp ? "VALUES OFF IN PF" : normal }

    public let hideAmounts: Bool
    public var pct: String { f.pct(s.dailyChangePercent) }
    public var pctColor: Color { Theme.signColor(s.dailyChangePercent) }
    public var arrow: String { (s.dailyChangePercent ?? 0) >= 0 ? "▲" : "▼" }
    public var chartColor: Color { Theme.signColor(s.performanceChangePercent ?? s.dailyChangePercent) }
    public var chart: [Double] { s.performance.map(\.normalizedValue) }
}

// MARK: - Pieces

public struct PFMark: View {
    public init(title: String? = nil) { self.title = title }
    public var title: String? = nil
    public var body: some View {
        HStack(spacing: 0) {
            PFGlyph(size: 10.5, color: Theme.t1)
            Text("_").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.acc).offset(y: 1)
            if let title {
                Text("  / " + title).font(Theme.mono(9.5)).tracking(0.8).foregroundStyle(Theme.t3).lineLimit(1)
            }
        }
    }
}

public struct FreshnessBadge: View {
    public init(f: WidgetFreshness) { self.f = f }
    public let f: WidgetFreshness
    public var body: some View {
        Group {
            switch f {
            case let .fresh(a):
                HStack(spacing: 4) { Text("●").foregroundStyle(Theme.pos); Text(WidgetFreshness.ageLabel(a)).foregroundStyle(Theme.t2) }
            case let .aging(a):
                Text("upd " + WidgetFreshness.ageLabel(a)).foregroundStyle(Theme.t3)
            case let .stale(a):
                Text("STALE · " + WidgetFreshness.ageLabel(a)).foregroundStyle(Theme.neg)
            }
        }
        .font(Theme.mono(9.5))
        .lineLimit(1)
        .fixedSize()
    }
}

private struct Caps: View {
    public let s: String
    public var c: Color = Theme.t3
    public init(_ s: String, _ c: Color = Theme.t3) { self.s = s; self.c = c }
    public var body: some View { Text(s).font(Theme.mono(9.5)).tracking(0.8).foregroundStyle(c).lineLimit(1) }
}

/// Portfolio value that steps down in precision instead of truncating.
private struct ValueText: View {
    public let v: Decimal?
    public let f: Fmt
    public let size: CGFloat
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(f.money(v)).fixedSize()
            Text(f.money(v, 0)).fixedSize()
            Text(f.compact(v)).fixedSize()
        }
        .font(Theme.mono(size, .medium))
        .foregroundStyle(v == nil ? Theme.t3 : Theme.t1)
        .lineLimit(1)
    }
}

private struct MoverChip: View {
    public let m: WidgetMover
    public let f: Fmt
    public var body: some View {
        Link(destination: PFLink.asset(m.id)) {
            HStack(spacing: 6) {
                Text(m.symbol).foregroundStyle(Theme.t1).fontWeight(.medium)
                Text(f.pct(m.changePercent)).foregroundStyle(Theme.signColor(m.changePercent))
            }
            .font(Theme.mono(10.5))
            .lineLimit(1)
            .fixedSize()
        }
    }
}

private struct Chart: View {
    public let m: WidgetModel
    public var body: some View {
        if m.chart.count >= 2 {
            StepLineChart(values: m.chart, color: m.chartColor, cell: 6, levels: 7, lineWidth: 1.25)
        } else {
            Caps("no history yet", Theme.t5).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Small

public struct SmallWidget: View {
    public init(m: WidgetModel) { self.m = m }
    public let m: WidgetModel

    public var body: some View {
        if m.showValue { valueLayout } else { performanceLayout }
    }

    private var valueLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { PFMark(title: m.s.contextLabel); Spacer(minLength: 4); FreshnessBadge(f: m.freshness) }
            Spacer(minLength: 6)
            ValueText(v: m.value, f: m.f, size: 22)
            if m.showPerformance {
                Text(m.pct).font(Theme.mono(13, .medium)).foregroundStyle(m.pctColor).padding(.top, 3)
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline) {
                if m.showPerformance {
                    Caps("24H")
                    Spacer(minLength: 4)
                    Text(m.f.signed(m.s.dailyChangeValue, 0)).font(Theme.mono(10.5)).foregroundStyle(m.pctColor).lineLimit(1)
                } else {
                    Caps("PORTFOLIO")
                    Spacer(minLength: 4)
                    Text(m.f.pct(m.s.unrealizedPnLPercent, 1) + " all").font(Theme.mono(10.5)).foregroundStyle(Theme.signColor(m.s.unrealizedPnLPercent)).lineLimit(1)
                }
            }
        }
    }

    /// Recomposed for privacy: the percentage becomes the hero instead of leaving a hole.
    private var performanceLayout: some View {
        VStack(spacing: 0) {
            HStack { PFMark(title: m.s.contextLabel); Spacer(minLength: 0) }
            Spacer(minLength: 4)
            Text(m.pct).font(Theme.mono(26, .medium)).foregroundStyle(m.pctColor).lineLimit(1).minimumScaleFactor(0.6)
            Text(m.arrow).font(Theme.mono(13)).foregroundStyle(m.pctColor).padding(.top, 2)
            Spacer(minLength: 4)
            HStack { Caps(m.perfCaption("24H"), m.valueBlockedByApp ? Theme.acc : Theme.t3); Spacer(minLength: 4); FreshnessBadge(f: m.freshness) }
        }
    }
}

// MARK: - Medium (flagship)

public struct MediumWidget: View {
    public init(m: WidgetModel) { self.m = m }
    public let m: WidgetModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { PFMark(title: m.s.contextLabel); Spacer(minLength: 6); FreshnessBadge(f: m.freshness) }
            HeadlineRow(m: m, valueSize: 22)
            Chart(m: m).frame(maxHeight: .infinity)
            if !m.movers.isEmpty {
                HStack(spacing: 0) {
                    ForEach(m.movers.prefix(3)) { mv in
                        MoverChip(m: mv, f: m.f).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// Value (or the percentage as hero, in privacy/performance mode) + 24h on the right.
private struct HeadlineRow: View {
    public let m: WidgetModel
    public let valueSize: CGFloat

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if m.showValue {
                ValueText(v: m.value, f: m.f, size: valueSize)
                Spacer(minLength: 6)
                if m.showPerformance { pct24(size: 13) }
                else { Caps("VALUE") }
            } else {
                Text(m.arrow + " " + m.pct).font(Theme.mono(valueSize, .medium)).foregroundStyle(m.pctColor).lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                Caps(m.perfCaption("24H PERFORMANCE"), m.valueBlockedByApp ? Theme.acc : Theme.t3)
            }
        }
    }

    private func pct24(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(m.pct).font(Theme.mono(size, .medium)).foregroundStyle(m.pctColor)
            Text(" / 24H").font(Theme.mono(9.5)).foregroundStyle(Theme.t3)
        }
        .lineLimit(1).fixedSize()
    }
}

// MARK: - Large

public struct LargeWidget: View {
    public init(m: WidgetModel) { self.m = m }
    public let m: WidgetModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { PFMark(title: m.s.contextLabel); Spacer(minLength: 6); FreshnessBadge(f: m.freshness) }
            HeadlineRow(m: m, valueSize: 24)
            if let u = m.s.unrealizedPnLPercent {
                HStack(spacing: 6) {
                    Caps("UNREALIZED")
                    if !m.hideAmounts, let pnl = m.s.unrealizedPnL {
                        Text(m.f.signed(pnl, 0)).font(Theme.mono(10.5)).foregroundStyle(Theme.signColor(pnl))
                    }
                    Text(m.f.pct(u)).font(Theme.mono(10.5)).foregroundStyle(Theme.signColor(u))
                }
                .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Caps(m.s.performanceRange, Theme.t5)
                Chart(m: m).frame(height: 62)
            }
            table
            Spacer(minLength: 0)
            footer
        }
    }

    private var showValueColumn: Bool { !m.hideAmounts }

    private var table: some View {
        VStack(spacing: 0) {
            row(Caps("ASSET"), Caps(m.showValue ? "VALUE" : "WEIGHT"), Caps("24H"), Caps("RETURN"))
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            ForEach(m.rows.prefix(6)) { p in
                Link(destination: PFLink.asset(p.id)) {
                    row(Text(p.symbol).foregroundStyle(Theme.t1).fontWeight(.medium),
                        Text(m.showValue ? m.f.compact(p.value) : p.allocation.map { m.f.num($0, 1) + "%" } ?? "—").foregroundStyle(Theme.t2),
                        Text(m.f.pct(p.change24h)).foregroundStyle(Theme.signColor(p.change24h)),
                        Text(m.f.pct(p.returnPercent, 0)).foregroundStyle(Theme.signColor(p.returnPercent)))
                        .font(Theme.mono(11))
                        .frame(height: 20)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowBorder).frame(height: 1) }
                }
            }
        }
    }

    private func row<A: View, B: View, C: View, D: View>(_ a: A, _ b: B, _ c: C, _ d: D) -> some View {
        HStack(spacing: 0) {
            a.frame(maxWidth: .infinity, alignment: .leading)
            b.frame(width: 84, alignment: .trailing)
            c.frame(width: 72, alignment: .trailing)
            d.frame(width: 66, alignment: .trailing)
        }
        .lineLimit(1)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let b = m.s.best24 {
                Caps("BEST")
                Text(b.symbol).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.t1)
                Text(m.f.pct(b.changePercent)).font(Theme.mono(10.5)).foregroundStyle(Theme.signColor(b.changePercent))
            }
            Spacer(minLength: 6)
            Text("upd " + WidgetFreshness.ageLabel(m.freshness.age)).font(Theme.mono(9.5)).foregroundStyle(m.freshness.isStale ? Theme.neg : Theme.t3)
        }
        .lineLimit(1)
    }
}

// MARK: - Empty

public struct EmptyWidget: View {
    public init(hasSnapshot: Bool) { self.hasSnapshot = hasSnapshot }
    public let hasSnapshot: Bool
    @Environment(\.widgetFamily) private var family

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PFMark()
            Spacer(minLength: 4)
            Text(hasSnapshot ? "NO PORTFOLIO" : "NO DATA YET").font(Theme.mono(family == .systemSmall ? 12 : 14, .medium)).tracking(1).foregroundStyle(Theme.t1)
            Text(hasSnapshot ? "Open PF Terminal\nto add your first position." : "Open PF Terminal\nto sync your portfolio.")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.t3).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text("[ open ]").font(Theme.mono(10.5)).foregroundStyle(Theme.acc)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
