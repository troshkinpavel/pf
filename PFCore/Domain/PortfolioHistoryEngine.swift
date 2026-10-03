import Foundation

/// Sorted price history for one asset with interpolated lookup.
public struct PriceSeries: Sendable, Hashable {
    public let points: [PricePoint]

    public init(_ points: [PricePoint]) { self.points = points.sorted { $0.time < $1.time } }

    public var first: PricePoint? { points.first }

    /// Linear interpolation; nil before the first point (no data), last price after the end.
    public func price(at t: Date, tolerance: TimeInterval = 0) -> Double? {
        guard let f = points.first, let l = points.last else { return nil }
        if t < f.time.addingTimeInterval(-tolerance) { return nil }
        if t <= f.time { return f.price }
        if t >= l.time { return l.price }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].time <= t { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return a.price }
        return a.price + (b.price - a.price) * t.timeIntervalSince(a.time) / span
    }
}

public struct HistoryPoint: Hashable, Sendable {
    public init(time: Date, value: Double? = nil, cost: Double, invested: Double = 0, deposited: Double = 0) { self.time = time; self.value = value; self.cost = cost; self.invested = invested; self.deposited = deposited }
    public let time: Date
    public let value: Double?      // nil when a held asset had no price at that time
    public let cost: Double
    public var invested: Double = 0    // cumulative external flows (buys, transfers in − sells, transfers out)
    public var deposited: Double = 0   // cumulative inflows only (buys, transfers in)

    /// Total P&L (realized + unrealized) at this time.
    public var pnl: Double? { value.map { $0 - invested } }
}

public enum ChartRange: String, CaseIterable, Codable, Sendable {
    case h1 = "1H", d1 = "1D", h24 = "24H", w1 = "1W", d7 = "7D", m1 = "1M", d30 = "30D", m3 = "3M", ytd = "YTD", y1 = "1Y", all = "ALL"

    /// Seconds covered, nil for ALL / YTD (depends on data / calendar).
    public var seconds: TimeInterval? {
        switch self {
        case .h1: 3600
        case .d1, .h24: 86400
        case .w1, .d7: 7 * 86400
        case .m1, .d30: 30 * 86400
        case .m3: 90 * 86400
        case .y1: 365 * 86400
        case .ytd, .all: nil
        }
    }

    public func start(now: Date, firstTransaction: Date?) -> Date {
        if let s = seconds { return now.addingTimeInterval(-s) }
        if self == .ytd {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
            return cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        }
        return firstTransaction ?? now.addingTimeInterval(-365 * 86400)
    }

    public var changePeriod: ChangePeriod? {
        switch self {
        case .h1: .h1
        case .d1, .h24: .h24
        case .w1, .d7: .d7
        case .m1, .d30: .d30
        case .y1: .y1
        default: nil
        }
    }
}

public enum PortfolioHistoryEngine {
    public static func grid(start: Date, end: Date, count: Int) -> [Date] {
        guard count > 1, end > start else { return [end] }
        let step = end.timeIntervalSince(start) / Double(count - 1)
        return (0..<count).map { start.addingTimeInterval(Double($0) * step) }
    }

    /// Reconstructs portfolio value at each grid time using the holdings *at that time*
    /// (from the ledger) times the historical price at that time. Never multiplies today's
    /// holdings by old prices.
    public static func reconstruct(transactions: [Transaction], grid: [Date], series: [AssetID: PriceSeries]) -> [HistoryPoint] {
        let txs = PortfolioEngine.ordered(transactions)
        var positions: [AssetID: Position] = [:]
        var i = 0
        var invested = 0.0, deposited = 0.0
        var out: [HistoryPoint] = []
        out.reserveCapacity(grid.count)
        for t in grid {
            while i < txs.count, txs[i].timestamp <= t {
                let t = txs[i]
                let flow = PortfolioEngine.externalFlow(t, fallbackPrice: series[t.assetID]?.price(at: t.timestamp).map(Decimal.of)).double
                invested += flow
                deposited += max(0, flow)
                var p = positions[t.assetID] ?? Position(assetID: t.assetID)
                PortfolioEngine.apply(t, to: &p)
                p.transactions.removeAll(keepingCapacity: false)
                positions[txs[i].assetID] = p
                i += 1
            }
            var value = 0.0, cost = 0.0, missing = false
            for (id, p) in positions where p.quantity > 0 {
                cost += p.costBasis.double
                if let px = series[id]?.price(at: t, tolerance: 6 * 3600) {
                    value += p.quantity.double * px
                } else {
                    missing = true
                }
            }
            out.append(HistoryPoint(time: t, value: missing ? nil : value, cost: cost, invested: invested, deposited: deposited))
        }
        return out
    }

    /// Replace the final point with the live valuation so charts end at the headline number.
    public static func pinLast(_ pts: [HistoryPoint], liveValue: Double?, liveCost: Double) -> [HistoryPoint] {
        guard let v = liveValue, let last = pts.last else { return pts }
        var p = pts
        p[p.count - 1] = HistoryPoint(time: last.time, value: v, cost: liveCost, invested: last.invested, deposited: last.deposited)
        return p
    }

    /// Money-weighted return between two points: P&L change over capital at work
    /// (start value + new deposits), the same basis as the app's 24h change.
    public static func moneyWeightedReturn(from a: HistoryPoint, to b: HistoryPoint) -> Double? {
        guard let pa = a.pnl, let pb = b.pnl else { return nil }
        let capital = (a.value ?? 0) + (b.deposited - a.deposited)
        return capital > 0 ? (pb - pa) / capital * 100 : nil
    }

    /// Time-weighted return index (starts at 1). Deposits and withdrawals between points are
    /// removed, so the index moves only with market performance — the basis for drawdown.
    public static func twrIndex(_ pts: [HistoryPoint]) -> [Double] {
        var idx = 1.0, out: [Double] = []
        var prev: HistoryPoint?
        for p in pts {
            guard let v = p.value else { continue }
            if let q = prev, let v0 = q.value, v0 > 0 {
                let r = (v - (p.invested - q.invested)) / v0
                if r.isFinite && r > 0 { idx *= r }
            }
            out.append(idx)
            prev = p
        }
        return out
    }

    public struct Drawdown: Sendable {
        public init(series: [Double], max: Double, maxIndex: Int) { self.series = series; self.max = max; self.maxIndex = maxIndex }
        public let series: [Double]      // ≤ 0 fractions
        public let max: Double           // most negative
        public let maxIndex: Int
        public var current: Double { series.last ?? 0 }
    }

    public static func drawdown(_ values: [Double]) -> Drawdown {
        var peak = -Double.infinity, maxDD = 0.0, maxI = 0
        var dd: [Double] = []
        for (i, v) in values.enumerated() {
            peak = Swift.max(peak, v)
            let d = peak > 0 ? v / peak - 1 : 0
            if d < maxDD { maxDD = d; maxI = i }
            dd.append(d)
        }
        return Drawdown(series: dd, max: maxDD, maxIndex: maxI)
    }
}

// MARK: - Period performance & movers

public struct PeriodPerformance: Sendable {
    public init(absolute: Decimal, percent: Double? = nil) { self.absolute = absolute; self.percent = percent }
    public let absolute: Decimal
    public let percent: Double?
}

public struct Mover: Identifiable, Hashable, Sendable {
    public init(valuation: PositionValuation, changePct: Double? = nil, impact: Decimal? = nil, periodReturn: Double? = nil) {
        self.valuation = valuation; self.changePct = changePct; self.impact = impact; self.periodReturn = periodReturn
    }
    public var id: AssetID { valuation.asset.id }
    public let valuation: PositionValuation
    public let changePct: Double?      // asset price move (or return for ALL)
    public let impact: Decimal?        // $ effect on the portfolio
    /// Your return on this asset over the range, flow-adjusted like the portfolio headline:
    /// impact ÷ (value held at the start + money put in during the range). A coin bought last
    /// week only counts from then; its 30-day price move is not your gain.
    public var periodReturn: Double?
}

public enum MoversEngine {
    /// Start price for an asset at the beginning of `range`: quote-reported change first, history second.
    public static func startPrice(_ id: AssetID, range: ChartRange, quote: Quote?, series: PriceSeries?, start: Date) -> Decimal? {
        if let p = range.changePeriod, let sp = quote?.startPrice(p) { return sp }
        return series?.price(at: start, tolerance: 86400).map(Decimal.of)
    }

    public static func movers(
        summary: PortfolioSummary, transactions: [Transaction], quotes: [AssetID: Quote],
        series: [AssetID: PriceSeries], range: ChartRange, now: Date
    ) -> [Mover] {
        if range == .all {
            return summary.positions.map { v in
                Mover(valuation: v, changePct: v.totalReturnPct, impact: v.totalPnL, periodReturn: v.totalReturnPct)
            }
        }
        let start = range.start(now: now, firstTransaction: summary.firstDate)
        let c = PortfolioEngine.contributions(transactions, quotes: quotes, start: start, now: now) {
            startPrice($0, range: range, quote: quotes[$0], series: series[$0], start: start)
        }
        return summary.positions.map { v in
            let sp = startPrice(v.asset.id, range: range, quote: v.quote, series: series[v.asset.id], start: start)
            let pct: Double? = {
                if let p = range.changePeriod, let ch = v.quote?.change[p] { return ch }
                guard let sp, sp > 0, let px = v.price else { return nil }
                return ((px - sp) / sp).double * 100
            }()
            let r = c[v.asset.id].flatMap { x -> Double? in
                let base = x.startValue + x.inflow
                return base > 0 ? (x.contribution / base).double * 100 : nil
            }
            return Mover(valuation: v, changePct: pct, impact: c[v.asset.id]?.contribution, periodReturn: r)
        }
    }

    /// Flow-adjusted portfolio performance over a range.
    /// ALL = total P&L (realized + unrealized) over total capital invested.
    public static func performance(
        summary: PortfolioSummary, transactions: [Transaction], quotes: [AssetID: Quote],
        series: [AssetID: PriceSeries], range: ChartRange, now: Date
    ) -> PeriodPerformance? {
        if range == .all {
            let invested = transactions.filter { $0.type.increases }.reduce(Decimal(0)) { $0 + $1.quantity * $1.price + $1.fee }
            return PeriodPerformance(absolute: summary.totalPnL, percent: invested > 0 ? (summary.totalPnL / invested).double * 100 : nil)
        }
        let start = range.start(now: now, firstTransaction: summary.firstDate)
        let c = PortfolioEngine.contributions(transactions, quotes: quotes, start: start, now: now) {
            startPrice($0, range: range, quote: quotes[$0], series: series[$0], start: start)
        }
        guard !c.isEmpty else { return nil }
        // Missing start prices for held assets make the figure unreliable: report nothing.
        let heldIDs = summary.positions.filter { $0.price != nil }.map(\.asset.id)
        guard heldIDs.allSatisfy({ c[$0] != nil }) else { return nil }
        let sum = c.values.reduce(Decimal(0)) { $0 + $1.contribution }
        let denom = c.values.reduce(Decimal(0)) { $0 + $1.startValue + $1.inflow }
        return PeriodPerformance(absolute: sum, percent: denom > 0 ? (sum / denom).double * 100 : nil)
    }
}

// MARK: - Portfolio chart (shared by every platform's portfolio screens, share cards and widgets)

public struct PortfolioChart: Sendable {
    public init(value: [Double] = [], pnl: [Double] = [], twr: [Double] = [], points: [HistoryPoint] = []) { self.value = value; self.pnl = pnl; self.twr = twr; self.points = points }
    public var value: [Double] = []     // market value (steps up on deposits)
    public var pnl: [Double] = []       // value − net invested: profit and drawdown periods
    public var twr: [Double] = []       // time-weighted index, deposits removed
    public var points: [HistoryPoint] = []
    public var isEmpty: Bool { value.count < 2 }
    /// Time-weighted return over the chart in %: market performance with deposits and
    /// withdrawals removed. nil without enough history.
    public var twrPercent: Double? { twr.count > 1 ? (twr[twr.count - 1] / twr[0] - 1) * 100 : nil }
}

extension PortfolioHistoryEngine {
    /// Reconstructed history for a range, ending at the live valuation. Falls back to locally
    /// recorded snapshots (cost basis stands in for net invested) when price history is thin.
    public static func chart(transactions txs: [Transaction], summary: PortfolioSummary, range: ChartRange, points: Int,
                      series: [AssetID: PriceSeries], now end: Date,
                      snapshots: (Date) -> [PortfolioSnapshotValue] = { _ in [] }) -> PortfolioChart {
        chart(transactions: txs, summary: summary, start: range.start(now: end, firstTransaction: summary.firstDate), points: points,
              series: series, now: end, snapshots: snapshots)
    }

    /// Same as above from an explicit start (benchmark windows such as 6M).
    public static func chart(transactions txs: [Transaction], summary: PortfolioSummary, start: Date, points: Int,
                      series: [AssetID: PriceSeries], now end: Date,
                      snapshots: (Date) -> [PortfolioSnapshotValue] = { _ in [] }) -> PortfolioChart {
        let grid = grid(start: start, end: end, count: points)
        var pts = reconstruct(transactions: txs, grid: grid, series: series)
        pts = pinLast(pts, liveValue: summary.isPartial ? nil : summary.totalValue.double, liveCost: summary.costBasis.double)
        let priced = pts.filter { $0.value != nil }
        if priced.count >= max(2, points / 3) {
            return PortfolioChart(value: priced.compactMap(\.value), pnl: priced.compactMap(\.pnl), twr: twrIndex(priced), points: priced)
        }
        // Snapshots record value and cost basis only. Money in/out comes from the ledger: cost basis
        // is not it (a profitable sell lowers cost by less than the cash taken out, which would
        // read as a loss in TWR).
        let ordered = PortfolioEngine.ordered(txs)
        var i = 0, invested = 0.0, deposited = 0.0
        let snaps = snapshots(start).sorted { $0.timestamp < $1.timestamp }.map { s -> HistoryPoint in
            while i < ordered.count, ordered[i].timestamp <= s.timestamp {
                let t = ordered[i]
                let f = PortfolioEngine.externalFlow(t, fallbackPrice: series[t.assetID]?.price(at: t.timestamp).map(Decimal.of)).double
                invested += f; deposited += max(0, f); i += 1
            }
            return HistoryPoint(time: s.timestamp, value: s.value, cost: s.costBasis, invested: invested, deposited: deposited)
        }
        guard snaps.count >= 2 else { return PortfolioChart() }
        return PortfolioChart(value: snaps.compactMap(\.value), pnl: snaps.compactMap(\.pnl), twr: twrIndex(snaps), points: snaps)
    }
}

extension PortfolioEngine {
    /// Assets held at any point during the range (at its start, traded within it, or now).
    public static func assetsHeld(_ txs: [Transaction], during range: ChartRange, now: Date) -> [AssetID] {
        let start = range.start(now: now, firstTransaction: txs.map(\.timestamp).min())
        let atStart = positions(txs, until: start).filter { $0.value.quantity > 0 }.keys
        let during = txs.filter { $0.timestamp > start }.map(\.assetID)
        let current = positions(txs).filter { $0.value.quantity > 0 }.keys
        return Array(Set(atStart).union(during).union(current))
    }
}

extension ChartRange {
    /// How long cached price history for this range stays fresh before it is fetched again.
    public var historyTTL: TimeInterval {
        switch self { case .h1: 120; case .d1, .h24: 600; case .w1, .d7: 1800; default: 6 * 3600 }
    }
}

extension MoversEngine {
    /// Price return of one asset over a range, from its quote (the benchmark rows on iOS).
    public static func priceReturn(_ quote: Quote?, series: PriceSeries?, range: ChartRange, now: Date) -> Double? {
        if let p = range.changePeriod, let c = quote?.change[p] { return c }
        guard let px = quote?.price, let sp = startPrice("", range: range, quote: quote, series: series,
                                                         start: range.start(now: now, firstTransaction: nil)), sp > 0 else { return nil }
        return ((px - sp) / sp).double * 100
    }
}
