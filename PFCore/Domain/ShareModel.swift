import Foundation

enum SharePrivacy: String, Codable, CaseIterable, Sendable {
    case `public`, value, custom
    var label: String { self == .value ? "value visible" : rawValue }
}

enum ShareField: String, Codable, CaseIterable, Sendable {
    case name, value, pct, pnl, chart, movers, alloc, posv, avg

    var label: String {
        switch self {
        case .name: "portfolio name"; case .value: "portfolio value"; case .pct: "percentage change"; case .pnl: "absolute P&L"
        case .chart: "performance chart"; case .movers: "top movers"; case .alloc: "asset allocation"
        case .posv: "position values"; case .avg: "average entries"
        }
    }
    /// Reveals holdings-level data.
    var isSensitive: Bool { [.pnl, .posv, .avg].contains(self) }
    /// Reveals portfolio size or composition but not holdings.
    var isSemiSensitive: Bool { [.value, .alloc, .name].contains(self) }
}

enum ShareFormat: String, Codable, CaseIterable, Sendable {
    case square, landscape, portrait
    var size: (w: Int, h: Int) {
        switch self { case .square: (1080, 1080); case .landscape: (1200, 675); case .portrait: (1080, 1350) }
    }
    var chartCols: Int { switch self { case .square: 64; case .landscape: 46; case .portrait: 64 } }
    var chartRows: Int { switch self { case .square: 11; case .landscape: 16; case .portrait: 18 } }
}

enum ShareTheme: String, Codable, CaseIterable, Sendable { case terminal, monochrome, phosphor }

enum MoverType: String, Codable, CaseIterable, Sendable { case gainers, impact }

struct ShareConfig: Codable, Equatable, Sendable {
    static let periods: [ChartRange] = [.h24, .d7, .d30, .ytd, .all]

    var period: ChartRange = .h24
    var privacy: SharePrivacy = .public
    var custom: Set<ShareField> = [.pct, .chart, .movers]
    var moverCount: Int = 3
    var moverType: MoverType = .gainers
    var format: ShareFormat = .square
    var theme: ShareTheme = .terminal
    var brand: Bool = true
    /// Portfolio to render: a portfolio UUID string or "all"; nil follows the active context.
    var source: String?

    /// Fields permitted by the privacy level. Sensitive fields exist only in `custom`, opt-in.
    var fields: Set<ShareField> {
        switch privacy {
        case .public: [.pct, .chart, .movers]
        case .value: [.value, .pct, .chart, .movers]
        case .custom: custom
        }
    }

    enum Level: Sendable { case safe, semi, sensitive }
    var level: Level {
        let f = fields
        if f.contains(where: \.isSensitive) { return .sensitive }
        if f.contains(where: \.isSemiSensitive) { return .semi }
        return .safe
    }

    /// Settings safe to remember for quick share: never persist a sensitive custom set as the default.
    var safeForReuse: ShareConfig {
        var c = self
        if c.level == .sensitive { c.privacy = .public; c.custom = [.pct, .chart, .movers] }
        return c
    }

    mutating func apply(_ o: ShareOverrides) {
        if let p = o.period { period = p }
        if let p = o.privacy { privacy = p }
        if let f = o.format { format = f }
        if let t = o.theme { theme = t }
    }

    var summary: String { "\(period.rawValue) · \(privacy.label) · \(format.rawValue) · \(theme.rawValue)" }
}

/// Everything the card may draw. Built by `ShareCardBuilder`, which only ever copies
/// permitted fields in: hidden data is absent from the model, not merely not drawn.
struct ShareCardModel: Equatable, Sendable {
    struct MoverRow: Equatable, Sendable { let rank, symbol, bar, main, extra: String; let sign: Int }
    struct AllocRow: Equatable, Sendable { let symbol, bar, pct: String }

    let format: ShareFormat
    let theme: ShareTheme
    let title: String
    let date: String
    let value: String?
    let pct: String?
    let pctSign: Int
    let pnl: String?
    let pnlSign: Int
    let sub: String?
    let chart: [String]?
    let moversTitle: String
    let moversSub: String
    let movers: [MoverRow]?
    let alloc: [AllocRow]?
    let brand: Bool

    /// Every string that ends up in the bitmap (for privacy tests).
    var allText: [String] {
        var t = [title, date, moversTitle, moversSub]
        t += [value, pct, pnl, sub].compactMap { $0 }
        t += chart ?? []
        t += (movers ?? []).flatMap { [$0.rank, $0.symbol, $0.bar, $0.main, $0.extra] }
        t += (alloc ?? []).flatMap { [$0.symbol, $0.bar, $0.pct] }
        return t
    }
}

enum ShareCardBuilder {
    static func periodLabel(_ p: ChartRange) -> String {
        switch p {
        case .h24, .d1: "today"; case .d7, .w1: "past 7 days"; case .d30, .m1: "past 30 days"
        case .ytd: "year to date"; case .all: "all time"; default: p.rawValue.lowercased()
        }
    }

    static func build(
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
    static func privacyCheck(_ c: ShareConfig) -> (visible: [String], hidden: [String]) {
        let f = c.fields
        let visible = ShareField.allCases.filter { f.contains($0) }.map { "✓ " + ($0 == .chart ? c.period.rawValue.lowercased() + " chart" : $0.label) }
        let hidden = [ShareField.name, .value, .pnl, .alloc, .posv, .avg].filter { !f.contains($0) }.map { "✓ " + $0.label }
            + ["✓ holdings / amounts", "✓ cost basis", "✓ transaction history", "✓ wallet & exchange info"]
        return (visible, hidden)
    }
}
