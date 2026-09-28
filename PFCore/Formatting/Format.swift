import Foundation

public enum NumberStyle: String, Codable, CaseIterable, Sendable {
    case comma = "1,234.56", space = "1 234.56", dot = "1.234,56"
    public var group: String { switch self { case .comma: ","; case .space: " "; case .dot: "." } }
    public var decimal: String { self == .dot ? "," : "." }
}

/// Deterministic, locale-independent number formatting matching the terminal design.
/// Sign is always explicit on deltas; hyphen-minus keeps widths stable.
public struct Fmt: Sendable {
    public init(style: NumberStyle = .comma, currency: String = "USD") { self.style = style; self.currency = currency }
    public var style: NumberStyle = .comma
    public var currency: String = "USD"

    public nonisolated(unsafe) static var current = Fmt()

    public var symbol: String {
        switch currency { case "EUR": "€"; case "CHF": "CHF "; case "GBP": "£"; default: "$" }
    }

    public func num(_ v: Double, _ dp: Int) -> String {
        guard v.isFinite else { return "—" }
        let neg = v < 0 && String(format: "%.\(dp)f", abs(v)) != String(format: "%.\(dp)f", 0.0)
        let s = String(format: "%.\(dp)f", abs(v))
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let i = String(parts[0])
        var grouped = ""
        for (k, ch) in i.enumerated() {
            if k > 0 && (i.count - k) % 3 == 0 { grouped += style.group }
            grouped.append(ch)
        }
        return (neg ? "-" : "") + grouped + (parts.count > 1 ? style.decimal + parts[1] : "")
    }

    public func money(_ v: Double?, _ dp: Int = 2) -> String {
        guard let v else { return symbol + "—" }
        return (v < 0 ? "-" : "") + symbol + num(abs(v), dp)
    }
    public func money(_ v: Decimal?, _ dp: Int = 2) -> String { money(v?.double, dp) }

    public func signed(_ v: Double?, _ dp: Int = 2) -> String {
        guard let v else { return symbol + "—" }
        return (v >= 0 ? "+" : "-") + symbol + num(abs(v), dp)
    }
    public func signed(_ v: Decimal?, _ dp: Int = 2) -> String { signed(v?.double, dp) }

    public func pct(_ v: Double?, _ dp: Int = 2) -> String {
        guard let v, v.isFinite else { return "—" }
        return (v >= 0 ? "+" : "") + num(v, dp) + "%"
    }

    /// Price with adaptive precision: ≥1 → 2dp, otherwise 4 significant digits.
    public func priceDigits(_ p: Double) -> String {
        guard p.isFinite else { return "—" }
        if p >= 1 { return num(p, 2) }
        var t = String(format: "%.4g", p)
        if t.contains("e") { t = String(format: "%.8f", p) }
        if t.contains(".") { while t.hasSuffix("0") { t.removeLast() } }
        if t.hasSuffix(".") { t.removeLast() }
        let frac = t.split(separator: ".").dropFirst().first?.count ?? 0
        if frac < 2 { t = String(format: "%.2f", p) }
        return t.replacingOccurrences(of: ".", with: style.decimal)
    }
    public func price(_ p: Double?) -> String { p.map { symbol + priceDigits($0) } ?? symbol + "—" }
    public func price(_ p: Decimal?) -> String { price(p?.double) }

    /// Round target levels (presets): no cents at or above 1,000, e.g. "$150,000".
    public func level(_ p: Double) -> String { p >= 1000 ? money(p, 0) : price(p) }
    public func level(_ p: Decimal) -> String { level(p.double) }

    public func amount(_ a: Decimal) -> String { amount(a.double) }
    public func amount(_ a: Double) -> String {
        if abs(a) >= 1000 { return num(a, 0) }
        var t = String(format: "%.4f", a)
        while t.contains(".") && t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.replacingOccurrences(of: ".", with: style.decimal)
    }

    public func compact(_ v: Double?) -> String {
        guard let v else { return symbol + "—" }
        let a = abs(v)
        let (d, s): (Double, String) = a >= 1e12 ? (1e12, "T") : a >= 1e9 ? (1e9, "B") : a >= 1e6 ? (1e6, "M") : a >= 1e3 ? (1e3, "k") : (1, "")
        let x = a / d
        return (v < 0 ? "-" : "") + symbol + String(format: "%.\(x >= 100 ? 1 : 2)f", x).replacingOccurrences(of: ".", with: style.decimal) + s
    }
    public func compact(_ v: Decimal?) -> String { compact(v?.double) }
}

public enum DateFmt {
    private static func f(_ format: String, _ locale: String = "en_US_POSIX") -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: locale); d.dateFormat = format; return d
    }
    private static let ymdF = f("yyyy-MM-dd"), hmsF = f("HH:mm:ss"), hmF = f("HH:mm"), cardF = f("d MMM yyyy", "en_GB")
    private static let lock = NSLock()
    private static func run(_ fm: DateFormatter, _ d: Date) -> String { lock.lock(); defer { lock.unlock() }; return fm.string(from: d) }

    public static func ymd(_ d: Date) -> String { run(ymdF, d) }
    public static func hms(_ d: Date) -> String { run(hmsF, d) }
    public static func hm(_ d: Date) -> String { run(hmF, d) }
    public static func card(_ d: Date) -> String { run(cardF, d).uppercased() }
    public static func parseYMD(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let d = ymdF.date(from: s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return d.addingTimeInterval(12 * 3600)   // noon local: avoids day shifts across time zones
    }

    /// Relative axis label: -42m, -5h, -3d, -2mo.
    public static func ago(minutes m: Double) -> String {
        let m = m.rounded()
        if m <= 0 { return "now" }
        if m < 120 { return "-\(Int(m))m" }
        if m < 2880 { return "-\(Int((m / 60).rounded()))h" }
        if m < 86400 { return "-\(Int((m / 1440).rounded()))d" }
        return "-\(Int((m / 43200).rounded()))mo"
    }

    public static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Parses human numeric input: "500000", "500k", "1.2m", "$0.10", ".1", "1,000".
public enum NumberInput {
    /// Parse with the user's number style: in "1.234,56" style "," is the decimal separator.
    /// Plain "0.1" (a single "." followed by 1–2 or 4+ digits) is always accepted as a decimal.
    public static func parse(_ raw: String?, style: NumberStyle = Fmt.current.style) -> Decimal? {
        guard var s = raw?.lowercased() else { return nil }
        s = s.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "$", with: "")
        if style == .dot && s.contains(",") {
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if style == .dot && s.filter({ $0 == "." }).count > 1 {
            s = s.replacingOccurrences(of: ".", with: "")        // "1.234.567" grouping only
        } else {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        var mult: Decimal = 1
        if s.hasSuffix("k") { mult = 1_000; s.removeLast() }
        else if s.hasSuffix("m") { mult = 1_000_000; s.removeLast() }
        else if s.hasSuffix("b") { mult = 1_000_000_000; s.removeLast() }
        if s.hasPrefix(".") { s = "0" + s }
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." }), s.filter({ $0 == "." }).count <= 1,
              let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), d > 0 else { return nil }
        return d * mult
    }

    /// Target input: absolute price or a multiple of current ("25x").
    public static func target(_ raw: String, current: Decimal, style: NumberStyle = Fmt.current.style) -> Decimal? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix("x") {
            guard let m = parse(String(s.dropLast()), style: style) else { return nil }
            return current * m
        }
        return parse(s, style: style)
    }
}

extension Decimal {
    public var double: Double { NSDecimalNumber(decimal: self).doubleValue }
    /// Double → Decimal via its shortest decimal representation (avoids 0.00431 → 0.0043099999…).
    public static func of(_ d: Double) -> Decimal {
        guard d.isFinite else { return 0 }
        return Decimal(string: String(format: "%.12g", d), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(d)
    }
    public var isPositive: Bool { self > 0 }
    public func rounded(_ scale: Int) -> Decimal {
        var v = self, r = Decimal()
        NSDecimalRound(&r, &v, scale, .plain)
        return r
    }
}
