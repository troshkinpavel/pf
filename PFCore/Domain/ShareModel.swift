import Foundation

public enum SharePrivacy: String, Codable, CaseIterable, Sendable {
    case `public`, value, custom
    public var label: String { self == .value ? "value visible" : rawValue }
}

public enum ShareField: String, Codable, CaseIterable, Sendable {
    case name, value, pct, pnl, chart, movers, alloc, posv, avg
    /// 0.7 cards: contributions in pp of the portfolio, the flows note, allocation drift, $ impact.
    case contrib, flows, drift, impact

    public var label: String {
        switch self {
        case .name: "portfolio name"; case .value: "portfolio value"; case .pct: "percentage change"; case .pnl: "absolute P&L"
        case .chart: "performance chart"; case .movers: "top movers"; case .alloc: "asset allocation"
        case .posv: "position values"; case .avg: "average entries"
        case .contrib: "contributors"; case .flows: "flows note"; case .drift: "allocation drift"; case .impact: "$ impact"
        }
    }
    /// Reveals holdings-level data.
    public var isSensitive: Bool { [.pnl, .posv, .avg].contains(self) }
    /// Reveals portfolio size or composition but not holdings.
    public var isSemiSensitive: Bool { [.value, .alloc, .name, .drift, .impact].contains(self) }
}

/// Which card (design §16): the 0.6 performance card, what changed, vs benchmark.
public enum ShareCardKind: String, Codable, CaseIterable, Sendable {
    case performance, changes, benchmark
    public var label: String { switch self { case .performance: "performance"; case .changes: "what changed"; case .benchmark: "vs benchmark" } }
    /// Content options this card offers.
    public var options: [ShareField] {
        switch self {
        case .performance: [.name, .value, .pct, .pnl, .chart, .movers, .alloc, .posv, .avg]
        case .changes: [.pct, .contrib, .flows, .drift, .name, .value, .impact]
        case .benchmark: [.pct, .name, .value]
        }
    }
    /// What "public" shows: percentages and pp only.
    public var publicFields: Set<ShareField> {
        switch self { case .performance: [.pct, .chart, .movers]; case .changes: [.pct, .contrib, .flows]; case .benchmark: [.pct] }
    }
    /// "value visible" adds the total value (and $ impact on what changed).
    public var valueFields: Set<ShareField> {
        switch self { case .performance: [.value, .pct, .chart, .movers]; case .changes: [.value, .pct, .contrib, .flows, .impact]; case .benchmark: [.value, .pct] }
    }
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

/// Card surface effect (design §16). Drawn over the card; never changes its content.
public enum ShareEffect: String, Codable, CaseIterable, Sendable { case none, scanlines, glow, dither, glitch, crt }
/// Still PNG, or a 3 s animation (chart draws in, bars grow) exported as MP4 or GIF.
public enum ShareMotion: String, Codable, CaseIterable, Sendable { case still, animated }
public enum ShareMotionFormat: String, Codable, CaseIterable, Sendable { case mp4, gif }
/// How an animated card builds up: numbers count up and rows slide in · terminal typing ·
/// a CRT scan line revealing the card.
public enum ShareMotionStyle: String, Codable, CaseIterable, Sendable {
    case countUp, typewriter, scan
    public var label: String { switch self { case .countUp: "count up"; case .typewriter: "typewriter"; case .scan: "scan" } }
}

public struct ShareConfig: Codable, Equatable, Sendable {
    /// 0.7: card kind and the benchmark card's range and headline benchmark.
    public var card: ShareCardKind = .performance
    public var benchRange: String = "1Y"
    public var benchVs: String = "BTC"
    public var effect: ShareEffect = .none
    public var motion: ShareMotion = .still
    public var motionFormat: ShareMotionFormat = .mp4
    public var motionStyle: ShareMotionStyle = .countUp

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

    /// Fields permitted by the privacy level, for this card. Sensitive fields exist only in
    /// `custom`, opt-in; a custom set never carries fields the card doesn't offer.
    public var fields: Set<ShareField> {
        switch privacy {
        case .public: card.publicFields
        case .value: card.valueFields
        case .custom: custom.intersection(card.options)
        }
    }

    enum CodingKeys: String, CodingKey { case period, privacy, custom, moverCount, moverType, format, theme, brand, source, card, benchRange, benchVs, effect, motion, motionFormat, motionStyle }

    /// Tolerant: settings saved before a field existed keep everything else.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShareConfig()
        period = (try? c.decode(ChartRange.self, forKey: .period)) ?? d.period
        privacy = (try? c.decode(SharePrivacy.self, forKey: .privacy)) ?? d.privacy
        custom = (try? c.decode(Set<ShareField>.self, forKey: .custom)) ?? d.custom
        moverCount = (try? c.decode(Int.self, forKey: .moverCount)) ?? d.moverCount
        moverType = (try? c.decode(MoverType.self, forKey: .moverType)) ?? d.moverType
        format = (try? c.decode(ShareFormat.self, forKey: .format)) ?? d.format
        theme = (try? c.decode(ShareTheme.self, forKey: .theme)) ?? d.theme
        brand = (try? c.decode(Bool.self, forKey: .brand)) ?? d.brand
        source = try? c.decode(String.self, forKey: .source)
        card = (try? c.decode(ShareCardKind.self, forKey: .card)) ?? d.card
        benchRange = (try? c.decode(String.self, forKey: .benchRange)) ?? d.benchRange
        benchVs = (try? c.decode(String.self, forKey: .benchVs)) ?? d.benchVs
        effect = (try? c.decode(ShareEffect.self, forKey: .effect)) ?? d.effect
        motion = (try? c.decode(ShareMotion.self, forKey: .motion)) ?? d.motion
        motionFormat = (try? c.decode(ShareMotionFormat.self, forKey: .motionFormat)) ?? d.motionFormat
        motionStyle = (try? c.decode(ShareMotionStyle.self, forKey: .motionStyle)) ?? d.motionStyle
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
        if c.level == .sensitive { c.privacy = .public; c.custom = c.card.publicFields }
        return c
    }

    public mutating func apply(_ o: ShareOverrides) {
        if let p = o.period { period = p }
        if let p = o.privacy { privacy = p }
        if let f = o.format { format = f }
        if let t = o.theme { theme = t }
    }

    public var summary: String {
        (card == .performance ? "" : card.label + " · ") + "\(card == .benchmark ? benchRange : period.rawValue) · \(privacy.label) · \(format.rawValue) · \(theme.rawValue)"
    }
}

/// Everything the card may draw. Built by `ShareCardBuilder`, which only ever copies
/// permitted fields in: hidden data is absent from the model, not merely not drawn.
public struct ShareCardModel: Equatable, Sendable {
    public init(format: ShareFormat, theme: ShareTheme, title: String, date: String, value: String? = nil, pct: String? = nil, pctSign: Int, pnl: String? = nil, pnlSign: Int, sub: String? = nil, chart: [String]? = nil, moversTitle: String, moversSub: String, movers: [MoverRow]? = nil, alloc: [AllocRow]? = nil, brand: Bool,
                barsTitle: String = "", barsSub: String = "", bars: [BarRow]? = nil, allocTitle: String = "ALLOCATION", note: String? = nil, effect: ShareEffect = .none, motionStyle: ShareMotionStyle = .countUp) { self.effect = effect; self.motionStyle = motionStyle; self.format = format; self.theme = theme; self.title = title; self.date = date; self.value = value; self.pct = pct; self.pctSign = pctSign; self.pnl = pnl; self.pnlSign = pnlSign; self.sub = sub; self.chart = chart; self.moversTitle = moversTitle; self.moversSub = moversSub; self.movers = movers; self.alloc = alloc; self.brand = brand; self.barsTitle = barsTitle; self.barsSub = barsSub; self.bars = bars; self.allocTitle = allocTitle; self.note = note }
    /// A labelled bar (contributions in pp, portfolio vs benchmarks).
    public struct BarRow: Equatable, Sendable {
        public enum Tint: Sendable, Equatable { case sign, accent, dim }
        public let symbol: String
        public let fraction: Double      // 0…1 of the longest bar
        public let value: String
        public let extra: String
        public let sign: Int
        public let tint: Tint
        public init(symbol: String, fraction: Double, value: String, extra: String = "", sign: Int, tint: Tint = .sign) {
            self.symbol = symbol; self.fraction = fraction; self.value = value; self.extra = extra; self.sign = sign; self.tint = tint
        }
    }
    public struct MoverRow: Equatable, Sendable {
        public let rank, symbol, bar, main, extra: String; public let sign: Int
        public init(rank: String, symbol: String, bar: String, main: String, extra: String, sign: Int) {
            self.rank = rank; self.symbol = symbol; self.bar = bar; self.main = main; self.extra = extra; self.sign = sign
        }
    }
    public struct AllocRow: Equatable, Sendable {
        public let symbol, bar, pct: String
        /// 0…1: drawn as a bar across the row (0.7); nil keeps the text `bar`.
        public let fraction: Double?
        public init(symbol: String, bar: String, pct: String, fraction: Double? = nil) { self.symbol = symbol; self.bar = bar; self.pct = pct; self.fraction = fraction }
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
    public let barsTitle: String
    public let barsSub: String
    public let bars: [BarRow]?
    public let allocTitle: String
    public let note: String?
    public let effect: ShareEffect
    public let motionStyle: ShareMotionStyle

    /// Every string that ends up in the bitmap (for privacy tests).
    public var allText: [String] {
        var t = [title, date, moversTitle, moversSub]
        t += [value, pct, pnl, sub].compactMap { $0 }
        t += chart ?? []
        t += (movers ?? []).flatMap { [$0.rank, $0.symbol, $0.bar, $0.main, $0.extra] }
        t += (alloc ?? []).flatMap { [$0.symbol, $0.bar, $0.pct] }
        t += [barsTitle, barsSub, allocTitle] + (note.map { [$0] } ?? [])
        t += (bars ?? []).flatMap { [$0.symbol, $0.value, $0.extra] }
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
            // Gainers: your positive return on the asset over the period (cash-like stablecoins excluded).
            let items = movers.filter { imp ? $0.impact != nil : ($0.periodReturn ?? 0) > 0 && !$0.valuation.asset.isStablecoin }
            let top = items.sorted { imp ? $0.impact!.double > $1.impact!.double : $0.periodReturn! > $1.periodReturn! }.prefix(config.moverCount)
            let mx = top.map { abs($0.impact?.double ?? 0) }.max() ?? 1
            moverRows = top.enumerated().map { i, m in
                var extra: [String] = []
                if f.contains(.posv) { extra.append(fmt.compact(m.valuation.value)) }
                if f.contains(.avg), let a = m.valuation.position.averageEntry { extra.append("avg " + fmt.price(a)) }
                let a = m.impact?.double ?? 0
                return .init(
                    rank: String(format: "%02d", i + 1), symbol: m.valuation.asset.symbol,
                    bar: imp ? " " + String(repeating: "█", count: max(1, Int((abs(a) / (mx > 0 ? mx : 1) * 9).rounded()))) : "",
                    main: imp ? (net != 0 ? fmt.num(a / net * 100, 0) + "%" : "—") : fmt.pct(m.periodReturn),
                    extra: extra.joined(separator: "  "), sign: sign(imp ? a : m.periodReturn ?? 0))
            }
        }

        var alloc: [ShareCardModel.AllocRow]? = nil
        if f.contains(.alloc) {
            alloc = summary.positions.compactMap { v in
                v.allocation.map { .init(symbol: v.asset.symbol, bar: AsciiChart.bar($0 / 100, width: 16), pct: fmt.num($0, 1) + "%", fraction: $0 / 100) }
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
            moversSub: imp ? "share of move" : (moverRows?.isEmpty == false ? "your return" : "none this period"),
            movers: moverRows, alloc: alloc, brand: config.brand, effect: config.effect, motionStyle: config.motionStyle)
    }

    // MARK: 0.7 cards (design §16) — public-safe by construction: pp of portfolio, never $
    // unless "value visible" / custom adds it.

    public static func changesPeriodLabel(_ p: Attribution.Period) -> String { p == .today ? "TODAY" : p.label }

    public static func buildChanges(config: ShareConfig, period: Attribution.Period, result r: Attribution.Result?, twr: Double?,
                                    symbol: (AssetID) -> String, now: Date, fmt: Fmt, contextName: String = "PORTFOLIO") -> ShareCardModel {
        let f = config.fields
        let sign: (Double) -> Int = { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
        let perf = twr ?? r?.performancePct
        var bars: [ShareCardModel.BarRow]? = nil
        if f.contains(.contrib), let r, r.startValue > 0 {
            let top = Array(r.byImpact.prefix(config.moverCount))
            let pps = top.map { ($0.contribution / r.startValue).double * 100 }
            let mx = pps.map(abs).max() ?? 1
            bars = zip(top, pps).map { a, pp in
                .init(symbol: symbol(a.id), fraction: mx > 0 ? abs(pp) / mx : 0, value: (pp < 0 ? "−" : "+") + fmt.num(abs(pp), 1) + "pp",
                      extra: f.contains(.impact) ? fmt.signed(a.contribution, 0) : "", sign: sign(pp))
            }
        }
        var alloc: [ShareCardModel.AllocRow]? = nil
        if f.contains(.drift), let r {
            alloc = r.assets.filter { abs($0.weightDelta) >= 0.05 }.sorted { abs($0.weightDelta) > abs($1.weightDelta) }.prefix(config.moverCount).map {
                .init(symbol: symbol($0.id), bar: fmt.num($0.weightStart, 1) + " → " + fmt.num($0.weightEnd, 1), pct: ($0.weightDelta < 0 ? "−" : "+") + fmt.num(abs($0.weightDelta), 1) + "pp")
            }
        }
        let note: String? = f.contains(.flows) ? r.map { r in
            let n = r.buys + r.sells
            return n == 0 ? "no money in or out · all of it is market move" : "\(n) trade\(n == 1 ? "" : "s") excluded from performance"
        } : nil
        return ShareCardModel(
            format: config.format, theme: config.theme,
            title: (f.contains(.name) ? contextName + " · " : "") + "WHAT CHANGED / " + changesPeriodLabel(period),
            date: DateFmt.card(now),
            value: f.contains(.value) ? r.map { fmt.money($0.endValue) } : nil,
            pct: f.contains(.pct) ? perf.map { ($0 >= 0 ? "▲ " : "▼ ") + fmt.pct($0) } ?? "—" : nil,
            pctSign: sign(perf ?? 0), pnlSign: 0,
            sub: "twr · deposits excluded",
            moversTitle: "", moversSub: "", brand: config.brand,
            barsTitle: "CONTRIBUTION", barsSub: "pp of portfolio", bars: bars, allocTitle: "ALLOC DRIFT", note: note, effect: config.effect, motionStyle: config.motionStyle)
    }

    public static func buildBenchmark(config: ShareConfig, result b: Benchmark.Result, value: Decimal? = nil, now: Date, fmt: Fmt, contextName: String = "PORTFOLIO") -> ShareCardModel {
        let f = config.fields
        let sign: (Double) -> Int = { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
        let vsETH = config.benchVs == "ETH"
        let headline = vsETH ? b.vsETH : b.vsBTC
        let name = f.contains(.name) ? contextName : "PORTFOLIO"
        let rows: [(String, Double?, ShareCardModel.BarRow.Tint)] = [(f.contains(.name) ? contextName : "MAIN", b.portfolio.returnPct, .sign),
                                                                       ("BTC", b.btc.returnPct, .accent), ("ETH", b.eth.returnPct, .dim)]
        let mx = rows.compactMap { $0.1.map(abs) }.max() ?? 1
        return ShareCardModel(
            format: config.format, theme: config.theme,
            title: name + " vs BTC · ETH / " + b.range.rawValue,
            date: DateFmt.card(now),
            value: f.contains(.value) ? value.map { fmt.money($0) } : nil,
            pct: f.contains(.pct) ? headline.map { ($0 < 0 ? "−" : "+") + fmt.num(abs($0), 1) + "pp" } ?? "—" : nil,
            pctSign: sign(headline ?? 0), pnlSign: 0,
            sub: "vs " + (vsETH ? "ETH" : "BTC") + " · twr, deposits excluded",
            moversTitle: "", moversSub: "", brand: config.brand,
            barsTitle: "", barsSub: "",
            bars: f.contains(.pct) ? rows.map { s, v, t in
                .init(symbol: s, fraction: v.map { mx > 0 ? abs($0) / mx : 0 } ?? 0, value: v.map { fmt.pct($0, 1) } ?? "—", sign: sign(v ?? 0), tint: t)
            } : nil, effect: config.effect, motionStyle: config.motionStyle)
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
