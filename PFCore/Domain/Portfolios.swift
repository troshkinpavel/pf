import Foundation

/// A named, independent ledger. Identity is the UUID; the name is mutable display text.
public struct PortfolioInfo: Codable, Hashable, Identifiable, Sendable {
    public init(id: UUID, name: String, glyph: String, createdAt: Date, status: Status = .active, isDemo: Bool = false) { self.id = id; self.name = name; self.glyph = glyph; self.createdAt = createdAt; self.status = status; self.isDemo = isDemo }
    public enum Status: String, Codable, Sendable { case active, archived }

    public var id: UUID
    public var name: String
    public var glyph: String
    public var createdAt: Date
    public var status: Status = .active
    public var isDemo: Bool = false

    public var isArchived: Bool { status == .archived }

    /// Whole seconds: the stored (ISO 8601) and synced form, so memory and disk never disagree.
    public static func stamp(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
}

/// What the app is looking at. `.all` is computed from the live portfolios; it owns nothing.
public enum PortfolioContext: Hashable, Codable, Sendable {
    case portfolio(UUID)
    case all

    public var storageKey: String { if case let .portfolio(id) = self { return id.uuidString }; return "all" }
    public init?(storageKey: String) {
        if storageKey == "all" { self = .all } else if let u = UUID(uuidString: storageKey) { self = .portfolio(u) } else { return nil }
    }
    public var portfolioID: UUID? { if case let .portfolio(id) = self { return id }; return nil }
}

public enum PortfolioGlyphs {
    public static let all: [String] = ["◈", "◆", "●", "■", "▲", "△", "∞", "⇄", "λ", "Σ", "#", "@"]
    public static let main = "◈"
    public static let newDefault = "◆"
    public static let aggregate = "Σ"
}

public enum PortfolioError: Error, Equatable, CustomStringConvertible {
    case emptyName, duplicateName(String), notFound, lastActivePortfolio

    public var description: String {
        switch self {
        case .emptyName: "name required"
        case let .duplicateName(n): "\(n) already exists"
        case .notFound: "portfolio not found"
        case .lastActivePortfolio: "keep at least one active portfolio"
        }
    }
}

/// Portfolio bookkeeping on the document. Pure value mutations: callers persist.
extension PortfolioDocument {
    public static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public var livePortfolios: [PortfolioInfo] { portfolios.filter { !$0.isArchived } }

    public func portfolio(_ id: UUID) -> PortfolioInfo? { portfolios.first { $0.id == id } }

    /// Resolve user text ("trading", "long term", "lt") to a live portfolio: exact, prefix, then fuzzy.
    public func resolvePortfolio(_ text: String) -> PortfolioInfo? {
        let q = Self.normalizedName(text)
        guard !q.isEmpty else { return nil }
        let live = livePortfolios
        return live.first { $0.name == q }
            ?? live.first { $0.name.hasPrefix(q) }
            ?? live.map { ($0, Fuzzy.score(q, $0.name)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    public func nameError(_ raw: String, excluding id: UUID? = nil) -> PortfolioError? {
        let n = Self.normalizedName(raw)
        if n.isEmpty { return .emptyName }
        if portfolios.contains(where: { $0.name == n && $0.id != id }) { return .duplicateName(n) }
        return nil
    }

    @discardableResult
    public mutating func createPortfolio(name raw: String, glyph: String, now: Date = Date()) throws -> PortfolioInfo {
        if let e = nameError(raw) { throw e }
        let p = PortfolioInfo(id: UUID(), name: Self.normalizedName(raw), glyph: glyph, createdAt: PortfolioInfo.stamp(now))
        portfolios.append(p)
        return p
    }

    /// Renaming touches only the label: transactions, history and widgets reference the UUID.
    public mutating func renamePortfolio(_ id: UUID, to raw: String) throws {
        guard let i = portfolios.firstIndex(where: { $0.id == id }) else { throw PortfolioError.notFound }
        if let e = nameError(raw, excluding: id) { throw e }
        portfolios[i].name = Self.normalizedName(raw)
    }

    /// Archive keeps everything; it only removes the portfolio from switcher, ALL, menu bar and widgets.
    public mutating func setArchived(_ id: UUID, _ archived: Bool) throws {
        guard let i = portfolios.firstIndex(where: { $0.id == id }) else { throw PortfolioError.notFound }
        if archived, !portfolios[i].isArchived, livePortfolios.count <= 1 { throw PortfolioError.lastActivePortfolio }
        portfolios[i].status = archived ? .archived : .active
    }

    /// Removes the portfolio and its transactions only. Shared asset identities stay.
    public mutating func deletePortfolio(_ id: UUID) throws {
        guard let p = portfolio(id) else { throw PortfolioError.notFound }
        if !p.isArchived, livePortfolios.count <= 1 { throw PortfolioError.lastActivePortfolio }
        portfolios.removeAll { $0.id == id }
        transactions.removeAll { $0.portfolioID == id }
    }

    /// Ledgers in scope, one per portfolio (ALL = every live portfolio; archived are excluded).
    public func ledgers(_ c: PortfolioContext) -> [[Transaction]] {
        let ids: [UUID]
        switch c {
        case let .portfolio(id): ids = portfolio(id) == nil ? [] : [id]
        case .all: ids = livePortfolios.map(\.id)
        }
        let byPF = Dictionary(grouping: transactions, by: \.portfolioID)
        return ids.map { byPF[$0] ?? [] }
    }

    public func transactions(_ c: PortfolioContext) -> [Transaction] { ledgers(c).flatMap { $0 } }

    /// A context that still exists and is live; otherwise the first live portfolio (or ALL).
    public func validContext(_ c: PortfolioContext?) -> PortfolioContext {
        if case let .portfolio(id)? = c, let p = portfolio(id), !p.isArchived { return .portfolio(id) }
        if c == .all { return .all }
        return livePortfolios.first.map { .portfolio($0.id) } ?? .all
    }

    public func displayName(_ c: PortfolioContext) -> String {
        if case let .portfolio(id) = c { return portfolio(id)?.name ?? "PORTFOLIO" }
        return "ALL PORTFOLIOS"
    }

    public func glyph(_ c: PortfolioContext) -> String {
        if case let .portfolio(id) = c { return portfolio(id)?.glyph ?? PortfolioGlyphs.newDefault }
        return PortfolioGlyphs.aggregate
    }

    public func isDemo(_ c: PortfolioContext) -> Bool {
        switch c {
        case let .portfolio(id): return portfolio(id)?.isDemo ?? false
        case .all: return livePortfolios.contains { $0.isDemo }
        }
    }
}
