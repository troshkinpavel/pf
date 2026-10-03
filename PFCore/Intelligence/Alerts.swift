import Foundation

// Portfolio-aware alert rules (design §07–08). Evaluated on this Mac by the existing price
// refresh (no extra polling); pure functions here, delivery in the app.

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case priceAbove, priceBelow, pnlAbove, pnlBelow, valueAbove, valueBelow, weightAbove, move24h, depeg, target, drawdown

    /// Short type name, as in the RULES table.
    public var label: String {
        switch self {
        case .priceAbove: "price above"; case .priceBelow: "price below"
        case .pnlAbove, .pnlBelow: "position p&l"
        case .valueAbove, .valueBelow: "portfolio value"
        case .weightAbove: "allocation"; case .move24h: "24h move"; case .depeg: "stablecoin depeg"
        case .target: "target reached"; case .drawdown: "drawdown"
        }
    }
    public var needsAsset: Bool { [.priceAbove, .priceBelow, .pnlAbove, .pnlBelow, .weightAbove, .target].contains(self) }
    public var needsPortfolio: Bool { [.valueAbove, .valueBelow, .drawdown].contains(self) }
}

/// What a rule watches. Stored as a string so the file stays readable.
public enum AlertSubject: Hashable, Codable, Sendable {
    case asset(AssetID), portfolio(String), anyHeld, anyStablecoin

    public var raw: String {
        switch self {
        case let .asset(a): "asset:" + a
        case let .portfolio(p): "portfolio:" + p
        case .anyHeld: "any-held"
        case .anyStablecoin: "any-stablecoin"
        }
    }
    public init(raw: String) {
        if raw.hasPrefix("asset:") { self = .asset(String(raw.dropFirst(6))) }
        else if raw.hasPrefix("portfolio:") { self = .portfolio(String(raw.dropFirst(10))) }
        else if raw == "any-stablecoin" { self = .anyStablecoin }
        else { self = .anyHeld }
    }
    public init(from decoder: Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
    public var assetID: AssetID? { if case let .asset(a) = self { return a }; return nil }
}

public enum AlertRepeat: String, Codable, CaseIterable, Sendable {
    /// Fires once, then stays fired until re-armed by hand (r).
    case once
    /// Fires on every crossing; re-arms by itself after moving back past the hysteresis.
    case cross = "every cross"
    /// At most once per calendar day while the condition holds.
    case daily
}

public struct AlertRule: Codable, Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), number: Int, kind: AlertKind, subject: AlertSubject, threshold: Double, repeatMode: AlertRepeat = .once,
                hysteresis: Double = 2, paused: Bool = false, createdAt: Date, note: String? = nil) {
        self.id = id; self.number = number; self.kind = kind; self.subject = subject; self.threshold = threshold; self.repeatMode = repeatMode
        self.hysteresis = hysteresis; self.paused = paused; self.createdAt = createdAt; self.note = note
    }
    public enum State: String, Codable, Sendable { case armed, fired }

    public var id: UUID
    /// "#5" in the UI; stable for the life of the rule.
    public var number: Int
    public var kind: AlertKind
    public var subject: AlertSubject
    /// Price/value in the ledger currency, or a percentage / percentage points by kind.
    public var threshold: Double
    public var repeatMode: AlertRepeat
    /// Reset band: % of the threshold for price/value rules, percentage points otherwise.
    public var hysteresis: Double
    public var paused: Bool
    public var state: State = .armed
    public var firedAt: Date?
    /// Fired and not yet looked at (⚑ in the status bar and menu bar).
    public var unseen = false
    public var createdAt: Date
    public var note: String?

    enum CodingKeys: String, CodingKey { case id, number, kind, subject, threshold, repeatMode, hysteresis, paused, state, firedAt, unseen, createdAt, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); number = try c.decode(Int.self, forKey: .number)
        kind = try c.decode(AlertKind.self, forKey: .kind); subject = try c.decode(AlertSubject.self, forKey: .subject)
        threshold = try c.decode(Double.self, forKey: .threshold)
        repeatMode = (try? c.decode(AlertRepeat.self, forKey: .repeatMode)) ?? .once
        hysteresis = (try? c.decode(Double.self, forKey: .hysteresis)) ?? 2
        paused = (try? c.decode(Bool.self, forKey: .paused)) ?? false
        state = (try? c.decode(State.self, forKey: .state)) ?? .armed
        firedAt = try? c.decode(Date.self, forKey: .firedAt)
        unseen = (try? c.decode(Bool.self, forKey: .unseen)) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        note = try? c.decode(String.self, forKey: .note)
    }
}

public struct AlertEvent: Codable, Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), at: Date, rule: UUID, number: Int, message: String, delivery: String) {
        self.id = id; self.at = at; self.rule = rule; self.number = number; self.message = message; self.delivery = delivery
    }
    public var id: UUID
    public var at: Date
    public var rule: UUID
    public var number: Int
    public var message: String
    public var delivery: String
}

/// Everything a rule can be checked against, from data the app already has.
public struct AlertInputs: Sendable {
    public init(now: Date, quotes: [AssetID: Quote], staleAfter: TimeInterval, held: Set<AssetID>, positionPnL: [AssetID: Double] = [:],
                weights: [AssetID: Double] = [:], portfolioValues: [String: Decimal] = [:], drawdowns: [String: Double] = [:],
                pegs: [AssetID: PegCheck] = [:], baseTargets: [AssetID: Decimal] = [:]) {
        self.now = now; self.quotes = quotes; self.staleAfter = staleAfter; self.held = held; self.positionPnL = positionPnL
        self.weights = weights; self.portfolioValues = portfolioValues; self.drawdowns = drawdowns; self.pegs = pegs; self.baseTargets = baseTargets
    }
    public var now: Date
    public var quotes: [AssetID: Quote]
    public var staleAfter: TimeInterval
    public var held: Set<AssetID>
    /// Position P&L in % (total return of the position) and weight in % of its portfolio context.
    public var positionPnL: [AssetID: Double]
    public var weights: [AssetID: Double]
    /// Portfolio context storage key ("all" or a UUID) → value / current TWR drawdown (≤ 0, in %).
    public var portfolioValues: [String: Decimal]
    public var drawdowns: [String: Double]
    public var pegs: [AssetID: PegCheck]
    public var baseTargets: [AssetID: Decimal]

    func freshPrice(_ a: AssetID) -> Decimal? {
        guard let q = quotes[a], now.timeIntervalSince(q.timestamp) <= staleAfter else { return nil }
        return q.price
    }
}

public enum AlertEngine {
    /// Current measurement and whether the condition holds. nil = no fresh data: the rule
    /// neither fires nor re-arms (stale prices never trigger anything).
    public struct Reading: Equatable, Sendable {
        public let value: Double
        public let met: Bool
        /// True when the reading is back past the reset band (used to re-arm `every cross`).
        public let reset: Bool
        /// Which asset (for "any held" / "any stablecoin" rules).
        public let asset: AssetID?
    }

    public static func read(_ r: AlertRule, _ i: AlertInputs) -> Reading? {
        let t = r.threshold, h = r.hysteresis
        func asset() -> AssetID? { r.subject.assetID }
        switch r.kind {
        case .priceAbove, .priceBelow, .target:
            guard let a = asset(), let p = i.freshPrice(a)?.double else { return nil }
            let level = r.kind == .target ? (i.baseTargets[a]?.double ?? 0) : t
            guard level > 0 else { return nil }
            let above = r.kind != .priceBelow
            return Reading(value: p, met: above ? p >= level : p <= level,
                           reset: above ? p < level * (1 - h / 100) : p > level * (1 + h / 100), asset: a)
        case .pnlAbove, .pnlBelow:
            guard let a = asset(), i.freshPrice(a) != nil, let v = i.positionPnL[a] else { return nil }
            let above = r.kind == .pnlAbove
            return Reading(value: v, met: above ? v >= t : v <= t, reset: above ? v < t - h : v > t + h, asset: a)
        case .weightAbove:
            guard let a = asset(), i.freshPrice(a) != nil, let v = i.weights[a] else { return nil }
            return Reading(value: v, met: v > t, reset: v < t - h, asset: a)
        case .valueAbove, .valueBelow:
            guard case let .portfolio(k) = r.subject, let v = i.portfolioValues[k]?.double else { return nil }
            let above = r.kind == .valueAbove
            return Reading(value: v, met: above ? v >= t : v <= t, reset: above ? v < t * (1 - h / 100) : v > t * (1 + h / 100), asset: nil)
        case .drawdown:
            guard case let .portfolio(k) = r.subject, let d = i.drawdowns[k] else { return nil }
            return Reading(value: d, met: d <= -abs(t), reset: d > -abs(t) + h, asset: nil)
        case .move24h:
            let ids: [AssetID] = r.subject == .anyHeld ? i.held.sorted() : asset().map { [$0] } ?? []
            let moves = ids.compactMap { a -> (AssetID, Double)? in
                guard i.freshPrice(a) != nil, let c = i.quotes[a]?.change24h, !Stablecoins.isStablecoin(a) || r.subject != .anyHeld else { return nil }
                return (a, c)
            }
            guard let top = moves.max(by: { abs($0.1) < abs($1.1) }) else { return nil }
            return Reading(value: top.1, met: abs(top.1) >= t, reset: abs(top.1) < t - h, asset: top.0)
        case .depeg:
            let ids: [AssetID] = r.subject == .anyStablecoin ? i.pegs.keys.sorted() : asset().map { [$0] } ?? []
            let devs = ids.compactMap { a -> (AssetID, Double)? in
                guard i.freshPrice(a) != nil, let d = i.pegs[a]?.deviationPercent else { return nil }
                return (a, d)
            }
            guard let top = devs.max(by: { abs($0.1) < abs($1.1) }) else { return nil }
            // 0.6 semantics: outside the band fires; re-arms only once back within half the band.
            return Reading(value: top.1, met: abs(top.1) > t, reset: abs(top.1) <= t / 2, asset: top.0)
        }
    }

    public struct Fired: Equatable, Sendable {
        public let rule: UUID
        public let number: Int
        public let reading: Reading
    }

    /// One evaluation pass. Event semantics: a rule fires when it is armed and its condition
    /// holds, then stays quiet until it re-arms (by hand for `once`, past the reset band for
    /// `every cross`, on a new day for `daily`). Paused rules and stale data never fire.
    public static func evaluate(_ rules: inout [AlertRule], _ i: AlertInputs, calendar: Calendar = .current) -> [Fired] {
        var out: [Fired] = []
        for k in rules.indices where !rules[k].paused {
            guard let rd = read(rules[k], i) else { continue }
            switch rules[k].state {
            case .armed:
                if rd.met {
                    rules[k].state = .fired; rules[k].firedAt = i.now; rules[k].unseen = true
                    out.append(Fired(rule: rules[k].id, number: rules[k].number, reading: rd))
                }
            case .fired:
                switch rules[k].repeatMode {
                case .once: break
                case .cross: if rd.reset { rules[k].state = .armed }
                case .daily:
                    if let f = rules[k].firedAt, !calendar.isDate(f, inSameDayAs: i.now) {
                        rules[k].state = .armed
                        if rd.met {
                            rules[k].state = .fired; rules[k].firedAt = i.now; rules[k].unseen = true
                            out.append(Fired(rule: rules[k].id, number: rules[k].number, reading: rd))
                        }
                    }
                }
            }
        }
        return out
    }

    /// How far a rule is from firing, in its own unit: % for price/value, pp otherwise.
    /// nil without data. Negative never happens for armed rules whose condition holds (they fire).
    public static func distance(_ r: AlertRule, _ rd: Reading?, _ i: AlertInputs) -> Double? {
        guard let rd else { return nil }
        switch r.kind {
        case .priceAbove, .priceBelow, .target, .valueAbove, .valueBelow:
            let level = r.kind == .target ? (rd.asset.flatMap { i.baseTargets[$0]?.double } ?? 0) : r.threshold
            return rd.value > 0 ? (level / rd.value - 1) * 100 : nil
        case .pnlAbove, .weightAbove: return r.threshold - rd.value
        case .pnlBelow: return rd.value - r.threshold
        case .drawdown: return rd.value + abs(r.threshold)
        case .move24h: return r.threshold - abs(rd.value)
        case .depeg: return r.threshold - abs(rd.value)
        }
    }

    /// "price ≤ $0.2400", "weight > 40.0%", "|price − $1| > 0.50%" …
    public static func condition(_ r: AlertRule, fmt f: Fmt) -> String {
        let t = r.threshold
        switch r.kind {
        case .priceAbove: return "price ≥ " + f.price(Decimal.of(t))
        case .priceBelow: return "price ≤ " + f.price(Decimal.of(t))
        case .target: return "price ≥ base target"
        case .pnlAbove: return "p&l ≥ " + f.pct(t, 1)
        case .pnlBelow: return "p&l ≤ " + f.pct(t, 1)
        case .valueAbove: return "value ≥ " + f.money(Decimal.of(t), 0)
        case .valueBelow: return "value ≤ " + f.money(Decimal.of(t), 0)
        case .weightAbove: return "weight > " + f.num(t, 1) + "%"
        case .move24h: return "|24h| > " + f.num(t, 1) + "%"
        case .depeg: return "|price − peg| > " + f.num(t, 2) + "%"
        case .drawdown: return "twr drawdown ≤ −" + f.num(abs(t), 1) + "%"
        }
    }

    /// Other rules on the same subject and kind family (design §08 review: "overlaps").
    public static func overlaps(_ r: AlertRule, in rules: [AlertRule]) -> [AlertRule] {
        rules.filter { $0.id != r.id && $0.subject == r.subject && $0.kind.label == r.kind.label }
    }

    /// Backtest a price rule against a price series: how many times it would have fired.
    /// nil for rules that aren't price based or without history.
    public static func backtest(_ r: AlertRule, series: PriceSeries?, baseTarget: Decimal? = nil) -> [Date]? {
        guard [.priceAbove, .priceBelow, .target].contains(r.kind), let pts = series?.points, pts.count > 1 else { return nil }
        let level = r.kind == .target ? (baseTarget?.double ?? 0) : r.threshold
        guard level > 0 else { return nil }
        let above = r.kind != .priceBelow
        var armed = true, fires: [Date] = []
        for p in pts {
            let met = above ? p.price >= level : p.price <= level
            let reset = above ? p.price < level * (1 - r.hysteresis / 100) : p.price > level * (1 + r.hysteresis / 100)
            if armed && met { fires.append(p.time); armed = false } else if !armed && reset { armed = true }
        }
        return fires
    }
}

// MARK: - Command grammar

/// `alert <subject> <verb> [number]`, shared by ⌘K and the setup sheet (design §08):
///   alert ada below .24 · alert tel above .02 · alert tel target · alert usdt depeg .5
///   alert main drawdown 60 · alert main value above 25k · alert ar pnl above 25
///   alert tel weight 40 · alert tel move 15 · alert any move 15
public enum AlertCommand {
    public struct Draft: Equatable, Sendable {
        public init(kind: AlertKind, subject: AlertSubject, threshold: Double) { self.kind = kind; self.subject = subject; self.threshold = threshold }
        public var kind: AlertKind
        public var subject: AlertSubject
        public var threshold: Double
    }
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case incomplete(String), unknownSubject(String), needsNumber(String), invalid(String)
        public var description: String {
            switch self {
            case let .incomplete(h): h
            case let .unknownSubject(s): "no held, watched or registry asset or portfolio called \(s)"
            case let .needsNumber(v): "\(v) needs a number"
            case let .invalid(m): m
            }
        }
    }

    public static let types: [(key: String, grammar: String)] = [
        ("price", "asset above|below price"), ("pnl", "asset above|below %"), ("value", "portfolio above|below $"), ("weight", "asset above %"),
        ("move", "asset|any 24h above %"), ("depeg", "stable beyond %"), ("target", "asset · uses scenario"), ("drawdown", "portfolio below −%"),
    ]

    /// `asset` resolves a symbol to a canonical id; `portfolio` a name to a context key.
    public static func parse(_ line: String, asset: (String) -> AssetID?, portfolio: (String) -> String?, style: NumberStyle = Fmt.current.style)
        -> Result<Draft, Failure> {
        var w = line.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if w.first == "alert" { w.removeFirst() }
        guard let subj = w.first else { return .failure(.incomplete("alert <asset|portfolio|any> <above|below|pnl|value|weight|move|depeg|target|drawdown> …")) }
        w.removeFirst()
        let num = { (s: String?) -> Double? in
            guard var s else { return nil }
            s = s.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "pp", with: "")
            let neg = s.hasPrefix("-") || s.hasPrefix("−")
            if neg { s.removeFirst() }
            return NumberInput.parse(s, style: style).map { neg ? -$0.double : $0.double }
        }
        var verb = w.first ?? ""
        var rest = Array(w.dropFirst())
        if ["pnl", "value"].contains(verb), let d = rest.first, ["above", "below", "over", "under"].contains(d) { verb += " " + d; rest.removeFirst() }
        if verb == "weight", rest.first == "above" { rest.removeFirst() }
        let n = num(rest.first)

        // Subject.
        let isAny = ["any", "held", "all-held"].contains(subj)
        let assetID = isAny ? nil : asset(subj)
        let pfKey = isAny ? nil : portfolio(subj)
        func need(_ v: String) -> Result<Draft, Failure> { .failure(.needsNumber(v)) }

        switch verb {
        case "above", "over", ">", "≥", "below", "under", "<", "≤":
            let up = ["above", "over", ">", "≥"].contains(verb)
            if let a = assetID { guard let n, n > 0 else { return need("price") }; return .success(Draft(kind: up ? .priceAbove : .priceBelow, subject: .asset(a), threshold: n)) }
            if let p = pfKey { guard let n, n > 0 else { return need("value") }; return .success(Draft(kind: up ? .valueAbove : .valueBelow, subject: .portfolio(p), threshold: n)) }
        case "pnl above", "pnl over", "pnl below", "pnl under", "pnl":
            guard let a = assetID else { break }
            guard let n else { return need("p&l") }
            let up = !verb.hasSuffix("below") && !verb.hasSuffix("under") && n >= 0
            return .success(Draft(kind: up ? .pnlAbove : .pnlBelow, subject: .asset(a), threshold: n))
        case "value above", "value over", "value below", "value under", "value":
            guard let p = pfKey else { break }
            guard let n, n > 0 else { return need("value") }
            return .success(Draft(kind: verb.hasSuffix("below") || verb.hasSuffix("under") ? .valueBelow : .valueAbove, subject: .portfolio(p), threshold: n))
        case "weight", "allocation":
            guard let a = assetID else { break }
            guard let n, n > 0, n < 100 else { return need("weight %") }
            return .success(Draft(kind: .weightAbove, subject: .asset(a), threshold: n))
        case "move", "24h":
            guard let n, n > 0 else { return need("24h move %") }
            if isAny { return .success(Draft(kind: .move24h, subject: .anyHeld, threshold: n)) }
            if let a = assetID { return .success(Draft(kind: .move24h, subject: .asset(a), threshold: n)) }
        case "depeg":
            let t = n.map(abs) ?? Stablecoins.tolerance.double * 100
            if isAny { return .success(Draft(kind: .depeg, subject: .anyStablecoin, threshold: t)) }
            if let a = assetID {
                guard Stablecoins.isStablecoin(a) else { return .failure(.invalid("depeg alerts are for stablecoins")) }
                return .success(Draft(kind: .depeg, subject: .asset(a), threshold: t))
            }
        case "target":
            if let a = assetID { return .success(Draft(kind: .target, subject: .asset(a), threshold: 0)) }
        case "drawdown", "dd":
            guard let p = pfKey else { break }
            guard let n, abs(n) > 0, abs(n) < 100 else { return need("drawdown %") }
            return .success(Draft(kind: .drawdown, subject: .portfolio(p), threshold: abs(n)))
        case "":
            return .failure(.incomplete("alert \(subj) above|below|pnl|weight|move|depeg|target|drawdown …"))
        default:
            return .failure(.invalid("unknown condition \"\(verb)\" · try above, below, pnl, weight, move, depeg, target, drawdown"))
        }
        if assetID == nil && pfKey == nil && !isAny { return .failure(.unknownSubject(subj.uppercased())) }
        return .failure(.invalid("\(verb) doesn't apply to \(subj.uppercased())"))
    }
}

extension Stablecoins {
    public static func isStablecoin(_ id: AssetID) -> Bool { peg(for: id) != nil }
}
