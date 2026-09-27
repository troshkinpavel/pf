import Foundation

enum Screen: String, Codable, Sendable {
    case overview, asset, target, movers, analytics, settings, share, portfolios
}

struct ShareOverrides: Equatable, Sendable {
    var period: ChartRange?
    var privacy: SharePrivacy?
    var format: ShareFormat?
    var theme: ShareTheme?
    var isEmpty: Bool { period == nil && privacy == nil && format == nil && theme == nil }
}

/// Structured palette commands. Mutating commands (`trade`) only ever open a preview;
/// the caller must require explicit confirmation before committing.
enum Command: Equatable, Sendable {
    case trade(TransactionType, asset: String, amount: String?, price: String?, portfolio: String? = nil)
    case target(asset: String, value: String?)
    case share(ShareOverrides)
    case navigate(Screen)
    case switchPortfolio(String)        // name may contain spaces: "long term"
    case newPortfolio(String)
    case managePortfolios, openSwitcher
    case refresh, exportBackup, importBackup, removeDemo

    var mutates: Bool { if case .trade = self { return true }; return false }
}

enum CommandParser {
    private static let tradeVerbs: [String: TransactionType] = [
        "buy": .buy, "b": .buy, "sell": .sell, "s": .sell,
        "in": .transferIn, "deposit": .transferIn, "out": .transferOut, "withdraw": .transferOut,
    ]
    private static let nav: [String: Screen] = [
        "portfolio": .overview, "overview": .overview, "home": .overview, "positions": .overview,
        "movers": .movers, "gainers": .movers, "losers": .movers,
        "analytics": .analytics, "pnl": .analytics, "allocation": .analytics, "performance": .analytics, "drawdown": .analytics,
        "settings": .settings, "preferences": .settings, "prefs": .settings, "sync": .settings, "icloud": .settings,
    ]
    private static let shareTokens: Set<String> = ["share"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "@", with: " @ ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    static func parse(_ input: String) -> Command? {
        var t = tokens(input)
        guard !t.isEmpty else { return nil }
        // Portfolio names keep their spaces: everything after the verb is the name.
        if t.count >= 2, ["portfolio", "pf", "p", "switch"].contains(t[0]), t[1] != "new" {
            return .switchPortfolio(t.dropFirst().joined(separator: " "))
        }
        if t.count >= 2, t[0] == "new", t[1] == "portfolio" { return .newPortfolio(t.dropFirst(2).joined(separator: " ")) }
        if t == ["portfolios"] || t == ["manage", "portfolios"] || t == ["manage"] { return .managePortfolios }
        if t == ["switch"] { return .openSwitcher }
        if t.count >= 2, t[0] == "transfer", t[1] == "in" || t[1] == "out" { t.removeFirst() }

        if let type = tradeVerbs[t[0]], t.count >= 2 {
            var rest = Array(t.dropFirst(2))
            // "buy eth 0.5 @ 3500 in trading" → destination portfolio
            var portfolio: String?
            if let i = rest.firstIndex(of: "in"), i + 1 < rest.count {
                portfolio = rest[(i + 1)...].joined(separator: " ")
                rest = Array(rest[..<i])
            }
            let amount = rest.first.flatMap { $0 == "@" || $0 == "at" ? nil : $0 }
            if amount != nil { rest.removeFirst() }
            if let f = rest.first, f == "@" || f == "at" { rest.removeFirst() }
            return .trade(type, asset: t[1], amount: amount, price: rest.first, portfolio: portfolio)
        }
        if ["target", "tgt", "t"].contains(t[0]), t.count >= 2 {
            return .target(asset: t[1], value: t.count > 2 ? t[2] : nil)
        }
        if t[0] == "share" {
            var o = ShareOverrides()
            for x in t.dropFirst() {
                if let p = ChartRange(rawValue: x.uppercased()), ShareConfig.periods.contains(p) { o.period = p }
                else if let p = SharePrivacy(rawValue: x) { o.privacy = p }
                else if let f = ShareFormat(rawValue: x) { o.format = f }
                else if let th = ShareTheme(rawValue: x) { o.theme = th }
            }
            return .share(o)
        }
        if t.count == 1 {
            if let s = nav[t[0]] { return .navigate(s) }
            switch t[0] {
            case "refresh", "reload": return .refresh
            case "export", "backup": return .exportBackup
            case "import", "restore": return .importBackup
            default: break
            }
        }
        if t == ["remove", "demo"] || t == ["clear", "demo"] { return .removeDemo }
        return nil
    }
}

enum Fuzzy {
    /// Substring match ranks by position; otherwise in-order subsequence; -1 = no match.
    static func score(_ q: String, _ s: String) -> Int {
        let q = q.lowercased(), s = s.lowercased()
        if q.isEmpty { return 1 }
        if let r = s.range(of: q) { return 100 - s.distance(from: s.startIndex, to: r.lowerBound) }
        var qi = q.startIndex, sc = 0
        for c in s where qi < q.endIndex && c == q[qi] { qi = q.index(after: qi); sc += 1 }
        return qi == q.endIndex ? sc : -1
    }
}
