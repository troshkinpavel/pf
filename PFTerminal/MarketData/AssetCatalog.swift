import Foundation

/// Bundled identities for common assets so typing "btc" resolves offline and unambiguously.
/// Anything else is resolved through provider search (CoinGecko id or chain + contract).
enum AssetCatalog {
    /// `id` stays stable even if a provider renames its identifier (`idOverride`).
    private static func a(_ sym: String, _ name: String, _ cg: String, _ bn: String? = nil, id idOverride: String? = nil) -> Asset {
        Asset(id: "cg:" + (idOverride ?? cg), symbol: sym, name: name, coingeckoID: cg, binanceSymbol: bn)
    }

    static let known: [Asset] = [
        a("BTC", "Bitcoin", "bitcoin", "BTCUSDT"),
        a("ETH", "Ethereum", "ethereum", "ETHUSDT"),
        a("SOL", "Solana", "solana", "SOLUSDT"),
        a("BNB", "BNB", "binancecoin", "BNBUSDT"),
        a("XRP", "XRP", "ripple", "XRPUSDT"),
        a("DOGE", "Dogecoin", "dogecoin", "DOGEUSDT"),
        a("ADA", "Cardano", "cardano", "ADAUSDT"),
        a("TRX", "TRON", "tron", "TRXUSDT"),
        a("TON", "Toncoin", "the-open-network", "TONUSDT"),
        a("AVAX", "Avalanche", "avalanche-2", "AVAXUSDT"),
        a("LINK", "Chainlink", "chainlink", "LINKUSDT"),
        a("DOT", "Polkadot", "polkadot", "DOTUSDT"),
        a("POL", "Polygon", "polygon-ecosystem-token", "POLUSDT"),
        a("LTC", "Litecoin", "litecoin", "LTCUSDT"),
        a("ATOM", "Cosmos", "cosmos", "ATOMUSDT"),
        a("UNI", "Uniswap", "uniswap", "UNIUSDT"),
        a("NEAR", "NEAR Protocol", "near", "NEARUSDT"),
        a("ARB", "Arbitrum", "arbitrum", "ARBUSDT"),
        a("OP", "Optimism", "optimism", "OPUSDT"),
        a("SUI", "Sui", "sui", "SUIUSDT"),
        a("PEPE", "Pepe", "pepe", "PEPEUSDT"),
        a("ZEC", "Zcash", "zcash", "ZECUSDT"),
        a("XMR", "Monero", "monero"),
        a("TEL", "Telcoin", "telcoin-2", id: "telcoin"),   // CoinGecko migrated telcoin → telcoin-2
        a("USDC", "USDC", "usd-coin"),
    ]

    static func binanceSymbol(forCoinGecko id: String) -> String? {
        known.first { $0.coingeckoID == id }?.binanceSymbol
    }

    /// Resolve user input against a set of assets: exact symbol, then symbol/name prefix.
    static func resolve(_ q: String, in assets: [Asset]) -> Asset? {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let u = t.uppercased(), l = t.lowercased()
        if let m = assets.first(where: { $0.symbol == u }) { return m }
        if let m = assets.first(where: { $0.id.lowercased() == l || $0.contractAddress?.lowercased() == l }) { return m }
        return assets.first { $0.symbol.lowercased().hasPrefix(l) || $0.name.lowercased().hasPrefix(l) }
    }
}
