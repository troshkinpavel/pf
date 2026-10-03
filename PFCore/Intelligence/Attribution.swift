import Foundation

/// "What changed" over a period (design §03): change = market move + flows.
///
/// - market move: price effect on holdings, Σ per-asset contribution
///   (qty_end·p_end − qty_start·p_start − flows of that asset), the same flow-adjusted
///   definition PF already uses for 24h and movers;
/// - flows: money in (buys, transfers in) and out (sells, transfers out), excluded from
///   performance. PF has no cash account, so this is the ledger's external flow;
/// - realized P&L: booked by sells inside the period (part of the market move, not extra).
///
/// Deterministic: the same ledger, prices and window give the same numbers. An asset with
/// no price for a boundary is reported in `missing` and the result is not used.
public enum Attribution {
    public enum Period: String, CaseIterable, Sendable {
        case today, d7 = "7d", d30 = "30d"
        public var label: String { switch self { case .today: "TODAY"; case .d7: "7D"; case .d30: "30D" } }
        /// Matching quote period for the start price (nil for today, which starts at day start).
        public var changePeriod: ChangePeriod? { switch self { case .today: nil; case .d7: .d7; case .d30: .d30 } }
        public var historyRange: ChartRange { switch self { case .today: .d1; case .d7: .w1; case .d30: .m1 } }

        /// Today starts at the local day start (`dayStartHour`); 7D/30D are rolling windows.
        public func start(now: Date, dayStartHour: Int = 0, calendar: Calendar = .current) -> Date {
            switch self {
            case .today:
                var s = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: now) ?? calendar.startOfDay(for: now)
                if s > now { s = calendar.date(byAdding: .day, value: -1, to: s) ?? s }
                return s
            case .d7: return now.addingTimeInterval(-7 * 86400)
            case .d30: return now.addingTimeInterval(-30 * 86400)
            }
        }
    }

    public struct Asset: Equatable, Sendable {
        public let id: AssetID
        public let contribution: Decimal
        public let priceChange: Double?
        public let weightStart: Double
        public let weightEnd: Double
        public let flow: Decimal
        public let bought: Bool
        public let sold: Bool
        public let realized: Decimal
        public var weightDelta: Double { weightEnd - weightStart }
    }

    public struct Result: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let startValue: Decimal
        public let endValue: Decimal
        public let assets: [Asset]
        public let moneyIn: Decimal
        public let moneyOut: Decimal          // ≤ 0
        public let buys: Int
        public let sells: Int
        public let realized: Decimal
        public let missing: [AssetID]

        public var change: Decimal { endValue - startValue }
        public var marketMove: Decimal { assets.reduce(0) { $0 + $1.contribution } }
        public var flows: Decimal { moneyIn + moneyOut }
        public var complete: Bool { missing.isEmpty }
        /// Market move over capital at work (start value + money in), the 0.6 24h basis.
        public var performancePct: Double? {
            let base = startValue + moneyIn
            return base > 0 ? (marketMove / base).double * 100 : nil
        }
        /// Assets ordered by absolute impact.
        public var byImpact: [Asset] { assets.sorted { abs($0.contribution.double) > abs($1.contribution.double) } }
    }

    /// `ledgers`: one transaction list per portfolio in scope (ALL = several), so realized P&L
    /// uses each portfolio's own average cost. `startPrice` gives an asset's price at `start`.
    public static func compute(ledgers: [[Transaction]], endPrices: [AssetID: Decimal], start: Date, end: Date,
                               startPrice: (AssetID) -> Decimal?) -> Result {
        let txs = ledgers.flatMap { $0 }
        let before = PortfolioEngine.positions(ledgers: ledgers, until: start)
        let after = PortfolioEngine.positions(ledgers: ledgers, until: end)
        let window = txs.filter { $0.timestamp > start && $0.timestamp <= end }
        let ids = Set(before.filter { $0.value.quantity > 0 }.keys).union(after.filter { $0.value.quantity > 0 }.keys).union(window.map(\.assetID))

        var rows: [(id: AssetID, q0: Decimal, q1: Decimal, p0: Decimal?, p1: Decimal?, flow: Decimal, bought: Bool, sold: Bool, realized: Decimal)] = []
        var missing: [AssetID] = []
        var moneyIn: Decimal = 0, moneyOut: Decimal = 0
        for id in ids.sorted() {
            let q0 = before[id]?.quantity ?? 0, q1 = after[id]?.quantity ?? 0
            let p1 = endPrices[id]
            let p0: Decimal? = q0 > 0 ? startPrice(id) : (p1 ?? startPrice(id))
            var flow: Decimal = 0, bought = false, sold = false
            for t in window where t.assetID == id {
                let f = PortfolioEngine.externalFlow(t, fallbackPrice: p1)
                flow += f
                if f > 0 { moneyIn += f } else { moneyOut += f }
                if t.type.increases { bought = true } else { sold = true }
            }
            let realized = (after[id]?.realizedPnL ?? 0) - (before[id]?.realizedPnL ?? 0)
            if (q0 > 0 && p0 == nil) || (q1 > 0 && p1 == nil) { missing.append(id) }
            rows.append((id, q0, q1, p0, p1, flow, bought, sold, realized))
        }
        let startValue = rows.reduce(Decimal(0)) { $0 + $1.q0 * ($1.p0 ?? 0) }
        let endValue = rows.reduce(Decimal(0)) { $0 + $1.q1 * ($1.p1 ?? 0) }
        let assets = rows.map { r -> Asset in
            let v0 = r.q0 * (r.p0 ?? 0), v1 = r.q1 * (r.p1 ?? 0)
            return Asset(id: r.id, contribution: v1 - v0 - r.flow,
                         priceChange: (r.p0 ?? 0) > 0 && r.p1 != nil ? ((r.p1! / r.p0!) - 1).double * 100 : nil,
                         weightStart: startValue > 0 ? (v0 / startValue).double * 100 : 0,
                         weightEnd: endValue > 0 ? (v1 / endValue).double * 100 : 0,
                         flow: r.flow, bought: r.bought, sold: r.sold, realized: r.realized)
        }
        return Result(start: start, end: end, startValue: startValue, endValue: endValue, assets: assets,
                      moneyIn: moneyIn, moneyOut: moneyOut, buys: window.filter { $0.type.increases }.count,
                      sells: window.filter { !$0.type.increases }.count,
                      realized: assets.reduce(0) { $0 + $1.realized }, missing: missing)
    }

    /// Why an asset's weight moved (allocation drift CAUSE column).
    public static func cause(_ a: Asset, result r: Result, fmt f: Fmt) -> String {
        var parts: [String] = []
        if a.bought { parts.append("buy") }
        if a.sold { parts.append("sell") }
        if let p = a.priceChange, abs(p) >= 0.05 { parts.append("price " + f.pct(p, 1)) }
        if parts.isEmpty {
            parts.append(r.moneyIn > 0 && a.weightDelta < 0 ? "diluted by money in" : a.weightDelta < 0 ? "others rose faster" : a.weightDelta > 0 ? "others fell faster" : "unchanged")
        }
        return parts.joined(separator: " + ")
    }

    /// One templated sentence from the numbers (never generated text).
    public static func summary(_ r: Result, twr: Double?, period: Period, symbol: (AssetID) -> String, fmt f: Fmt) -> String {
        var s: [String] = []
        let mm = r.marketMove
        let when = period == .today ? "today's" : period == .d7 ? "the week's" : "the 30 days'"
        if let top = r.byImpact.first, top.contribution != 0, mm != 0 {
            let share = abs((top.contribution / mm).double) * 100
            if share > 100 {
                s.append("\(symbol(top.id)) \(top.contribution >= 0 ? "added" : "lost") \(f.money(abs(top.contribution), 0)), more than the whole market move.")
            } else {
                s.append("\(symbol(top.id)) explains \(f.num(share, 0))% of \(when) market move.")
            }
        } else if mm == 0 {
            s.append("No market move in this period.")
        }
        if r.flows != 0 {
            let perf = twr ?? r.performancePct
            let raw = r.startValue > 0 ? (r.change / r.startValue).double * 100 : nil
            var t = "Net money \(r.flows > 0 ? "in" : "out") of \(f.money(abs(r.flows), 0)) \(r.flows > 0 ? "raised" : "lowered") value but is excluded from return"
            if let perf, let raw { t += ", so performance is \(f.pct(perf, 1)), not \(f.pct(raw, 1))" }
            s.append(t + ".")
        }
        if r.realized != 0 { s.append("Sells realized \(f.signed(r.realized, 0)).") }
        if let d = r.assets.max(by: { abs($0.weightDelta) < abs($1.weightDelta) }), abs(d.weightDelta) >= 1 {
            s.append("\(symbol(d.id))'s weight \(d.weightDelta > 0 ? "rose" : "fell") \(f.num(abs(d.weightDelta), 1))pp (\(cause(d, result: r, fmt: f))).")
        }
        return s.joined(separator: " ")
    }
}
