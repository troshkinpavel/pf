import PFCore
import PFCoreTestSupport
import Foundation
import Testing
@testable import PFTerminal

struct CommandParserTests {
    @Test func tradeCommand() {
        #expect(CommandParser.parse("buy tel 500000 @ .001805") == .trade(.buy, asset: "tel", amount: "500000", price: ".001805"))
        #expect(CommandParser.parse("buy tel 500k@0.0018") == .trade(.buy, asset: "tel", amount: "500k", price: "0.0018"))
        #expect(CommandParser.parse("s btc 0.1 at 90000") == .trade(.sell, asset: "btc", amount: "0.1", price: "90000"))
        #expect(CommandParser.parse("buy eth") == .trade(.buy, asset: "eth", amount: nil, price: nil))
        #expect(CommandParser.parse("transfer in btc 1") == .trade(.transferIn, asset: "btc", amount: "1", price: nil))
    }

    @Test func tradesAlwaysRequireConfirmation() {
        #expect(CommandParser.parse("buy tel 1 @ 1")!.mutates)
        #expect(!CommandParser.parse("movers")!.mutates)
    }

    @Test func targetAndNavigation() {
        #expect(CommandParser.parse("target tel .1") == .target(asset: "tel", value: ".1"))
        #expect(CommandParser.parse("movers") == .navigate(.movers))
        #expect(CommandParser.parse("pnl") == .navigate(.analytics))
        #expect(CommandParser.parse("allocation") == .navigate(.analytics))
        #expect(CommandParser.parse("settings") == .navigate(.settings))
        #expect(CommandParser.parse("portfolio") == .navigate(.overview))
        #expect(CommandParser.parse("tel") == nil)
    }

    @Test func shareCommands() {
        #expect(CommandParser.parse("share") == .share(ShareOverrides()))
        #expect(CommandParser.parse("share 24h") == .share(ShareOverrides(period: .h24)))
        #expect(CommandParser.parse("share 24h public") == .share(ShareOverrides(period: .h24, privacy: .public)))
        #expect(CommandParser.parse("share public portrait phosphor") == .share(ShareOverrides(privacy: .public, format: .portrait, theme: .phosphor)))
    }

    @Test func fuzzy() {
        #expect(Fuzzy.score("mov", "Show biggest winners movers") > 0)
        #expect(Fuzzy.score("xyz", "Open BTC") < 0)
        #expect(Fuzzy.score("open", "Open BTC") > Fuzzy.score("btc", "Open BTC"))
    }
}

struct SharePrivacyTests {
    func model(_ c: ShareConfig) async throws -> ShareCardModel {
        let q = try await MockMarketDataProvider().quotes(for: MockMarketDataProvider.assets, currency: "USD")
        let a = Dictionary(uniqueKeysWithValues: MockMarketDataProvider.assets.map { ($0.id, $0) })
        let txs = DemoPortfolio.transactions()
        let s = PortfolioEngine.summarize(transactions: txs, assets: a, quotes: q)
        let perf = MoversEngine.performance(summary: s, transactions: txs, quotes: q, series: [:], range: .h24, now: Date())
        let mv = MoversEngine.movers(summary: s, transactions: txs, quotes: q, series: [:], range: .h24, now: Date())
        return ShareCardBuilder.build(config: c, summary: s, performance: perf, history: [1, 2, 3, 2, 4], movers: mv, now: Date(), fmt: Fmt())
    }

    @Test func publicIsDefaultAndSafe() {
        let c = ShareConfig()
        #expect(c.privacy == .public)
        #expect(c.level == .safe)
    }

    @Test func publicCardContainsNoMoneyAmounts() async throws {
        var c = ShareConfig()
        c.moverType = .impact
        let m = try await model(c)
        #expect(m.value == nil)
        #expect(m.pnl == nil)
        #expect(m.alloc == nil)
        #expect(m.movers!.allSatisfy { $0.extra.isEmpty })
        #expect(!m.allText.contains { $0.contains("$") }, "no currency amount may reach the bitmap")
        #expect(m.pct == "▲ +3.51%")
    }

    @Test func valueVisibleAddsOnlyTotal() async throws {
        var c = ShareConfig(); c.privacy = .value
        let m = try await model(c)
        #expect(m.value == "$48,286.22")
        #expect(m.pnl == nil)
        #expect(m.movers!.allSatisfy { $0.extra.isEmpty })
        #expect(c.level == .semi)
    }

    @Test func customSensitiveFieldsAreOptIn() async throws {
        var c = ShareConfig(); c.privacy = .custom; c.custom = [.pct, .movers, .posv, .avg, .pnl]
        let m = try await model(c)
        #expect(m.value == nil)                       // not selected, so absent
        #expect(m.pnl != nil)
        #expect(m.movers!.contains { $0.extra.contains("avg") })
        #expect(c.level == .sensitive)
        #expect(c.safeForReuse.privacy == .public, "quick share never reuses a sensitive config")
    }

    @Test func privacyCheckListsHiddenFields() {
        let chk = ShareCardBuilder.privacyCheck(ShareConfig())
        #expect(chk.hidden.contains("✓ portfolio value"))
        #expect(chk.hidden.contains("✓ cost basis"))
        #expect(chk.visible.contains("✓ 24h chart"))
    }
}

struct FormatTests {
    @Test func formats() {
        let f = Fmt()
        #expect(f.money(1234.5) == "$1,234.50")
        #expect(f.signed(-109.0) == "-$109.00")
        #expect(f.pct(0) == "+0.00%")
        #expect(f.price(Double(0.00431)) == "$0.00431")
        #expect(f.price(Double(0.1)) == "$0.10")
        #expect(f.price(Double(91420)) == "$91,420.00")
        #expect(f.amount(Double(3_435_000)) == "3,435,000")
        #expect(f.amount(Double(0.2013)) == "0.2013")
        #expect(f.compact(Double(48286)) == "$48.29k")
        #expect(Fmt(style: .dot).money(1234.5) == "$1.234,50")
        #expect(Fmt(style: .space).num(1234567, 0) == "1 234 567")
    }

    @Test func asciiLineChartShape() {
        let rows = AsciiChart.render([0, 1, 2], height: 3, style: .line) { _ in "" }
        #expect(rows.map(\.plot) == [" ╭", "╭╯", "╯ "])
    }
}

/// Provider routing with mocks — no network.
struct RouterTests {
    struct Stub: MarketDataProvider {
        let name: String
        var result: Result<Decimal, MarketError>
        var withSupply = false
        func supports(_ a: Asset) -> Bool { true }
        func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
            let p = try result.get()
            return Dictionary(uniqueKeysWithValues: assets.map {
                ($0.id, Quote(price: p, circulatingSupply: withSupply ? 1000 : nil, source: name, timestamp: Date()))
            })
        }
    }

    let btc = AssetCatalog.known[0]

    struct SearchStub: MarketDataProvider {
        let name = "CoinGecko"
        func supports(_ a: Asset) -> Bool { true }
        func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] { throw MarketError.rateLimited(retryAfter: 60) }
        func search(_ query: String) async throws -> [Asset] {
            [Asset(id: "cg:tether", symbol: "USDT", name: "Tether", coingeckoID: "tether")]
        }
    }

    @Test func searchRespectsBackoffWhileLocalRegistrySearchStillWorks() async {
        let r = ProviderRouter(providers: [SearchStub()])
        _ = await r.quotes(for: [btc], currency: "USD")
        #expect(await r.isBlocked("CoinGecko"), "quotes put it in backoff")
        #expect(await r.search("usdt").isEmpty, "online search doesn't bypass a 429 backoff")
        #expect(AssetRegistry.shared.search("usdt").first?.coingeckoId == "tether", "discovery still works locally")
    }

    @Test func usdtResolvesOfflineToTether() {
        let a = AssetCatalog.resolve("USDT", in: AssetCatalog.known)
        #expect(a?.id == "cg:tether" && a?.coingeckoID == "tether" && a?.binanceSymbol == nil)
        #expect(AssetCatalog.resolve("USDC", in: AssetCatalog.known)?.id == "cg:usd-coin")
    }

    @Test func fallsBackWhenPrimaryFails() async {
        let r = ProviderRouter(providers: [Stub(name: "A", result: .failure(.rateLimited(retryAfter: 30))), Stub(name: "B", result: .success(5))])
        let out = await r.quotes(for: [btc], currency: "USD")
        #expect(out.quotes[btc.id]?.source == "B")
        #expect(out.errors["A"] == .rateLimited(retryAfter: 30))
        #expect(await r.isBlocked("A"))
    }

    @Test func primaryWinsAndMetadataIsEnriched() async {
        // Price from the routed exchange; supply etc. from CoinGecko (the only metadata source).
        let r = ProviderRouter(providers: [Stub(name: "Binance", result: .success(1)), Stub(name: "CoinGecko", result: .success(2), withSupply: true)])
        let out = await r.quotes(for: [btc], currency: "USD")
        #expect(out.quotes[btc.id]?.price == 1)
        #expect(out.quotes[btc.id]?.circulatingSupply == 1000)
    }

    @Test func unresolvedWhenAllFail() async {
        let r = ProviderRouter(providers: [Stub(name: "A", result: .failure(.offline))])
        let out = await r.quotes(for: [btc], currency: "USD")
        #expect(out.quotes.isEmpty)
        #expect(out.unresolved == [btc.id])
    }
}

struct BackupTests {
    @Test func roundTripPreservesDecimals() throws {
        let main = UUID()
        let doc = PortfolioDocument(portfolios: [PortfolioInfo(id: main, name: "MAIN", glyph: "◈", createdAt: Date())],
                                    assets: MockMarketDataProvider.assets, transactions: DemoPortfolio.transactions(portfolio: main))
        let back = try PortfolioDocument.load(try doc.encoded())
        #expect(back.transactions == doc.transactions)
        #expect(String(data: try doc.encoded(), encoding: .utf8)!.contains("\"0.00241\""))
    }

    @Test func rejectsInvalidBackups() {
        #expect(throws: PortfolioDocument.ImportError.self) { try PortfolioDocument.load(Data("{}".utf8)) }
        #expect(throws: PortfolioDocument.ImportError.self) { try PortfolioDocument.load(Data("{\"schemaVersion\":99}".utf8)) }
        let main = UUID()
        var doc = PortfolioDocument(portfolios: [PortfolioInfo(id: main, name: "MAIN", glyph: "◈", createdAt: Date())], assets: [], transactions: DemoPortfolio.transactions(portfolio: main))
        #expect(throws: PortfolioDocument.ImportError.self) { try PortfolioDocument.load(try doc.encoded()) }   // unknown assets
        doc.assets = MockMarketDataProvider.assets
        doc.transactions.append(Transaction(portfolioID: main, assetID: "cg:bitcoin", type: .sell, quantity: 5, price: 1, timestamp: Date()))
        #expect(throws: PortfolioDocument.ImportError.self) { try PortfolioDocument.load(try doc.encoded()) }   // oversold
    }
}
