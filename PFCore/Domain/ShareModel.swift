import Foundation

public enum SharePrivacy: String, Codable, CaseIterable, Sendable {
    case `public`, value, custom
    public var label: String { self == .value ? "value visible" : rawValue }
}

public enum ShareField: String, Codable, CaseIterable, Sendable {
    case name, value, pct, pnl, chart, movers, alloc, posv, avg

    public var label: String {
        switch self {
        case .name: "portfolio name"; case .value: "portfolio value"; case .pct: "percentage change"; case .pnl: "absolute P&L"
        case .chart: "performance chart"; case .movers: "top movers"; case .alloc: "asset allocation"
        case .posv: "position values"; case .avg: "average entries"
        }
    }
    /// Reveals holdings-level data.
    public var isSensitive: Bool { [.pnl, .posv, .avg].contains(self) }
    /// Reveals portfolio size or composition but not holdings.
    public var isSemiSensitive: Bool { [.value, .alloc, .name].contains(self) }
}

public enum ShareFormat: String, Codable, CaseIterable, Sendable {
    case square, landscape, portrait, story
    /// Formats offered per platform: the Mac card editor, the iPhone share screen (1:1, 9:16).
    public static let mac: [ShareFormat] = [.square, .landscape, .portrait]
    public static let phone: [ShareFormat] = [.square, .story]
    public var size: (w: Int, h: Int) {
        switch self { case .square: (1080, 1080); case .landscape: (1200, 675); case .portrait: (1080, 1350); case .story: (1080, 1920) }
    }
    public var chartCols: Int { switch self { case .square: 64; case .landscape: 46; case .portrait: 64; case .story: 64 } }
    public var chartRows: Int { switch self { case .square: 11; case .landscape: 16; case .portrait: 18; case .story: 26 } }
}

public enum ShareTheme: String, Codable, CaseIterable, Sendable { case terminal, monochrome, phosphor }

public enum MoverType: String, Codable, CaseIterable, Sendable { case gainers, impact }

public struct ShareConfig: Codable, Equatable, Sendable {
    public init(period: ChartRange = .h24, privacy: SharePrivacy = .public, custom: Set<ShareField> = [.pct, .chart, .movers], moverCount: Int = 3, moverType: MoverType = .gainers, format: ShareFormat = .square, theme: ShareTheme = .terminal, brand: Bool = true, source: String? = nil) { self.period = period; self.privacy = privacy; self.custom = custom; self.moverCount = moverCount; self.moverType = moverType; self.format = format; self.theme = theme; self.brand = brand; self.source = source }
    public static let periods: [ChartRange] = [.h24, .d7, .d30, .ytd, .all]

    public var period: ChartRange = .h24
    public var privacy: SharePrivacy = .public
    public var custom: Set<ShareField> = [.pct, .chart, .movers]
    public var moverCount: Int = 3
    public var moverType: MoverType = .gainers
    public var format: ShareFormat = .square
    public var theme: ShareTheme = .terminal
    public var brand: Bool = true
    /// Portfolio to render: a portfolio UUID string or "all"; nil follows the active context.
    public var source: String?

    /// Fields permitted by the privacy level. Sensitive fields exist only in `custom`, opt-in.
    public var fields: Set<ShareField> {
        switch privacy {
        case .public: [.pct, .chart, .movers]
        case .value: [.value, .pct, .chart, .movers]
        case .custom: custom
        }
    }

    public enum Level: Sendable { case safe, semi, sensitive }
    public var level: Level {
        let f = fields
        if f.contains(where: \.isSensitive) { return .sensitive }
        if f.contains(where: \.isSemiSensitive) { return .semi }
        return .safe
    }

    /// Settings safe to remember for quick share: never persist a sensitive custom set as the default.
    public var safeForReuse: ShareConfig {
        var c = self
        if c.level == .sensitive { c.privacy = .public; c.custom = [.pct, .chart, .movers] }
        return c
    }

    public mutating func apply(_ o: ShareOverrides) {
        if let p = o.period { period = p }
        if let p = o.privacy { privacy = p }
        if let f = o.format { format = f }
        if let t = o.theme { theme = t }
    }

    public var summary: String { "\(period.rawValue) · \(privacy.label) · \(format.rawValue) · \(theme.rawValue)" }
}

/// Everything the card may draw. Built by `ShareCardBuilder`, which only ever copies
/// permitted fields in: hidden data is absent from the model, not merely not drawn.
public struct ShareCardModel: Equatable, Sendable {
    public init(format: ShareFormat, theme: ShareTheme, title: String, date: String, value: String? = nil, pct: String? = nil, pctSign: Int, pnl: String? = nil, pnlSign: Int, sub: String? = nil, chart: [String]? = nil, moversTitle: String, moversSub: String, movers: [MoverRow]? = nil, alloc: [AllocRow]? = nil, brand: Bool) { self.format = format; self.theme = theme; self.title = title; self.date = date; self.value = value; self.pct = pct; self.pctSign = pctSign; self.pnl = pnl; self.pnlSign = pnlSign; self.sub = sub; self.chart = chart; self.moversTitle = moversTitle; self.moversSub = moversSub; self.movers = movers; self.alloc = alloc; self.brand = brand }
    public struct MoverRow: Equatable, Sendable {
        public let rank, symbol, bar, main, extra: String; public let sign: Int
        public init(rank: String, symbol: String, bar: String, main: String, extra: String, sign: Int) {
            self.rank = rank; self.symbol = symbol; self.bar = bar; self.main = main; self.extra = extra; self.sign = sign
        }
    }
    public struct AllocRow: Equatable, Sendable {
        public let symbol, bar, pct: String
        public init(symbol: String, bar: String, pct: String) { self.symbol = symbol; self.bar = bar; self.pct = pct }
    }

    public let format: ShareFormat
    public let theme: ShareTheme
    public let title: String
    public let date: String
    public let value: String?
    public let pct: String?
    public let pctSign: Int
    public let pnl: String?
    public let pnlSign: Int
    public let sub: String?
    public let chart: [String]?
    public let moversTitle: String
    public let moversSub: String
    public let movers: [MoverRow]?
    public let alloc: [AllocRow]?
    public let brand: Bool

    /// Every string that ends up in the bitmap (for privacy tests).
    public var allText: [String] {
        var t = [title, date, moversTitle, moversSub]
        t += [value, pct, pnl, sub].compactMap { $0 }
        t += chart ?? []
        t += (movers ?? []).flatMap { [$0.rank, $0.symbol, $0.bar, $0.main, $0.extra] }
        t += (alloc ?? []).flatMap { [$0.symbol, $0.bar, $0.pct] }
        return t
    }
}

public enum ShareCardBuilder {
    public static func periodLabel(_ p: ChartRange) -> String {
        switch p {
        case .h24, .d1: "today"; case .d7, .w1: "past 7 days"; case .d30, .m1: "past 30 days"
        case .ytd: "year to date"; case .all: "all time"; default: p.rawValue.lowercased()
        }
    }

    public static func build(
        config: ShareConfig, summary: PortfolioSummary, performance: PeriodPerformance?,
        history: [Double], movers: [Mover], now: Date, fmt: Fmt, contextName: String = "PORTFOLIO"
    ) -> ShareCardModel {
        let f = config.fields
        let sign: (Double) -> Int = { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
        let pp = performance?.percent
        let net = performance?.absolute.double ?? 0
        let imp = config.moverType == .impact

        var chart: [String]? = nil
        if f.contains(.chart), history.count >= 2 {
            let v = AsciiChart.resample(history, to: config.format.chartCols + 1)
            chart = AsciiChart.render(v, height: config.format.chartRows, style: .line) { _ in "" }.map(\.plot)
        }

        var moverRows: [ShareCardModel.MoverRow]? = nil
        if f.contains(.movers) {
            let items = movers.filter { imp ? $0.impact != nil : $0.changePct != nil }
            let top = items.sorted { imp ? $0.impact!.double > $1.impact!.double : $0.changePct! > $1.changePct! }.prefix(config.moverCount)
            let mx = top.map { abs($0.impact?.double ?? 0) }.max() ?? 1
            moverRows = top.enumerated().map { i, m in
                var extra: [String] = []
                if f.contains(.posv) { extra.append(fmt.compact(m.valuation.value)) }
                if f.contains(.avg), let a = m.valuation.position.averageEntry { extra.append("avg " + fmt.price(a)) }
                let a = m.impact?.double ?? 0
                return .init(
                    rank: String(format: "%02d", i + 1), symbol: m.valuation.asset.symbol,
                    bar: imp ? " " + String(repeating: "█", count: max(1, Int((abs(a) / (mx > 0 ? mx : 1) * 9).rounded()))) : "",
                    main: imp ? (net != 0 ? fmt.num(a / net * 100, 0) + "%" : "—") : fmt.pct(m.changePct),
                    extra: extra.joined(separator: "  "), sign: sign(imp ? a : m.changePct ?? 0))
            }
        }

        var alloc: [ShareCardModel.AllocRow]? = nil
        if f.contains(.alloc) {
            alloc = summary.positions.compactMap { v in
                v.allocation.map { .init(symbol: v.asset.symbol, bar: AsciiChart.bar($0 / 100, width: 16), pct: fmt.num($0, 1) + "%") }
            }
        }

        return ShareCardModel(
            format: config.format, theme: config.theme,
            title: (f.contains(.name) ? contextName : "PORTFOLIO") + " / " + config.period.rawValue,
            date: DateFmt.card(now),
            value: f.contains(.value) ? fmt.money(summary.totalValue) : nil,
            pct: f.contains(.pct) ? pp.map { ($0 >= 0 ? "▲ " : "▼ ") + fmt.pct($0) } ?? "—" : nil,
            pctSign: sign(pp ?? 0),
            pnl: f.contains(.pnl) ? fmt.signed(performance?.absolute) + " " + periodLabel(config.period) : nil,
            pnlSign: sign(net),
            sub: f.contains(.pnl) ? nil : periodLabel(config.period),
            chart: chart,
            moversTitle: (imp ? "BIGGEST IMPACT" : "TOP GAINERS") + " / " + config.period.rawValue,
            moversSub: imp ? "share of move" : "change",
            movers: moverRows, alloc: alloc, brand: config.brand)
    }

    /// Privacy check lists shown next to the preview.
    public static func privacyCheck(_ c: ShareConfig) -> (visible: [String], hidden: [String]) {
        let f = c.fields
        let visible = ShareField.allCases.filter { f.contains($0) }.map { "✓ " + ($0 == .chart ? c.period.rawValue.lowercased() + " chart" : $0.label) }
        let hidden = [ShareField.name, .value, .pnl, .alloc, .posv, .avg].filter { !f.contains($0) }.map { "✓ " + $0.label }
            + ["✓ holdings / amounts", "✓ cost basis", "✓ transaction history", "✓ wallet & exchange info"]
        return (visible, hidden)
    }
}
