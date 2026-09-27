import Foundation

/// Canonical internal asset identifier. Never a bare ticker: tickers collide.
/// Conventions: `cg:<coingecko-id>` for listed coins, `dex:<chain>:<contract>` for tokens
/// that only exist on a DEX. See `Asset.makeID`.
typealias AssetID = String

struct Asset: Codable, Hashable, Identifiable, Sendable {
    var id: AssetID
    var symbol: String
    var name: String
    var coingeckoID: String?
    var binanceSymbol: String?      // e.g. "BTCUSDT"
    var chain: String?              // DexScreener chain id, e.g. "ethereum", "base"
    var contractAddress: String?
    var decimals: Int?
    /// Market data provider the user pinned for this asset ("CoinGecko", "Binance", "DexScreener").
    /// nil = the app's provider order. Other providers remain fallbacks.
    var preferredSource: String?

    static func makeID(coingeckoID: String?, chain: String?, contract: String?, symbol: String) -> AssetID {
        if let c = chain, let a = contract { return "dex:\(c.lowercased()):\(a.lowercased())" }
        if let g = coingeckoID { return "cg:\(g)" }
        return "sym:\(symbol.lowercased())"
    }
}

enum TransactionType: String, Codable, CaseIterable, Sendable {
    case buy = "BUY", sell = "SELL", transferIn = "TRANSFER_IN", transferOut = "TRANSFER_OUT"

    var short: String {
        switch self { case .buy: "BUY"; case .sell: "SELL"; case .transferIn: "IN"; case .transferOut: "OUT" }
    }
    var increases: Bool { self == .buy || self == .transferIn }
}

/// Transactions are the source of truth. Holdings, cost basis and P&L are always derived.
struct Transaction: Codable, Hashable, Identifiable, Sendable {
    /// Placeholder until migration assigns the owning portfolio (v1 files have none).
    static let unassigned = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var id: UUID = UUID()
    var portfolioID: UUID = Transaction.unassigned
    var assetID: AssetID
    var type: TransactionType
    var quantity: Decimal
    /// Price per unit in `currency`. For transfers this is the carried cost basis per unit (may be 0).
    var price: Decimal
    var currency: String = "USD"
    var timestamp: Date
    /// Fee in `currency`. Added to cost on buys, subtracted from proceeds on sells.
    var fee: Decimal = 0
    var note: String?
}

enum ChangePeriod: String, Codable, CaseIterable, Sendable {
    case h1 = "1H", h24 = "24H", d7 = "7D", d30 = "30D", y1 = "1Y"
    var seconds: TimeInterval {
        switch self { case .h1: 3600; case .h24: 86400; case .d7: 7 * 86400; case .d30: 30 * 86400; case .y1: 365 * 86400 }
    }
}

struct Quote: Codable, Hashable, Sendable {
    var price: Decimal
    /// Percentage change per period, e.g. [.h24: 2.41]
    var change: [ChangePeriod: Double] = [:]
    var marketCap: Decimal?
    var circulatingSupply: Decimal?
    var volume24h: Decimal?
    var ath: Decimal?
    var source: String
    var timestamp: Date

    var change24h: Double? { change[.h24] }

    /// Price at the start of `period`, derived from the reported change.
    func startPrice(_ period: ChangePeriod) -> Decimal? {
        guard let c = change[period], c > -100 else { return nil }
        return price / Decimal.of(1 + c / 100)
    }

    /// Fill missing metadata from another quote without touching the price.
    func enriched(with other: Quote) -> Quote {
        var q = self
        for (k, v) in other.change where q.change[k] == nil { q.change[k] = v }
        q.marketCap = q.marketCap ?? other.marketCap
        q.circulatingSupply = q.circulatingSupply ?? other.circulatingSupply
        q.volume24h = q.volume24h ?? other.volume24h
        q.ath = q.ath ?? other.ath
        return q
    }
}

struct PricePoint: Codable, Hashable, Sendable {
    var time: Date
    var price: Double
}

/// A local record of portfolio state, persisted for fast future charting.
struct PortfolioSnapshotValue: Codable, Hashable, Sendable {
    var timestamp: Date
    var value: Double
    var costBasis: Double
    var unrealized: Double
}
