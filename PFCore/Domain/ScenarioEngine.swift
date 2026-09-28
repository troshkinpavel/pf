import Foundation

/// Target-price scenario for current holdings. A calculator, never a prediction.
public struct Scenario: Hashable, Sendable {
    public init(target: Decimal, deltaPct: Double, positionValue: Decimal, profit: Decimal, returnPct: Double? = nil, multiple: Double? = nil, impliedMarketCap: Decimal? = nil, portfolioValue: Decimal, shareOfPortfolio: Double, vsATH: Double? = nil) { self.target = target; self.deltaPct = deltaPct; self.positionValue = positionValue; self.profit = profit; self.returnPct = returnPct; self.multiple = multiple; self.impliedMarketCap = impliedMarketCap; self.portfolioValue = portfolioValue; self.shareOfPortfolio = shareOfPortfolio; self.vsATH = vsATH }
    public let target: Decimal
    public let deltaPct: Double            // target vs current price
    public let positionValue: Decimal
    public let profit: Decimal             // vs cost basis
    public let returnPct: Double?
    public let multiple: Double?           // position value / cost basis
    public let impliedMarketCap: Decimal?  // only with reliable circulating supply
    public let portfolioValue: Decimal     // other positions held at current prices
    public let shareOfPortfolio: Double
    public let vsATH: Double?
}

public enum ScenarioEngine {
    public static func evaluate(
        target: Decimal, quantity: Decimal, costBasis: Decimal, currentPrice: Decimal,
        portfolioTotal: Decimal, circulatingSupply: Decimal?, ath: Decimal?
    ) -> Scenario {
        let v = quantity * target
        let profit = v - costBasis
        let rest = portfolioTotal - quantity * currentPrice
        let pf = rest + v
        return Scenario(
            target: target,
            deltaPct: currentPrice > 0 ? ((target / currentPrice) - 1).double * 100 : 0,
            positionValue: v,
            profit: profit,
            returnPct: costBasis > 0 ? (profit / costBasis).double * 100 : nil,
            multiple: costBasis > 0 ? (v / costBasis).double : nil,
            impliedMarketCap: circulatingSupply.flatMap { $0 > 0 ? $0 * target : nil },
            portfolioValue: pf,
            shareOfPortfolio: pf > 0 ? (v / pf).double * 100 : 0,
            vsATH: ath.flatMap { $0 > 0 ? (target / $0).double : nil })
    }

    /// Five "round" price levels above the current price, spread on a log scale.
    public static func presets(for price: Decimal) -> [Decimal] {
        let p = price.double
        guard p > 0 else { return [] }
        let mantissas: [Double] = [1, 1.5, 2, 2.5, 5, 7.5]
        func nice(_ x: Double) -> Double {
            let e = floor(log10(x)), base = pow(10, e)
            let cands = (mantissas + [10]).map { $0 * base }
            return cands.min { abs(log($0 / x)) < abs(log($1 / x)) }!
        }
        var out: [Double] = []
        for m in [1.5, 3, 5, 10, 25] {
            var n = nice(p * m)
            if n <= p * 1.05 { n = nice(p * m * 1.5) }
            if let last = out.last, n <= last * 1.05 { continue }
            out.append(n)
        }
        return out.map { Decimal.of($0) }
    }
}
