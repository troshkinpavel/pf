import Foundation

/// Canonical on-disk and backup format. Human-readable JSON; decimals are strings so no
/// precision is lost through binary floating point. Bump `currentSchema` and add a
/// migration in `migrate(_:)` for any breaking change.
///
/// v1: one implicit portfolio (`portfolio` meta + transactions).
/// v2: `portfolios` list; every transaction carries `portfolioID`.
struct PortfolioDocument: Codable, Equatable {
    static let currentSchema = 2

    /// v1 metadata, read only for migration and never written again.
    struct Meta: Codable, Equatable {
        var name: String = "main"
        var isDemo: Bool = false
        var createdAt: Date = Date()
    }

    var schemaVersion: Int = currentSchema
    var app: String = "pf Terminal"
    var exportedAt: Date?
    var portfolios: [PortfolioInfo] = []
    var assets: [Asset] = []
    var transactions: [Transaction] = []
    var settings: AppSettings?
    var legacyMeta: Meta?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, app, exportedAt, portfolios, assets, transactions, settings
        case legacyMeta = "portfolio"
    }

    init(schemaVersion: Int = currentSchema, portfolios: [PortfolioInfo] = [], assets: [Asset] = [], transactions: [Transaction] = [], settings: AppSettings? = nil) {
        self.schemaVersion = schemaVersion; self.portfolios = portfolios; self.assets = assets
        self.transactions = transactions; self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "pf Terminal"
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        portfolios = try c.decodeIfPresent([PortfolioInfo].self, forKey: .portfolios) ?? []
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        transactions = try c.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings)
        legacyMeta = try c.decodeIfPresent(Meta.self, forKey: .legacyMeta)
    }

    /// A fresh document with one empty MAIN portfolio.
    static func fresh(now: Date = Date()) -> PortfolioDocument {
        PortfolioDocument(portfolios: [PortfolioInfo(id: UUID(), name: "MAIN", glyph: PortfolioGlyphs.main, createdAt: PortfolioInfo.stamp(now))])
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum ImportError: Error, CustomStringConvertible {
        case unreadable(String)
        case newerSchema(Int)
        case invalid([String])
        var description: String {
            switch self {
            case let .unreadable(m): "not a pf backup: \(m)"
            case let .newerSchema(v): "backup schema v\(v) is newer than this app (v\(PortfolioDocument.currentSchema))"
            case let .invalid(e): e.prefix(3).joined(separator: " · ")
            }
        }
    }

    /// Decode + validate. Nothing is applied by this function. `ledgerChecks: false` (the
    /// app's own file) accepts a ledger that became oversold through a synced delete —
    /// it is shown, never quarantined. Imports are always strict.
    static func load(_ data: Data, ledgerChecks: Bool = true) throws -> PortfolioDocument {
        let probe: [String: Any]
        do { probe = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        catch { throw ImportError.unreadable("invalid JSON") }
        let v = probe["schemaVersion"] as? Int ?? 0
        guard v >= 1 else { throw ImportError.unreadable("missing schemaVersion") }
        guard v <= currentSchema else { throw ImportError.newerSchema(v) }
        var doc: PortfolioDocument
        do { doc = try decoder.decode(PortfolioDocument.self, from: data) }
        catch { throw ImportError.unreadable(String(describing: error).prefix(120).description) }
        doc = migrate(doc)
        let errs = doc.validationErrors(ledger: ledgerChecks)
        guard errs.isEmpty else { throw ImportError.invalid(errs) }
        return doc
    }

    /// v1 → v2: the single implicit portfolio becomes MAIN and owns every transaction.
    /// Idempotent: on a v2 document with valid references this changes nothing.
    static func migrate(_ d: PortfolioDocument) -> PortfolioDocument {
        var d = d
        if d.portfolios.isEmpty {
            let meta = d.legacyMeta ?? Meta()
            let firstTx = d.transactions.map(\.timestamp).min()
            d.portfolios = [PortfolioInfo(id: UUID(), name: "MAIN", glyph: PortfolioGlyphs.main,
                                          createdAt: min(meta.createdAt, firstTx ?? meta.createdAt), isDemo: meta.isDemo)]
        }
        let valid = Set(d.portfolios.map(\.id)), first = d.portfolios[0].id
        for i in d.transactions.indices where !valid.contains(d.transactions[i].portfolioID) {
            d.transactions[i].portfolioID = first
        }
        d.legacyMeta = nil
        d.schemaVersion = currentSchema
        return d
    }

    func validationErrors(ledger: Bool = true) -> [String] {
        var errs: [String] = []
        let ids = Set(assets.map(\.id))
        if ids.count != assets.count { errs.append("duplicate asset ids") }
        for a in assets where a.symbol.isEmpty { errs.append("asset \(a.id) has no symbol") }
        if portfolios.isEmpty { errs.append("no portfolios") }
        if Set(portfolios.map(\.id)).count != portfolios.count { errs.append("duplicate portfolio ids") }
        if Set(portfolios.map(\.name)).count != portfolios.count { errs.append("duplicate portfolio names") }
        let pids = Set(portfolios.map(\.id))
        for t in transactions where !pids.contains(t.portfolioID) { errs.append("tx \(t.id.uuidString.prefix(8)): unknown portfolio") }
        // Holdings are per portfolio: a sell can never draw on another portfolio's coins.
        for (_, txs) in Dictionary(grouping: transactions, by: \.portfolioID) where ledger {
            errs += PortfolioEngine.validate(txs, knownAssets: ids).map { e in
                switch e {
                case let .oversold(id, _, _), let .nonPositiveQuantity(id), let .negativePrice(id), let .negativeFee(id), let .unknownAsset(id, _):
                    "tx \(id.uuidString.prefix(8)): \(e)"
                }
            }
        }
        return errs
    }

    func encoded() throws -> Data { try Self.encoder.encode(self) }
}

// Decimal fields as strings; accepts numbers on input for hand-written files.
extension Transaction {
    enum CodingKeys: String, CodingKey { case id, portfolioID, assetID, type, quantity, price, currency, timestamp, fee, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func dec(_ k: CodingKeys) throws -> Decimal {
            if let s = try? c.decode(String.self, forKey: k), let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) { return d }
            if let d = try? c.decode(Double.self, forKey: k) { return .of(d) }
            if !c.contains(k) && k == .fee { return 0 }
            throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "expected decimal")
        }
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        portfolioID = try c.decodeIfPresent(UUID.self, forKey: .portfolioID) ?? Transaction.unassigned   // v1: set by migrate
        assetID = try c.decode(String.self, forKey: .assetID)
        type = try c.decode(TransactionType.self, forKey: .type)
        quantity = try dec(.quantity)
        price = try dec(.price)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        fee = try dec(.fee)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(portfolioID, forKey: .portfolioID)
        try c.encode(assetID, forKey: .assetID)
        try c.encode(type, forKey: .type)
        try c.encode("\(quantity)", forKey: .quantity)
        try c.encode("\(price)", forKey: .price)
        try c.encode(currency, forKey: .currency)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode("\(fee)", forKey: .fee)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// Local file storage: ~/Library/Application Support/pf/portfolio.json (inside the app sandbox container).
struct PortfolioStore {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pf", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent("portfolio.json") }

    func load() throws -> PortfolioDocument? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let doc = try PortfolioDocument.load(data, ledgerChecks: false)
        // Keep the pre-migration file once, before any v2 write replaces it.
        let v = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int ?? 0
        let backup = directory.appendingPathComponent("portfolio.v\(v)-backup.json")
        if v < PortfolioDocument.currentSchema, !FileManager.default.fileExists(atPath: backup.path) {
            try? data.write(to: backup, options: .atomic)
        }
        return doc
    }

    func save(_ doc: PortfolioDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var d = doc
        d.settings = nil
        d.exportedAt = nil
        try d.encoded().write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    /// Keep an unreadable file aside instead of overwriting the user's data.
    func quarantine() {
        let dst = directory.appendingPathComponent("portfolio.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: fileURL, to: dst)
    }

    var byteSize: Int { (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0 }
}
