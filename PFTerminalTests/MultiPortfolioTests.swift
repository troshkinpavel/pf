import Foundation
import Testing
@testable import PFTerminal

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
private func day(_ s: String) -> Date { DateFmt.parseYMD(s)! }
private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
private let eth = AssetCatalog.known.first { $0.symbol == "ETH" }!

private func tx(_ pf: UUID, _ type: TransactionType, _ q: String, _ p: String, _ date: String, asset: Asset = btc) -> Transaction {
    Transaction(portfolioID: pf, assetID: asset.id, type: type, quantity: d(q), price: d(p), timestamp: day(date))
}
private func quote(_ p: String, ch24: Double = 0) -> Quote {
    Quote(price: d(p), change: [.h24: ch24], source: "test", timestamp: Date())
}

/// MAIN: 1 BTC @100 · TRADING: 1 BTC @200 then sells 0.5 @300, 10 ETH @10 · ARCHIVE: 5 BTC @50 (archived)
private func book() -> (PortfolioDocument, main: UUID, trading: UUID, archived: UUID) {
    var doc = PortfolioDocument.fresh(now: day("2024-01-01"))
    let main = doc.portfolios[0].id
    let trading = try! doc.createPortfolio(name: "trading", glyph: "⇄").id
    let arch = try! doc.createPortfolio(name: "old", glyph: "#").id
    doc.assets = [btc, eth]
    doc.transactions = [
        tx(main, .buy, "1", "100", "2024-01-02"),
        tx(trading, .buy, "1", "200", "2024-02-01"), tx(trading, .sell, "0.5", "300", "2024-03-01"),
        tx(trading, .buy, "10", "10", "2024-02-02", asset: eth),
        tx(arch, .buy, "5", "50", "2024-01-05"),
    ]
    try! doc.setArchived(arch, true)
    return (doc, main, trading, arch)
}

struct MigrationTests {
    static let v1 = """
    {"schemaVersion":1,"app":"pf Terminal","portfolio":{"name":"main","isDemo":false,"createdAt":"2025-01-01T00:00:00Z"},
     "assets":[{"id":"cg:bitcoin","symbol":"BTC","name":"Bitcoin","coingeckoID":"bitcoin"}],
     "transactions":[
       {"id":"6F1C2A3B-0000-0000-0000-000000000001","assetID":"cg:bitcoin","type":"BUY","quantity":"0.12","price":"58400","currency":"USD","timestamp":"2024-09-06T12:00:00Z","fee":"1.5"},
       {"id":"6F1C2A3B-0000-0000-0000-000000000002","assetID":"cg:bitcoin","type":"SELL","quantity":"0.02","price":"90000","currency":"USD","timestamp":"2025-02-01T12:00:00Z","fee":"0","note":"trim"}]}
    """

    @Test func v1BecomesMainWithEverythingPreserved() throws {
        let doc = try PortfolioDocument.load(Data(Self.v1.utf8))
        #expect(doc.schemaVersion == 2)
        #expect(doc.portfolios.map(\.name) == ["MAIN"])
        #expect(doc.portfolios[0].glyph == "◈")
        #expect(doc.portfolios[0].createdAt <= ISO8601DateFormatter().date(from: "2024-09-06T12:00:00Z")!, "created no later than the first transaction")
        let main = doc.portfolios[0].id
        #expect(doc.transactions.count == 2)
        #expect(doc.transactions.allSatisfy { $0.portfolioID == main })
        #expect(doc.transactions[0].quantity == d("0.12") && doc.transactions[0].price == 58400 && doc.transactions[0].fee == d("1.5"))
        #expect(doc.transactions[1].note == "trim")
        #expect(doc.transactions[0].id.uuidString == "6F1C2A3B-0000-0000-0000-000000000001")
    }

    @Test func migrationIsIdempotent() throws {
        let once = try PortfolioDocument.load(Data(Self.v1.utf8))
        let twice = PortfolioDocument.migrate(once)
        #expect(twice == once)
        let reloaded = try PortfolioDocument.load(once.encoded())
        #expect(reloaded == once)
    }

    @Test func loadingV1KeepsABackupOfTheOriginalFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-mig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PortfolioStore(directory: dir)
        try Data(Self.v1.utf8).write(to: store.fileURL)
        let doc = try #require(try store.load())
        #expect(doc.portfolios.count == 1)
        let backup = dir.appendingPathComponent("portfolio.v1-backup.json")
        #expect(try Data(contentsOf: backup) == Data(Self.v1.utf8))
        try store.save(doc)
        #expect(try store.load() == doc)
    }
}

struct PortfolioCRUDTests {
    @Test func createValidatesNames() throws {
        var doc = PortfolioDocument.fresh()
        let p = try doc.createPortfolio(name: "  long   term ", glyph: "∞")
        #expect(p.name == "LONG TERM")
        #expect(throws: PortfolioError.emptyName) { try doc.createPortfolio(name: "   ", glyph: "◆") }
        #expect(throws: PortfolioError.duplicateName("LONG TERM")) { try doc.createPortfolio(name: "Long Term", glyph: "◆") }
        #expect(doc.portfolios.count == 2)
    }

    @Test func renameKeepsIdentityAndTransactions() throws {
        var (doc, _, trading, _) = book()
        let before = doc.transactions(.portfolio(trading))
        try doc.renamePortfolio(trading, to: "swing")
        #expect(doc.portfolio(trading)?.name == "SWING")
        #expect(doc.transactions(.portfolio(trading)) == before)
        #expect(throws: PortfolioError.duplicateName("MAIN")) { try doc.renamePortfolio(trading, to: "main") }
    }

    @Test func archiveUnarchiveAndLastActiveGuard() throws {
        var (doc, main, trading, arch) = book()
        #expect(doc.livePortfolios.map(\.id) == [main, trading])
        try doc.setArchived(arch, false)
        #expect(doc.livePortfolios.count == 3)
        try doc.setArchived(arch, true); try doc.setArchived(trading, true)
        #expect(throws: PortfolioError.lastActivePortfolio) { try doc.setArchived(main, true) }
        #expect(doc.transactions.count == 5, "archive keeps every transaction")
    }

    @Test func deleteRemovesOnlyThatPortfolio() throws {
        var (doc, main, trading, _) = book()
        let mainTxs = doc.transactions(.portfolio(main))
        try doc.deletePortfolio(trading)
        #expect(doc.portfolio(trading) == nil)
        #expect(!doc.transactions.contains { $0.portfolioID == trading })
        #expect(doc.transactions(.portfolio(main)) == mainTxs)
        #expect(doc.assets.contains(eth), "shared asset identities stay")
        #expect(throws: PortfolioError.lastActivePortfolio) { try doc.deletePortfolio(main) }
    }

    @Test func invalidContextFallsBack() {
        let (doc, main, _, arch) = book()
        #expect(doc.validContext(.portfolio(arch)) == .portfolio(main))
        #expect(doc.validContext(.portfolio(UUID())) == .portfolio(main))
        #expect(doc.validContext(.all) == .all)
        #expect(PortfolioContext(storageKey: PortfolioContext.portfolio(main).storageKey) == .portfolio(main))
    }
}

struct AggregationTests {
    let quotes: [AssetID: Quote] = [btc.id: quote("400", ch24: 10), eth.id: quote("20", ch24: -5)]
    var assets: [AssetID: Asset] { [btc.id: btc, eth.id: eth] }

    @Test func transactionsAreIsolated() {
        let (doc, main, trading, _) = book()
        #expect(doc.transactions(.portfolio(main)).allSatisfy { $0.portfolioID == main })
        #expect(!doc.transactions(.portfolio(trading)).contains { $0.portfolioID == main })
        let t = PortfolioEngine.summarize(ledgers: doc.ledgers(.portfolio(trading)), assets: assets, quotes: quotes)
        #expect(t.valuation(btc.id)?.position.quantity == d("0.5"))
    }

    @Test func allAggregatesPerPortfolioAccounting() {
        let (doc, main, trading, _) = book()
        let m = PortfolioEngine.summarize(ledgers: doc.ledgers(.portfolio(main)), assets: assets, quotes: quotes)
        let t = PortfolioEngine.summarize(ledgers: doc.ledgers(.portfolio(trading)), assets: assets, quotes: quotes)
        let all = PortfolioEngine.summarize(ledgers: doc.ledgers(.all), assets: assets, quotes: quotes)
        // Holdings: MAIN 1 BTC + TRADING 0.5 BTC = 1.5 BTC (archived 5 BTC excluded).
        #expect(all.valuation(btc.id)?.position.quantity == d("1.5"))
        #expect(all.totalValue == m.totalValue + t.totalValue)
        #expect(all.costBasis == m.costBasis + t.costBasis)
        #expect(all.unrealized == m.unrealized + t.unrealized)
        #expect(all.realized == m.realized + t.realized)
        // TRADING realized 0.5·(300−200)=50. A merged ledger would re-average at 150 and report 75.
        #expect(all.realized == 50)
        #expect(all.valuation(btc.id)?.position.costBasis == 200)          // 100 + 0.5·200
        #expect(all.change24h == (m.change24h ?? 0) + (t.change24h ?? 0))
        #expect(all.totalValue == 1.5 * 400 + 10 * 20)
    }

    @Test func archivedPortfolioExcludedFromAll() {
        let (doc, _, _, arch) = book()
        #expect(!doc.transactions(.all).contains { $0.portfolioID == arch })
        #expect(doc.ledgers(.all).count == 2)
    }

    @Test func sellsCannotUseAnotherPortfoliosCoins() {
        var (doc, _, trading, _) = book()
        doc.transactions.append(tx(trading, .sell, "1", "400", "2024-04-01"))   // TRADING only holds 0.5
        #expect(doc.validationErrors().contains { $0.contains("held") })
    }

    @Test func historyIsPortfolioSpecific() {
        let (doc, main, trading, _) = book()
        let s = PriceSeries([PricePoint(time: day("2024-01-01"), price: 100), PricePoint(time: day("2024-12-31"), price: 100)])
        let grid = [day("2024-01-10"), day("2024-02-15")]
        let pm = PortfolioHistoryEngine.reconstruct(transactions: doc.transactions(.portfolio(main)), grid: grid, series: [btc.id: s])
        let pt = PortfolioHistoryEngine.reconstruct(transactions: doc.transactions(.portfolio(trading)), grid: grid, series: [btc.id: s, eth.id: s])
        #expect(pm.map(\.value) == [100, 100])
        #expect(pt.map(\.value) == [0, 1100], "TRADING has no value before its first transaction")
        let pa = PortfolioHistoryEngine.reconstruct(transactions: doc.transactions(.all), grid: grid, series: [btc.id: s, eth.id: s])
        #expect(pa.map(\.value) == [100, 1200])
    }
}

@MainActor
struct ActiveContextTests {
    func makeStore(_ dir: URL, _ defaults: UserDefaults) -> AppStore {
        var o = AppStore.Options()
        o.directory = dir; o.inMemory = true; o.defaults = defaults; o.publishWidgets = false; o.mockMarket = true
        return AppStore(o)
    }

    @Test func activePortfolioPersistsAndSwitchingRescopes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-ctx-\(UUID())")
        let suite = "pf.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = makeStore(dir, defaults)
        a.createEmpty()
        let main = a.doc.portfolios[0].id
        a.newPortfolio = NewPortfolioDraft(name: "long term", glyph: "∞")
        a.createPortfolio()
        let lt = try #require(a.doc.resolvePortfolio("long term")).id
        #expect(a.context == .portfolio(lt), "a new portfolio becomes active")
        #expect(a.doc.portfolio(lt)?.glyph == "∞")

        a.doc.assets = [btc]
        a.doc.transactions = [tx(main, .buy, "1", "100", "2024-01-02"), tx(lt, .buy, "2", "100", "2024-01-03")]
        a.quotes = [btc.id: quote("150")]
        a.setContext(.portfolio(main))
        #expect(a.summary.valuation(btc.id)?.position.quantity == 1)
        a.setContext(.portfolio(lt))
        #expect(a.summary.valuation(btc.id)?.position.quantity == 2)
        a.setContext(.all)
        #expect(a.summary.valuation(btc.id)?.position.quantity == 3)
        a.cyclePortfolio(1)                                    // ALL → first live
        #expect(a.context == .portfolio(main))
        a.setContext(.portfolio(lt))
        a.save()

        let b = makeStore(dir, defaults)                        // "restart"
        #expect(b.context == .portfolio(lt))
        #expect(b.doc.portfolios.map(\.name) == ["MAIN", "LONG TERM"])
    }

    @Test func archivingOrDeletingTheActivePortfolioMovesContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-ctx-\(UUID())")
        let suite = "pf.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = makeStore(dir, defaults)
        s.createEmpty()
        s.newPortfolio = NewPortfolioDraft(name: "trading"); s.createPortfolio()
        let t = s.context.portfolioID!
        s.toggleArchive(t)
        #expect(s.context == .portfolio(s.doc.portfolios[0].id))
        s.toggleArchive(t)                                      // restore
        #expect(s.doc.portfolio(t)?.isArchived == false)
        s.setContext(.portfolio(t))
        s.requestDeletePortfolio(t)                             // first press only arms
        #expect(s.doc.portfolio(t) != nil)
        s.requestDeletePortfolio(t)
        #expect(s.doc.portfolio(t) == nil)
        #expect(s.context == .portfolio(s.doc.portfolios[0].id))
    }
}

struct PortfolioCommandTests {
    @Test func portfolioCommands() {
        #expect(CommandParser.parse("portfolio long term") == .switchPortfolio("long term"))
        #expect(CommandParser.parse("pf all") == .switchPortfolio("all"))
        #expect(CommandParser.parse("new portfolio swing") == .newPortfolio("swing"))
        #expect(CommandParser.parse("portfolios") == .managePortfolios)
        #expect(CommandParser.parse("manage portfolios") == .managePortfolios)
        #expect(CommandParser.parse("buy tel 500000 @ .001805 in long term")
                == .trade(.buy, asset: "tel", amount: "500000", price: ".001805", portfolio: "long term"))
        #expect(CommandParser.parse("buy tel 500000 @ .001805") == .trade(.buy, asset: "tel", amount: "500000", price: ".001805"))
    }

    @Test func namesResolveWithSpacesAndPrefixes() {
        var doc = PortfolioDocument.fresh()
        _ = try? doc.createPortfolio(name: "long term", glyph: "∞")
        _ = try? doc.createPortfolio(name: "trading", glyph: "⇄")
        #expect(doc.resolvePortfolio("long term")?.name == "LONG TERM")
        #expect(doc.resolvePortfolio("trad")?.name == "TRADING")
        #expect(doc.resolvePortfolio("zzz") == nil)
    }
}

struct WidgetContextTests {
    @Test func snapshotCarriesPortfolioContext() {
        let (doc, _, trading, _) = book()
        let q: [AssetID: Quote] = [btc.id: quote("400", ch24: 10), eth.id: quote("20")]
        let s = PortfolioEngine.summarize(ledgers: doc.ledgers(.portfolio(trading)), assets: [btc.id: btc, eth.id: eth], quotes: q)
        let snap = WidgetSnapshotBuilder.build(.init(
            summary: s, movers24h: [], performance: [], performanceStart: Date(), performanceRange: "24H", performanceChangePercent: nil,
            hasPortfolio: true, quotesAsOf: Date(), refreshInterval: 60, isStale: false, privacy: .full, currency: "USD", numberStyle: .comma,
            now: Date(), contextID: PortfolioContext.portfolio(trading).storageKey, contextName: "TRADING", contextGlyph: "⇄"))
        #expect(snap.contextID == trading.uuidString)
        #expect(snap.contextLabel == "TRADING")
        #expect(snap.portfolioValue == 0.5 * 400 + 10 * 20)
        let back = try? WidgetSnapshotStore.decoder.decode(WidgetPortfolioSnapshot.self, from: WidgetSnapshotStore.encoder.encode(snap))
        #expect(back?.contextID == trading.uuidString)
    }
}
