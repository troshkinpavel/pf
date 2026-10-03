import Foundation

/// Portfolio vs BTC / ETH (design §10). The portfolio side is its time-weighted return, so
/// deposits and withdrawals are excluded; benchmarks are buy-and-hold price returns in the
/// ledger currency from the same start. Relative performance is a simple difference of the
/// cumulative returns, in percentage points. No history is ever made up: a missing side is
/// nil with a reason.
public enum Benchmark {
    public enum Range: String, CaseIterable, Sendable {
        case m1 = "1M", m3 = "3M", m6 = "6M", y1 = "1Y", all = "ALL"
        public func start(now: Date, firstTransaction: Date?) -> Date {
            switch self {
            case .m1: now.addingTimeInterval(-30 * 86400)
            case .m3: now.addingTimeInterval(-90 * 86400)
            case .m6: now.addingTimeInterval(-182 * 86400)
            case .y1: now.addingTimeInterval(-365 * 86400)
            case .all: firstTransaction ?? now.addingTimeInterval(-365 * 86400)
            }
        }
        /// Which loaded price history covers this window.
        public var history: ChartRange { switch self { case .m1: .m1; case .m3: .m3; case .m6, .y1: .y1; case .all: .all } }
    }

    public static let btc: AssetID = "cg:bitcoin"
    public static let eth: AssetID = "cg:ethereum"

    public struct Side: Equatable, Sendable {
        public init(returnPct: Double?, path: [Double], missing: String?) { self.returnPct = returnPct; self.path = path; self.missing = missing }
        public let returnPct: Double?
        /// Cumulative return path (%), for the chart.
        public let path: [Double]
        public let missing: String?
    }

    public struct Result: Equatable, Sendable {
        public init(range: Range, start: Date, portfolio: Side, btc: Side, eth: Side) { self.range = range; self.start = start; self.portfolio = portfolio; self.btc = btc; self.eth = eth }
        public let range: Range
        public let start: Date
        public let portfolio: Side
        public let btc: Side
        public let eth: Side
        public var vsBTC: Double? { zip(portfolio.returnPct, btc.returnPct).map { $0 - $1 } }
        public var vsETH: Double? { zip(portfolio.returnPct, eth.returnPct).map { $0 - $1 } }
    }

    /// Buy-and-hold price return from `start` to `endPrice` (or the series' last point).
    public static func priceSide(_ series: PriceSeries?, start: Date, endPrice: Decimal?, now: Date, points: Int = 80, name: String) -> Side {
        guard let s = series, let first = s.first else { return Side(returnPct: nil, path: [], missing: "\(name) price history unavailable") }
        guard first.time <= start.addingTimeInterval(2 * 86400), let p0 = s.price(at: start, tolerance: 2 * 86400), p0 > 0 else {
            return Side(returnPct: nil, path: [], missing: "\(name) history starts \(DateFmt.ymd(first.time))")
        }
        let end = endPrice?.double ?? s.points.last!.price
        let path = PortfolioHistoryEngine.grid(start: start, end: now, count: points).map { t in ((t >= now ? end : (s.price(at: t) ?? p0)) / p0 - 1) * 100 }
        return Side(returnPct: (end / p0 - 1) * 100, path: path, missing: nil)
    }

    /// Portfolio side from a history chart over the same window (TWR index).
    public static func portfolioSide(_ chart: PortfolioChart, start: Date, firstTransaction: Date?) -> Side {
        guard chart.twr.count > 1, let r = chart.twrPercent else {
            return Side(returnPct: nil, path: [], missing: "not enough portfolio history for this range")
        }
        if let first = firstTransaction, first > start.addingTimeInterval(86400) {
            return Side(returnPct: nil, path: [], missing: "portfolio starts \(DateFmt.ymd(first)) · choose ALL")
        }
        let base = chart.twr[0]
        return Side(returnPct: r, path: chart.twr.map { ($0 / base - 1) * 100 }, missing: nil)
    }
}

private func zip(_ a: Double?, _ b: Double?) -> (Double, Double)? { if let a, let b { return (a, b) }; return nil }
