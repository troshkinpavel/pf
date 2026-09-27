import Foundation

/// Sorted price history for one asset with interpolated lookup.
struct PriceSeries: Sendable, Hashable {
    let points: [PricePoint]

    init(_ points: [PricePoint]) { self.points = points.sorted { $0.time < $1.time } }

    var first: PricePoint? { points.first }

    /// Linear interpolation; nil before the first point (no data), last price after the end.
    func price(at t: Date, tolerance: TimeInterval = 0) -> Double? {
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

struct HistoryPoint: Hashable, Sendable {
    let time: Date
    let value: Double?      // nil when a held asset had no price at that time
    let cost: Double
    var invested: Double = 0    // cumulative external flows (buys, transfers in − sells, transfers out)
    var deposited: Double = 0   // cumulative inflows only (buys, transfers in)

    /// Total P&L (realized + unrealized) at this time.
    var pnl: Double? { value.map { $0 - invested } }
}

enum ChartRange: String, CaseIterable, Codable, Sendable {
    case h1 = "1H", d1 = "1D", h24 = "24H", w1 = "1W", d7 = "7D", m1 = "1M", d30 = "30D", m3 = "3M", ytd = "YTD", y1 = "1Y", all = "ALL"

    /// Seconds covered, nil for ALL / YTD (depends on data / calendar).
    var seconds: TimeInterval? {
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

    func start(now: Date, firstTransaction: Date?) -> Date {
        if let s = seconds { return now.addingTimeInterval(-s) }
        if self == .ytd {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
            return cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        }
        return firstTransaction ?? now.addingTimeInterval(-365 * 86400)
    }

    var changePeriod: ChangePeriod? {
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

enum PortfolioHistoryEngine {
    static func grid(start: Date, end: Date, count: Int) -> [Date] {
        guard count > 1, end > start else { return [end] }
        let step = end.timeIntervalSince(start) / Double(count - 1)
        return (0..<count).map { start.addingTimeInterval(Double($0) * step) }
    }

    /// Reconstructs portfolio value at each grid time using the holdings *at that time*
    /// (from the ledger) times the historical price at that time. Never multiplies today's
    /// holdings by old prices.
    static func reconstruct(transactions: [Transaction], grid: [Date], series: [AssetID: PriceSeries]) -> [HistoryPoint] {
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
    static func pinLast(_ pts: [HistoryPoint], liveValue: Double?, liveCost: Double) -> [HistoryPoint] {
        guard let v = liveValue, let last = pts.last else { return pts }
        var p = pts
        p[p.count - 1] = HistoryPoint(time: last.time, value: v, cost: liveCost, invested: last.invested, deposited: last.deposited)
        return p
    }

    /// Money-weighted return between two points: P&L change over capital at work
    /// (start value + new deposits), the same basis as the app's 24h change.
    static func moneyWeightedReturn(from a: HistoryPoint, to b: HistoryPoint) -> Double? {
        guard let pa = a.pnl, let pb = b.pnl else { return nil }
        let capital = (a.value ?? 0) + (b.deposited - a.deposited)
        return capital > 0 ? (pb - pa) / capital * 100 : nil
    }

    /// Time-weighted return index (starts at 1). Deposits and withdrawals between points are
    /// removed, so the index moves only with market performance — the basis for drawdown.
    static func twrIndex(_ pts: [HistoryPoint]) -> [Double] {
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

    struct Drawdown: Sendable {
        let series: [Double]      // ≤ 0 fractions
        let max: Double           // most negative
        let maxIndex: Int
        var current: Double { series.last ?? 0 }
    }

    static func drawdown(_ values: [Double]) -> Drawdown {
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

struct PeriodPerformance: Sendable {
    let absolute: Decimal
    let percent: Double?
}

struct Mover: Identifiable, Hashable, Sendable {
    var id: AssetID { valuation.asset.id }
    let valuation: PositionValuation
    let changePct: Double?      // asset price move (or return for ALL)
    let impact: Decimal?        // $ effect on the portfolio
}

enum MoversEngine {
    /// Start price for an asset at the beginning of `range`: quote-reported change first, history second.
    static func startPrice(_ id: AssetID, range: ChartRange, quote: Quote?, series: PriceSeries?, start: Date) -> Decimal? {
        if let p = range.changePeriod, let sp = quote?.startPrice(p) { return sp }
        return series?.price(at: start, tolerance: 86400).map(Decimal.of)
    }

    static func movers(
        summary: PortfolioSummary, transactions: [Transaction], quotes: [AssetID: Quote],
        series: [AssetID: PriceSeries], range: ChartRange, now: Date
    ) -> [Mover] {
        if range == .all {
            return summary.positions.map { v in
                Mover(valuation: v, changePct: v.returnPct, impact: v.unrealized.map { $0 + v.position.realizedPnL })
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
            return Mover(valuation: v, changePct: pct, impact: c[v.asset.id]?.contribution)
        }
    }

    /// Flow-adjusted portfolio performance over a range.
    /// ALL = total P&L (realized + unrealized) over total capital invested.
    static func performance(
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
