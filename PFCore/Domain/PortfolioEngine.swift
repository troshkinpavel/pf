import Foundation

/// Holdings derived from a transaction ledger (average-cost method).
struct Position: Hashable, Sendable {
    let assetID: AssetID
    var quantity: Decimal = 0
    var costBasis: Decimal = 0
    var realizedPnL: Decimal = 0
    var transactions: [Transaction] = []

    var averageEntry: Decimal? { quantity > 0 ? costBasis / quantity : nil }
    var isOpen: Bool { quantity > 0 }
}

enum LedgerError: Error, Equatable, CustomStringConvertible {
    case nonPositiveQuantity(UUID)
    case negativePrice(UUID)
    case negativeFee(UUID)
    case oversold(UUID, held: Decimal, requested: Decimal)
    case unknownAsset(UUID, AssetID)

    var description: String {
        switch self {
        case .nonPositiveQuantity: "quantity must be greater than 0"
        case .negativePrice: "price cannot be negative"
        case .negativeFee: "fee cannot be negative"
        case let .oversold(_, held, _): "only \(held) held at that date"
        case let .unknownAsset(_, a): "unknown asset \(a)"
        }
    }
}

enum PortfolioEngine {
    /// Stable chronological order: timestamp, then original ledger order.
    static func ordered(_ txs: [Transaction]) -> [Transaction] {
        txs.enumerated().sorted { a, b in
            a.element.timestamp != b.element.timestamp ? a.element.timestamp < b.element.timestamp : a.offset < b.offset
        }.map(\.element)
    }

    /// Apply one transaction to a position. Pure; used by every derivation below.
    static func apply(_ t: Transaction, to p: inout Position) {
        p.transactions.append(t)
        switch t.type {
        case .buy:
            p.quantity += t.quantity
            p.costBasis += t.quantity * t.price + t.fee
        case .transferIn:
            p.quantity += t.quantity
            p.costBasis += t.quantity * t.price + t.fee
        case .sell, .transferOut:
            let q = min(t.quantity, p.quantity)
            guard q > 0 else { return }
            // A full exit removes exactly the remaining cost (no division residue).
            let removedCost = q == p.quantity ? p.costBasis : (p.costBasis / p.quantity) * q
            if t.type == .sell {
                p.realizedPnL += q * t.price - t.fee - removedCost
            } else {
                p.realizedPnL -= t.fee
            }
            p.costBasis -= removedCost
            p.quantity -= q
            if p.quantity == 0 { p.costBasis = 0 }
        }
    }

    static func positions(_ txs: [Transaction], until date: Date? = nil) -> [AssetID: Position] {
        var out: [AssetID: Position] = [:]
        for t in ordered(txs) {
            if let d = date, t.timestamp > d { break }
            var p = out[t.assetID] ?? Position(assetID: t.assetID)
            apply(t, to: &p)
            out[t.assetID] = p
        }
        return out
    }

    /// Aggregate of independent ledgers (the ALL context). Each portfolio is computed with its own
    /// average cost, then quantities, cost basis and realized P&L are summed — merging the raw
    /// transactions instead would re-average sells across portfolios and misstate both.
    static func positions(ledgers: [[Transaction]], until date: Date? = nil) -> [AssetID: Position] {
        if ledgers.count == 1 { return positions(ledgers[0], until: date) }
        var out: [AssetID: Position] = [:]
        for l in ledgers {
            for (id, p) in positions(l, until: date) {
                var m = out[id] ?? Position(assetID: id)
                m.quantity += p.quantity
                m.costBasis += p.costBasis
                m.realizedPnL += p.realizedPnL
                m.transactions += p.transactions
                out[id] = m
            }
        }
        for id in out.keys { out[id]!.transactions = ordered(out[id]!.transactions) }
        return out
    }

    /// Validates a ledger before it is committed. Sells may never exceed holdings at their date.
    static func validate(_ txs: [Transaction], knownAssets: Set<AssetID>? = nil) -> [LedgerError] {
        var errors: [LedgerError] = []
        var held: [AssetID: Decimal] = [:]
        for t in ordered(txs) {
            if let k = knownAssets, !k.contains(t.assetID) { errors.append(.unknownAsset(t.id, t.assetID)) }
            if t.quantity <= 0 { errors.append(.nonPositiveQuantity(t.id)); continue }
            if t.price < 0 { errors.append(.negativePrice(t.id)) }
            if t.fee < 0 { errors.append(.negativeFee(t.id)) }
            let h = held[t.assetID] ?? 0
            if t.type.increases {
                held[t.assetID] = h + t.quantity
            } else if t.quantity > h {
                errors.append(.oversold(t.id, held: h, requested: t.quantity))
                held[t.assetID] = 0
            } else {
                held[t.assetID] = h - t.quantity
            }
        }
        return errors
    }

    /// Value moving into (+) or out of (−) a position through a transaction.
    static func externalFlow(_ t: Transaction, fallbackPrice: Decimal?) -> Decimal {
        switch t.type {
        case .buy: return t.quantity * t.price + t.fee
        case .sell: return -(t.quantity * t.price - t.fee)
        case .transferIn: return t.quantity * (t.price > 0 ? t.price : (fallbackPrice ?? 0))
        case .transferOut: return -t.quantity * (t.price > 0 ? t.price : (fallbackPrice ?? 0))
        }
    }

    /// Absolute value change of each asset over [start, now] net of external flows.
    /// contribution = qty_now·p_now − qty_start·p_start − Σflows(start, now]
    /// This is the asset's contribution to the portfolio's move, not its price change.
    static func contributions(
        _ txs: [Transaction], quotes: [AssetID: Quote], start: Date, now: Date,
        startPrice: (AssetID) -> Decimal?
    ) -> [AssetID: (contribution: Decimal, startValue: Decimal, inflow: Decimal)] {
        let before = positions(txs, until: start)
        let after = positions(txs, until: now)
        var out: [AssetID: (Decimal, Decimal, Decimal)] = [:]
        for id in Set(before.keys).union(after.keys) {
            guard let q = quotes[id] else { continue }
            let qStart = before[id]?.quantity ?? 0, qNow = after[id]?.quantity ?? 0
            if qStart == 0 && qNow == 0 && !txs.contains(where: { $0.assetID == id && $0.timestamp > start && $0.timestamp <= now }) { continue }
            guard let p0 = qStart > 0 ? startPrice(id) : q.price else { continue }
            var flow: Decimal = 0, inflow: Decimal = 0
            for t in txs where t.assetID == id && t.timestamp > start && t.timestamp <= now {
                let f = externalFlow(t, fallbackPrice: q.price)
                flow += f
                if f > 0 { inflow += f }
            }
            let startValue = qStart * p0
            out[id] = (qNow * q.price - startValue - flow, startValue, inflow)
        }
        return out
    }
}

// MARK: - Valuation

struct PositionValuation: Identifiable, Hashable, Sendable {
    var id: AssetID { asset.id }
    let asset: Asset
    let position: Position
    let quote: Quote?

    var price: Decimal? { quote?.price }
    var value: Decimal? { price.map { $0 * position.quantity } }
    var unrealized: Decimal? { value.map { $0 - position.costBasis } }
    var returnPct: Double? {
        guard let u = unrealized, position.costBasis > 0 else { return nil }
        return (u / position.costBasis).double * 100
    }
    var change24h: Double? { quote?.change24h }
    /// 24h contribution to portfolio value (set by the summary; accounts for intraday transactions).
    var contribution24h: Decimal?
    var allocation: Double?

    init(asset: Asset, position: Position, quote: Quote?) {
        self.asset = asset; self.position = position; self.quote = quote
    }
}

struct Ranked: Hashable, Sendable {
    let symbol: String
    let assetID: AssetID
    let value: Double
}

struct PortfolioSummary: Sendable {
    var positions: [PositionValuation]          // open positions, value desc (unpriced last)
    var closed: [Position]                      // fully exited, realized only
    var totalValue: Decimal                     // priced positions only
    var unpriced: [AssetID]                     // open positions without a quote
    var costBasis: Decimal
    var unrealized: Decimal
    var realized: Decimal
    var change24h: Decimal?
    var change24hPct: Double?
    var driver: (valuation: PositionValuation, share: Double)?
    var best: Ranked?, worst: Ranked?
    var best24: Ranked?, worst24: Ranked?
    var transactionCount: Int
    var firstDate: Date?

    var isPartial: Bool { !unpriced.isEmpty }
    var isEmpty: Bool { positions.isEmpty }
    var totalPnL: Decimal { unrealized + realized }
    /// Unrealized return on current cost basis.
    var returnPct: Double? { costBasis > 0 ? (unrealized / costBasis).double * 100 : nil }

    func valuation(_ id: AssetID) -> PositionValuation? { positions.first { $0.asset.id == id } }
}

extension PortfolioEngine {
    static func summarize(
        transactions: [Transaction], assets: [AssetID: Asset], quotes: [AssetID: Quote], now: Date = Date()
    ) -> PortfolioSummary {
        summarize(ledgers: [transactions], assets: assets, quotes: quotes, now: now)
    }

    /// Summary for a context: one ledger per portfolio in scope.
    static func summarize(
        ledgers: [[Transaction]], assets: [AssetID: Asset], quotes: [AssetID: Quote], now: Date = Date()
    ) -> PortfolioSummary {
        let transactions = ledgers.flatMap { $0 }   // quantities and flows are additive across ledgers
        let pos = positions(ledgers: ledgers, until: now)
        var vals: [PositionValuation] = []
        var closed: [Position] = []
        for (id, p) in pos {
            guard let a = assets[id] else { continue }
            if p.isOpen { vals.append(PositionValuation(asset: a, position: p, quote: quotes[id])) } else { closed.append(p) }
        }
        let priced = vals.filter { $0.value != nil }
        let total = priced.reduce(Decimal(0)) { $0 + ($1.value ?? 0) }
        let cost = priced.reduce(Decimal(0)) { $0 + $1.position.costBasis }
        let realized = pos.values.reduce(Decimal(0)) { $0 + $1.realizedPnL }

        // 24h contributions, flow-adjusted.
        let start = now.addingTimeInterval(-86400)
        let contrib = contributions(transactions, quotes: quotes, start: start, now: now) { quotes[$0]?.startPrice(.h24) }
        let hasAll24 = priced.allSatisfy { $0.change24h != nil }
        var d24: Decimal? = nil, d24p: Double? = nil
        if hasAll24, !priced.isEmpty {
            let sum = contrib.values.reduce(Decimal(0)) { $0 + $1.contribution }
            let denom = contrib.values.reduce(Decimal(0)) { $0 + $1.startValue + $1.inflow }
            d24 = sum
            d24p = denom > 0 ? (sum / denom).double * 100 : nil
        }
        for i in vals.indices {
            vals[i].contribution24h = contrib[vals[i].asset.id]?.contribution
            if let v = vals[i].value, total > 0 { vals[i].allocation = (v / total).double * 100 }
        }
        vals.sort { ($0.value ?? -1) > ($1.value ?? -1) }

        var s = PortfolioSummary(
            positions: vals, closed: closed, totalValue: total,
            unpriced: vals.filter { $0.value == nil }.map(\.asset.id),
            costBasis: cost, unrealized: total - cost, realized: realized,
            change24h: d24, change24hPct: d24p, transactionCount: transactions.count,
            firstDate: ordered(transactions).first?.timestamp)

        if let d = d24, d != 0,
           let drv = vals.filter({ $0.contribution24h != nil }).max(by: { abs($0.contribution24h!.double) < abs($1.contribution24h!.double) }) {
            s.driver = (drv, (drv.contribution24h! / d).double * 100)
        }
        let byRet = vals.compactMap { v in v.returnPct.map { Ranked(symbol: v.asset.symbol, assetID: v.asset.id, value: $0) } }.sorted { $0.value > $1.value }
        s.best = byRet.first; s.worst = byRet.count > 1 ? byRet.last : nil
        let by24 = vals.compactMap { v in v.change24h.map { Ranked(symbol: v.asset.symbol, assetID: v.asset.id, value: $0) } }.sorted { $0.value > $1.value }
        s.best24 = by24.first; s.worst24 = by24.count > 1 ? by24.last : nil
        return s
    }
}
