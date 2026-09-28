import PFCore
import Foundation

// Deterministic sample snapshots for previews and the widget gallery. Never written to disk,
// never shown when the app has published a real snapshot.

extension WidgetPortfolioSnapshot {
    public static func previewPositive(now: Date) -> WidgetPortfolioSnapshot { sample(now: now) }

    public static func previewNegative(now: Date) -> WidgetPortfolioSnapshot {
        var s = sample(now: now, sign: -1)
        s.dailyChangeValue = -1_702.35; s.dailyChangePercent = -3.42; s.performanceChangePercent = -3.42
        s.unrealizedPnL = -4_011.48; s.unrealizedPnLPercent = -10.8
        return s
    }

    public static func previewPrivacy(now: Date) -> WidgetPortfolioSnapshot {
        var s = sample(now: now)
        s.privacyMode = .percentageOnly
        s.portfolioValue = nil; s.dailyChangeValue = nil; s.unrealizedPnL = nil
        s.gainers = s.gainers.map { WidgetMover(id: $0.id, symbol: $0.symbol, changePercent: $0.changePercent, impact: nil) }
        s.impact = s.impact.map { WidgetMover(id: $0.id, symbol: $0.symbol, changePercent: $0.changePercent, impact: nil) }
        s.positions = s.positions.map { WidgetPosition(id: $0.id, symbol: $0.symbol, value: nil, allocation: $0.allocation, change24h: $0.change24h, returnPercent: $0.returnPercent) }
        return s
    }

    public static func previewStale(now: Date) -> WidgetPortfolioSnapshot {
        var s = sample(now: now)
        s.generatedAt = now.addingTimeInterval(-3 * 3600); s.quotesAsOf = s.generatedAt
        return s
    }

    public static func previewEmpty(now: Date) -> WidgetPortfolioSnapshot {
        var s = sample(now: now)
        s.hasPortfolio = false; s.portfolioValue = nil; s.positions = []; s.gainers = []; s.impact = []; s.performance = []
        return s
    }

    private static func sample(now: Date, sign: Double = 1) -> WidgetPortfolioSnapshot {
        let movers: [(String, String, Double, Decimal)] = [("cg:telcoin", "TEL", 8.72, 1_187.44), ("cg:bitcoin", "BTC", 2.41, 433.07),
                                                           ("cg:ethereum", "ETH", 1.87, 127.73), ("cg:zcash", "ZEC", -1.32, -108.62)]
        let gainers = movers.map { WidgetMover(id: $0.0, symbol: $0.1, changePercent: $0.2 * sign, impact: $0.3 * Decimal(sign)) }
        let positions: [(String, String, Decimal, Double, Double, Double)] = [
            ("cg:bitcoin", "BTC", 18_402.85, 38.1, 2.41, 38.1), ("cg:telcoin", "TEL", 14_804.85, 30.7, 8.72, 131.8),
            ("cg:zcash", "ZEC", 8_120.45, 16.8, -1.32, 21.4), ("cg:ethereum", "ETH", 6_958.08, 14.4, 1.87, 17.8),
        ]
        // A stepped 24h path with a dip and a recovery, like the app's chart.
        let shape: [Double] = [0.30, 0.30, 0.34, 0.26, 0.22, 0.22, 0.28, 0.40, 0.46, 0.44, 0.52, 0.50, 0.48, 0.58, 0.64, 0.62, 0.70, 0.66, 0.72, 0.80, 0.78, 0.86, 0.92, 1.00]
        let pts = shape.enumerated().map { i, v in
            WidgetPerformancePoint(timestamp: now.addingTimeInterval(-86400 + Double(i) * 86400 / Double(shape.count - 1)), normalizedValue: sign > 0 ? v : 1 - v)
        }
        var s = WidgetPortfolioSnapshot(
            generatedAt: now.addingTimeInterval(-120), quotesAsOf: now.addingTimeInterval(-120), refreshInterval: 300, isStale: false, hasPortfolio: true,
            portfolioValue: 48_098.97, dailyChangeValue: 1_634.21, dailyChangePercent: 3.52 * sign,
            unrealizedPnL: 15_977.52, unrealizedPnLPercent: 49.45,
            gainers: gainers.sorted { $0.changePercent > $1.changePercent },
            impact: gainers.sorted { abs(($0.impact ?? 0).double) > abs(($1.impact ?? 0).double) },
            positions: positions.map { WidgetPosition(id: $0.0, symbol: $0.1, value: $0.2, allocation: $0.3, change24h: $0.4 * sign, returnPercent: $0.5) },
            performance: pts, performanceRange: "24H", performanceChangePercent: 3.52 * sign,
            privacyMode: .full, currencyCode: "USD", numberStyle: .comma)
        s.contextID = "sample-main"; s.contextName = "MAIN"; s.contextGlyph = "◈"
        return s
    }
}

