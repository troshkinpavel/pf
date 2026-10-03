import Foundation

/// A transaction being entered (Mac sheet, iPhone form, command line). Text fields stay raw
/// until `TransactionPlanner.preview` parses and validates them.
public struct TxDraft: Equatable {
    public init(editing: UUID? = nil, portfolioID: UUID? = nil, type: TransactionType = .buy, asset: String = "", amount: String = "",
                price: String = "", date: String = DateFmt.ymd(Date()), fee: String = "", note: String = "", searchResults: [Asset] = [],
                candidateQuotes: [AssetID: Quote] = [:], pick: Int = 0, searching: Bool = false) {
        self.editing = editing; self.portfolioID = portfolioID; self.type = type; self.asset = asset; self.amount = amount
        self.price = price; self.date = date; self.fee = fee; self.note = note; self.searchResults = searchResults
        self.candidateQuotes = candidateQuotes; self.pick = pick; self.searching = searching
    }
    public var editing: UUID?
    public var portfolioID: UUID?     // destination; required before commit (ALL owns nothing)
    public var type: TransactionType = .buy
    public var asset = ""
    public var amount = ""
    public var price = ""
    public var date = DateFmt.ymd(Date())
    public var fee = ""
    public var note = ""
    public var searchResults: [Asset] = []
    public var candidateQuotes: [AssetID: Quote] = [:]
    public var pick = 0                 // chosen search result (↑↓ in the sheet)
    public var searching = false
    /// Close price on a past date, loaded by the host for a backdated BUY/SELL with a blank
    /// price. Used only while `historicalKey` matches the draft's asset and date.
    public var historicalPrice: Decimal?
    public var historicalKey: String?
    public var loadingHistorical = false

    public static func historicalKey(_ asset: AssetID, _ ymd: String) -> String { asset + "|" + ymd }
}

/// The validated result of a draft: what would be written, and what changes. Nothing is saved
/// until the caller commits `tx` after an explicit confirmation.
public struct TxPreview {
    public init(line: String) { self.line = line }
    /// Semantic color of a row; each platform maps it to its theme.
    public enum Tone: Equatable { case primary, secondary, accent, negative, sign(Double) }
    public struct Row: Identifiable {
        public let id = UUID(); public let k: String; public let v: String; public let tone: Tone
        public init(k: String, v: String, tone: Tone) { self.k = k; self.v = v; self.tone = tone }
    }

    public var line: String
    public var rows: [Row] = []
    public var ok = false
    public var tx: Transaction?
    public var asset: Asset?
    public var assetHint = ""
    public var assetHintError = false
    public var pricePlaceholder = "3500"
    /// Position in the destination portfolio before and after this transaction.
    public var before: Position?
    public var after: Position?
    /// First validation problem, for compact UIs.
    public var error: String? { rows.first { $0.k == "error" }?.v }
}

public enum TransactionPlanner {
    /// Parses, validates and previews a draft against the destination portfolio's own ledger.
    public static func preview(_ d: TxDraft, doc: PortfolioDocument, quotes: [AssetID: Quote], currency: String,
                        resolve: (String, [Asset]) -> Asset?, now: Date = Date(), fmt f: Fmt = Fmt.current) -> TxPreview {
        var p = TxPreview(line: d.type.short + " — enter asset, amount, price")
        let a = resolve(d.asset, d.searchResults)
        p.asset = a
        if let a {
            let isSearch = !doc.assets.contains(a) && !AssetCatalog.known.contains(a)
            p.assetHint = a.name.lowercased() + (quotes[a.id].map { " · " + f.price($0.price) } ?? "") + (isSearch ? " · " + (a.chain.map { "\($0) token" } ?? "coingecko:\(a.coingeckoID ?? "")") : "")
            if let q = quotes[a.id] ?? d.candidateQuotes[a.id] { p.pricePlaceholder = "market " + f.priceDigits(q.price.double) }
            else { p.pricePlaceholder = d.searching ? "loading market price…" : "no market price · enter price" }
        } else if !d.asset.isEmpty {
            p.assetHint = d.searching ? "searching…" : "no match"
            p.assetHintError = !d.searching
        }
        let amount = NumberInput.parse(d.amount, style: f.style)
        let marketPrice = a.flatMap { quotes[$0.id]?.price ?? d.candidateQuotes[$0.id]?.price }
        let rawPrice = d.price.trimmingCharacters(in: .whitespaces)
        let fee: Decimal? = d.fee.trimmingCharacters(in: .whitespaces).isEmpty || d.fee == "0" ? 0 : NumberInput.parse(d.fee, style: f.style)
        let date = DateFmt.parseYMD(d.date)
        let backdated = date.map { DateFmt.ymd($0) != DateFmt.ymd(now) } ?? false
        // A blank price is filled only from a price for the right moment, and always said so:
        // never today's price for a past date, never a market price as a transfer's cost basis.
        var auto: (price: Decimal, note: String)?
        var link: Transaction?
        if rawPrice.isEmpty, let a {
            switch d.type {
            case .buy, .sell:
                if !backdated {
                    if let m = marketPrice { auto = (m, "market now") }
                } else if d.historicalKey == TxDraft.historicalKey(a.id, d.date), let h = d.historicalPrice {
                    auto = (h, "close \(d.date)")
                } else {
                    p.pricePlaceholder = d.loadingHistorical ? "loading \(d.date) price…" : "no price for \(d.date) · enter price"
                }
            case .transferIn:
                if let amount, let date, let pid = d.portfolioID,
                   let (out, avg) = linkedTransferOut(a.id, quantity: amount, date: date, into: pid, doc: doc, excluding: d.editing) {
                    link = out
                    auto = (avg, "avg entry of the transfer out from \(doc.portfolio(out.portfolioID)?.name ?? "another portfolio")")
                } else {
                    p.pricePlaceholder = "cost per unit · 0 = no cost basis"
                }
            case .transferOut:
                auto = (0, "")   // cost leaves at the average entry; the price is not used for the cost basis
            }
            if let auto, d.type == .transferIn { p.pricePlaceholder = "linked " + f.priceDigits(auto.price.double) }
            else if let auto, backdated, d.type != .transferOut { p.pricePlaceholder = "\(d.date) close " + f.priceDigits(auto.price.double) }
        }
        let price: Decimal? = rawPrice.isEmpty ? auto?.price : (rawPrice == "0" ? 0 : NumberInput.parse(d.price, style: f.style))
        guard let a, let amount else { return p }
        guard let pid = d.portfolioID, let dest = doc.portfolio(pid), !dest.isArchived else {
            p.rows = [.init(k: "error", v: "choose a portfolio", tone: .negative)]; return p
        }
        guard let price else {
            let why: String
            switch d.type {
            case .transferIn: why = "enter cost per unit (0 = no cost basis)"
            default: why = rawPrice.isEmpty ? (backdated ? (d.loadingHistorical ? "loading the \(d.date) price…" : "no price found for \(d.date) · enter it") : "no market price · enter price") : "invalid price"
            }
            p.rows = [.init(k: "error", v: why, tone: .negative)]; return p
        }
        p.line = "\(d.type.short) \(f.amount(amount)) \(a.symbol) @ \(f.price(price))"
        guard let fee else { p.rows = [.init(k: "error", v: "invalid fee", tone: .negative)]; return p }
        guard var date else { p.rows = [.init(k: "error", v: "date must be YYYY-MM-DD", tone: .negative)]; return p }
        if DateFmt.ymd(date) == DateFmt.ymd(now) { date = min(now, date) }
        if date > now.addingTimeInterval(60) { p.rows = [.init(k: "error", v: "date is in the future", tone: .negative)]; return p }
        // Keep the original time of day when editing an unchanged date.
        let old = d.editing.flatMap { id in doc.transactions.first { $0.id == id } }
        if let old, DateFmt.ymd(old.timestamp) == d.date { date = old.timestamp }

        let t = Transaction(id: d.editing ?? UUID(), portfolioID: pid, assetID: a.id, type: d.type, quantity: amount, price: price,
                            currency: currency, timestamp: date, fee: fee, note: d.note.isEmpty ? nil : d.note)
        // Holdings and validation are per destination portfolio: a sell can't use another portfolio's coins.
        let current = doc.transactions.filter { $0.portfolioID == pid }
        var ledger = current.filter { $0.id != d.editing }
        ledger.append(t)
        let before = PortfolioEngine.positions(current)[a.id] ?? Position(assetID: a.id)
        let after = PortfolioEngine.positions(ledger)[a.id] ?? Position(assetID: a.id)
        p.before = before
        p.after = after
        var errs = PortfolioEngine.validate(ledger)
        // Moving an edited transaction out of its old portfolio must leave that one valid too.
        if let old, old.portfolioID != pid {
            errs += PortfolioEngine.validate(doc.transactions.filter { $0.portfolioID == old.portfolioID && $0.id != old.id })
        }
        if let e = errs.first(where: { if case .oversold = $0 { return true }; return false }) {
            if case let .oversold(_, held, _) = e {
                p.rows = [.init(k: "error", v: "only \(f.amount(held)) \(a.symbol) held at that date", tone: .negative)]
            }
            return p
        }
        guard errs.isEmpty else { p.rows = [.init(k: "error", v: errs[0].description, tone: .negative)]; return p }

        let pos = "\(f.amount(before.quantity)) → \(f.amount(after.quantity)) \(a.symbol)"
        let avg = "\(f.price(before.averageEntry ?? price)) → \(f.price(after.averageEntry ?? before.averageEntry ?? price))"
        switch d.type {
        case .buy:
            p.rows = [.init(k: "cost", v: f.money(amount * price + fee), tone: .primary), .init(k: "position", v: pos, tone: .secondary), .init(k: "avg entry", v: avg, tone: .primary)]
        case .sell:
            let rl = after.realizedPnL - before.realizedPnL
            p.rows = [.init(k: "proceeds", v: f.money(amount * price - fee), tone: .primary), .init(k: "position", v: pos, tone: .secondary),
                      .init(k: "realized pnl", v: f.signed(rl), tone: .sign(rl.double))]
        case .transferIn:
            p.rows = [.init(k: "cost basis added", v: f.money(amount * price + fee), tone: .primary), .init(k: "position", v: pos, tone: .secondary), .init(k: "avg entry", v: avg, tone: .primary)]
        case .transferOut:
            p.rows = [.init(k: "position", v: pos, tone: .secondary), .init(k: "cost basis removed", v: f.money(before.costBasis - after.costBasis), tone: .primary)]
        }
        if let auto, rawPrice.isEmpty, !auto.note.isEmpty {
            p.rows.insert(.init(k: d.type == .transferIn ? "cost/unit" : "price", v: f.price(price) + " · auto · " + auto.note, tone: .accent), at: 0)
        }
        if link != nil { p.rows.insert(.init(k: "linked", v: "matches a transfer out · same amount", tone: .secondary), at: 0) }
        p.rows.insert(.init(k: "portfolio", v: dest.glyph + " " + dest.name, tone: .secondary), at: 0)
        if d.editing != nil { p.rows.insert(.init(k: "edit", v: "replaces the original transaction", tone: .accent), at: 0) }
        p.ok = true
        p.tx = t
        return p
    }
}

extension TransactionPlanner {
    /// A TRANSFER OUT of the same asset and amount from another portfolio within two days: the
    /// other half of a move between portfolios. Its cost basis carries over at the source's
    /// average entry at that moment.
    public static func linkedTransferOut(_ asset: AssetID, quantity: Decimal, date: Date, into pid: UUID,
                                         doc: PortfolioDocument, excluding: UUID? = nil) -> (Transaction, Decimal)? {
        let out = doc.transactions.filter {
            $0.type == .transferOut && $0.assetID == asset && $0.quantity == quantity && $0.portfolioID != pid && $0.id != excluding
                && abs($0.timestamp.timeIntervalSince(date)) <= 2 * 86400
        }.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
        guard let out else { return nil }
        let before = doc.transactions.filter { $0.portfolioID == out.portfolioID && $0.id != out.id && $0.timestamp <= out.timestamp }
        guard let avg = PortfolioEngine.positions(before)[asset]?.averageEntry else { return nil }
        return (out, avg)
    }
}

extension PortfolioDocument {
    /// Records a validated transaction (new or edited) and its asset identity. The same stable
    /// UUID is kept on edit, so sync updates the existing record instead of creating one.
    public mutating func upsert(_ t: Transaction, asset: Asset) {
        if !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
        if let i = transactions.firstIndex(where: { $0.id == t.id }) { transactions[i] = t } else { transactions.append(t) }
    }

    /// Removes a transaction unless a later one in the same portfolio depends on it; drops
    /// asset identities no transaction references any more.
    public mutating func removeTransaction(_ t: Transaction) throws {
        let ledger = transactions.filter { $0.id != t.id }
        if let e = PortfolioEngine.validate(ledger.filter { $0.portfolioID == t.portfolioID }).first { throw e }
        transactions = ledger
        assets.removeAll { a in !ledger.contains { $0.assetID == a.id } }
    }
}
