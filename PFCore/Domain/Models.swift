import Foundation

/// Canonical internal asset identifier. Never a bare ticker: tickers collide.
/// Conventions: `cg:<coingecko-id>` for listed coins, `dex:<chain>:<contract>` for tokens
/// that only exist on a DEX. See `Asset.makeID`.
public typealias AssetID = String

public struct Asset: Codable, Hashable, Identifiable, Sendable {
    public init(id: AssetID, symbol: String, name: String, coingeckoID: String? = nil, binanceSymbol: String? = nil, chain: String? = nil, contractAddress: String? = nil, decimals: Int? = nil, preferredSource: String? = nil) { self.id = id; self.symbol = symbol; self.name = name; self.coingeckoID = coingeckoID; self.binanceSymbol = binanceSymbol; self.chain = chain; self.contractAddress = contractAddress; self.decimals = decimals; self.preferredSource = preferredSource }
    public var id: AssetID
    public var symbol: String
    public var name: String
    public var coingeckoID: String?
    public var binanceSymbol: String?      // e.g. "BTCUSDT"
    public var chain: String?              // DexScreener chain id, e.g. "ethereum", "base"
    public var contractAddress: String?
    public var decimals: Int?
    /// Market data provider the user pinned for this asset ("CoinGecko", "Binance", "DexScreener").
    /// nil = the app's provider order. Other providers remain fallbacks.
    public var preferredSource: String?

    public static func makeID(coingeckoID: String?, chain: String?, contract: String?, symbol: String) -> AssetID {
        if let c = chain, let a = contract { return "dex:\(c.lowercased()):\(a.lowercased())" }
        if let g = coingeckoID { return "cg:\(g)" }
        return "sym:\(symbol.lowercased())"
    }
}

public enum TransactionType: String, Codable, CaseIterable, Sendable {
    case buy = "BUY", sell = "SELL", transferIn = "TRANSFER_IN", transferOut = "TRANSFER_OUT"

    public var short: String {
        switch self { case .buy: "BUY"; case .sell: "SELL"; case .transferIn: "IN"; case .transferOut: "OUT" }
    }
    public var increases: Bool { self == .buy || self == .transferIn }
}

/// Transactions are the source of truth. Holdings, cost basis and P&L are always derived.
public struct Transaction: Codable, Hashable, Identifiable, Sendable {
    public init(id: UUID = UUID(), portfolioID: UUID = Transaction.unassigned, assetID: AssetID, type: TransactionType, quantity: Decimal, price: Decimal, currency: String = "USD", timestamp: Date, fee: Decimal = 0, note: String? = nil) { self.id = id; self.portfolioID = portfolioID; self.assetID = assetID; self.type = type; self.quantity = quantity; self.price = price; self.currency = currency; self.timestamp = timestamp; self.fee = fee; self.note = note }
    /// Placeholder until migration assigns the owning portfolio (v1 files have none).
    public static let unassigned = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public var id: UUID = UUID()
    public var portfolioID: UUID = Transaction.unassigned
    public var assetID: AssetID
    public var type: TransactionType
    public var quantity: Decimal
    /// Price per unit in `currency`. For transfers this is the carried cost basis per unit (may be 0).
    public var price: Decimal
    public var currency: String = "USD"
    public var timestamp: Date
    /// Fee in `currency`. Added to cost on buys, subtracted from proceeds on sells.
    public var fee: Decimal = 0
    public var note: String?
}

public enum ChangePeriod: String, Codable, CaseIterable, Sendable {
    case h1 = "1H", h24 = "24H", d7 = "7D", d30 = "30D", y1 = "1Y"
    public var seconds: TimeInterval {
        switch self { case .h1: 3600; case .h24: 86400; case .d7: 7 * 86400; case .d30: 30 * 86400; case .y1: 365 * 86400 }
    }
}

public struct Quote: Codable, Hashable, Sendable {
    public init(price: Decimal, change: [ChangePeriod: Double] = [:], marketCap: Decimal? = nil, circulatingSupply: Decimal? = nil, volume24h: Decimal? = nil, ath: Decimal? = nil, source: String, timestamp: Date) { self.price = price; self.change = change; self.marketCap = marketCap; self.circulatingSupply = circulatingSupply; self.volume24h = volume24h; self.ath = ath; self.source = source; self.timestamp = timestamp }
    public var price: Decimal
    /// Percentage change per period, e.g. [.h24: 2.41]
    public var change: [ChangePeriod: Double] = [:]
    public var marketCap: Decimal?
    public var circulatingSupply: Decimal?
    public var volume24h: Decimal?
    public var ath: Decimal?
    public var source: String
    public var timestamp: Date

    public var change24h: Double? { change[.h24] }

    /// Price at the start of `period`, derived from the reported change.
    public func startPrice(_ period: ChangePeriod) -> Decimal? {
        guard let c = change[period], c > -100 else { return nil }
        return price / Decimal.of(1 + c / 100)
    }

    /// Fill missing metadata from another quote without touching the price.
    public func enriched(with other: Quote) -> Quote {
        var q = self
        for (k, v) in other.change where q.change[k] == nil { q.change[k] = v }
        q.marketCap = q.marketCap ?? other.marketCap
        q.circulatingSupply = q.circulatingSupply ?? other.circulatingSupply
        q.volume24h = q.volume24h ?? other.volume24h
        q.ath = q.ath ?? other.ath
        return q
    }
}

public struct PricePoint: Codable, Hashable, Sendable {
    public init(time: Date, price: Double) { self.time = time; self.price = price }
    public var time: Date
    public var price: Double
}

/// A local record of portfolio state, persisted for fast future charting.
public struct PortfolioSnapshotValue: Codable, Hashable, Sendable {
    public init(timestamp: Date, value: Double, costBasis: Double, unrealized: Double) { self.timestamp = timestamp; self.value = value; self.costBasis = costBasis; self.unrealized = unrealized }
    public var timestamp: Date
    public var value: Double
    public var costBasis: Double
    public var unrealized: Double
}
