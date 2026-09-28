import Foundation
import Testing
@testable import PFCore

/// Which DEX pool prices a token. Fixture: TEL's real pools on 2026-09-29, when the deepest pool
/// (Ethereum) had gone stale at 0.001848 while the traded ones matched the market (~0.00236).
struct DexScreenerSelectionTests {
    let tel = "0x7e13b43065380acdec1c2d138c579cbbbafa0731"

    func pairs(_ rows: [(chain: String, price: String, liq: Double, vol: Double)]) throws -> [DexScreenerProvider.Pair] {
        let json = rows.map { r in
            #"{"chainId":"\#(r.chain)","baseToken":{"address":"\#(tel)","symbol":"TEL"},"priceUsd":"\#(r.price)","liquidity":{"usd":\#(r.liq)},"volume":{"h24":\#(r.vol)}}"#
        }.joined(separator: ",")
        return try JSONDecoder().decode([DexScreenerProvider.Pair].self, from: Data("[\(json)]".utf8))
    }

    @Test func mostTradedPoolWinsOverDeepestStalePool() throws {
        let p = try pairs([("ethereum", "0.001848", 55_480, 543), ("base", "0.002308", 5_844, 1_506),
                           ("polygon", "0.002358", 1_335, 129), ("ethereum", "0.001871", 5, 4)])
        let b = try #require(DexScreenerProvider.best(p))
        #expect(b.chainId == "base" && b.priceUsd == "0.002308")
    }

    @Test func dustPoolsIgnoredEvenWithVolume() throws {
        let p = try pairs([("ethereum", "0.0020", 20_000, 300), ("base", "0.0090", 400, 50_000)])
        #expect(DexScreenerProvider.best(p)?.priceUsd == "0.0020", "a $400 pool can't set the price")
    }

    @Test func onlyDustLeftUsesTheMostLiquid() throws {
        let p = try pairs([("ethereum", "0.0019", 800, 10), ("base", "0.0030", 200, 90)])
        #expect(DexScreenerProvider.best(p)?.priceUsd == "0.0019")
        #expect(DexScreenerProvider.best([]) == nil)
    }

    @Test func sameVolumePrefersDeeperPool() throws {
        let p = try pairs([("base", "0.0021", 2_000, 100), ("polygon", "0.0022", 9_000, 100)])
        #expect(DexScreenerProvider.best(p)?.chainId == "polygon")
    }
}
