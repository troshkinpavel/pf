import Foundation

/// Turns the app's computed portfolio state into the small widget snapshot. Pure.
/// Privacy is enforced here: in `percentageOnly` no currency amount enters the snapshot.
public enum WidgetSnapshotBuilder {
    public struct Inputs {
        public init(summary: PortfolioSummary, movers24h: [Mover], performance: [Double], performanceStart: Date, performanceRange: String,
                    performanceChangePercent: Double? = nil, hasPortfolio: Bool, quotesAsOf: Date? = nil, refreshInterval: TimeInterval,
                    isStale: Bool, privacy: WidgetPrivacyMode, currency: String, numberStyle: NumberStyle, now: Date,
                    contextID: String = "all", contextName: String = "PORTFOLIO", contextGlyph: String = "Σ") {
            self.summary = summary; self.movers24h = movers24h; self.performance = performance; self.performanceStart = performanceStart
            self.performanceRange = performanceRange; self.performanceChangePercent = performanceChangePercent; self.hasPortfolio = hasPortfolio
            self.quotesAsOf = quotesAsOf; self.refreshInterval = refreshInterval; self.isStale = isStale; self.privacy = privacy
            self.currency = currency; self.numberStyle = numberStyle; self.now = now
            self.contextID = contextID; self.contextName = contextName; self.contextGlyph = contextGlyph
        }
        public var summary: PortfolioSummary
        public var movers24h: [Mover]            // MoversEngine output for 24H (flow-adjusted impact)
        public var performance: [Double]         // time-weighted index for the chart period
        public var performanceStart: Date
        public var performanceRange: String
        public var performanceChangePercent: Double?
        public var hasPortfolio: Bool
        public var quotesAsOf: Date?
        public var refreshInterval: TimeInterval
        public var isStale: Bool
        public var privacy: WidgetPrivacyMode
        public var currency: String
        public var numberStyle: NumberStyle
        public var now: Date
        public var contextID = "all"
        public var contextName = "PORTFOLIO"
        public var contextGlyph = "Σ"
    }

    public static let maxRows = 6
    public static let chartPoints = 48

    public static func build(_ i: Inputs) -> WidgetPortfolioSnapshot {
        let full = i.privacy == .full
        let s = i.summary

        let mover: (Mover) -> WidgetMover? = { m in
            guard let pct = m.changePct else { return nil }
            return WidgetMover(id: m.valuation.asset.id, symbol: m.valuation.asset.symbol, changePercent: pct, impact: full ? m.impact : nil)
        }
        let gainers = i.movers24h.filter { $0.changePct != nil }.sorted { $0.changePct! > $1.changePct! }.prefix(maxRows).compactMap(mover)
        let impact = i.movers24h.filter { $0.impact != nil }.sorted { abs($0.impact!.double) > abs($1.impact!.double) }.prefix(maxRows).compactMap(mover)

        let positions = s.positions.prefix(maxRows).map { v in
            WidgetPosition(id: v.asset.id, symbol: v.asset.symbol, value: full ? v.value : nil,
                           allocation: v.allocation, change24h: v.change24h, returnPercent: v.returnPct)
        }

        var perf: [WidgetPerformancePoint] = []
        if i.performance.count >= 2 {
            let pts = resample(i.performance, to: chartPoints)
            let mn = pts.min()!, mx = pts.max()!, rg = mx - mn
            let span = i.now.timeIntervalSince(i.performanceStart)
            perf = pts.enumerated().map { k, v in
                WidgetPerformancePoint(timestamp: i.performanceStart.addingTimeInterval(span * Double(k) / Double(pts.count - 1)),
                                       normalizedValue: rg > 0 ? (v - mn) / rg : 0.5)
            }
        }

        let hasValue = !s.isEmpty
        var out = WidgetPortfolioSnapshot(
            generatedAt: i.now, quotesAsOf: i.quotesAsOf, refreshInterval: i.refreshInterval, isStale: i.isStale,
            hasPortfolio: i.hasPortfolio && hasValue,
            portfolioValue: full && hasValue ? s.totalValue : nil,
            dailyChangeValue: full ? s.change24h : nil,
            dailyChangePercent: s.change24hPct,
            unrealizedPnL: full && hasValue ? s.unrealized : nil,
            unrealizedPnLPercent: s.returnPct,
            gainers: Array(gainers), impact: Array(impact), positions: Array(positions),
            performance: perf, performanceRange: i.performanceRange, performanceChangePercent: i.performanceChangePercent,
            privacyMode: i.privacy, currencyCode: i.currency, numberStyle: i.numberStyle)
        out.contextID = i.contextID
        out.contextName = i.contextName
        out.contextGlyph = i.contextGlyph
        return out
    }

    private static func resample(_ v: [Double], to n: Int) -> [Double] { AsciiChart.resample(v, to: n) }
}
