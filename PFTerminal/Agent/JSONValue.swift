import Foundation

/// A JSON value for the MCP wire format: requests are parsed into it, responses are built with it.
/// Numbers keep their textual form on output so money never goes through binary floating point twice.
enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case num(Double)
    /// An exact decimal (amounts, prices): written as its plain digits.
    case dec(Decimal)
    case str(String)
    case arr([JSON])
    case obj([(String, JSON)])

    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.num(x), .num(y)): return x == y
        case let (.dec(x), .dec(y)): return x == y
        case let (.str(x), .str(y)): return x == y
        case let (.arr(x), .arr(y)): return x == y
        case let (.obj(x), .obj(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    // MARK: reading

    subscript(_ k: String) -> JSON? {
        if case let .obj(o) = self { return o.first { $0.0 == k }?.1 }
        return nil
    }
    var string: String? { if case let .str(s) = self { return s }; return nil }
    var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
    var double: Double? {
        switch self { case let .num(d): return d; case let .dec(d): return d.double; default: return nil }
    }
    var object: [(String, JSON)]? { if case let .obj(o) = self { return o }; return nil }
    var array: [JSON]? { if case let .arr(a) = self { return a }; return nil }
    var isNull: Bool { self == .null }

    // MARK: parsing

    enum ParseError: Error { case invalid, tooDeep }

    /// Strict JSON (RFC 8259). Numbers keep full precision as `.dec` when they are exact decimals.
    static func parse(_ data: Data) throws -> JSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError.invalid }
        return v
    }

    static func parse(_ s: String) throws -> JSON { try parse(Data(s.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 64 else { throw ParseError.tooDeep }
            guard i < bytes.count else { throw ParseError.invalid }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1; skipWS()
                var out: [(String, JSON)] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .obj(out) }
                while true {
                    skipWS()
                    guard case let .str(k) = try string() else { throw ParseError.invalid }
                    skipWS()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError.invalid }
                    i += 1; skipWS()
                    let v = try value(depth: depth + 1)
                    if out.contains(where: { $0.0 == k }) { throw ParseError.invalid }   // duplicate keys are ambiguous
                    out.append((k, v))
                    skipWS()
                    guard i < bytes.count else { throw ParseError.invalid }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .obj(out) }
                    throw ParseError.invalid
                }
            case UInt8(ascii: "["):
                i += 1; skipWS()
                var out: [JSON] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .arr(out) }
                while true {
                    skipWS()
                    out.append(try value(depth: depth + 1))
                    skipWS()
                    guard i < bytes.count else { throw ParseError.invalid }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .arr(out) }
                    throw ParseError.invalid
                }
            case UInt8(ascii: "\""): return try string()
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw ParseError.invalid }
            i += u.count
        }

        mutating func number() throws -> JSON {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            func digits() -> Int { let s = i; while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }; return i - s }
            guard i < bytes.count else { throw ParseError.invalid }
            if bytes[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw ParseError.invalid }
            var exact = true
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") { i += 1; guard digits() > 0 else { throw ParseError.invalid } }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                exact = false
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw ParseError.invalid }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if exact, text.count <= 40, let d = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) { return .dec(d) }
            guard let d = Double(text), d.isFinite else { throw ParseError.invalid }
            return .num(d)
        }

        mutating func string() throws -> JSON {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError.invalid }
            i += 1
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; return .str(String(decoding: out, as: UTF8.self)) }
                if c < 0x20 { throw ParseError.invalid }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw ParseError.invalid }
                    switch bytes[i] {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if (0xD800...0xDBFF).contains(cp) {
                            guard i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") else { throw ParseError.invalid }
                            i += 2
                            let lo = try hex4()
                            guard (0xDC00...0xDFFF).contains(lo) else { throw ParseError.invalid }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(cp) { throw ParseError.invalid }
                        guard let sc = Unicode.Scalar(cp) else { throw ParseError.invalid }
                        out.append(contentsOf: Array(String(Character(sc)).utf8))
                    default: throw ParseError.invalid
                    }
                    i += 1
                    continue
                }
                out.append(c); i += 1
            }
            throw ParseError.invalid
        }

        /// Reads the 4 hex digits after `\u`; leaves `i` on the last one.
        mutating func hex4() throws -> UInt32 {
            guard i + 4 < bytes.count else { throw ParseError.invalid }
            var v: UInt32 = 0
            for k in 1...4 {
                let c = bytes[i + k]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw ParseError.invalid
                }
                v = v * 16 + d
            }
            i += 4
            return v
        }
    }

    // MARK: writing

    /// Compact, single-line JSON (MCP stdio framing is one message per line).
    var text: String {
        var s = ""
        write(&s)
        return s
    }

    private func write(_ s: inout String) {
        switch self {
        case .null: s += "null"
        case let .bool(b): s += b ? "true" : "false"
        case let .num(d): s += d.isFinite ? Self.format(d) : "null"
        case let .dec(d): s += NSDecimalNumber(decimal: d).stringValue
        case let .str(v): Self.quote(v, into: &s)
        case let .arr(a):
            s += "["
            for (k, v) in a.enumerated() { if k > 0 { s += "," }; v.write(&s) }
            s += "]"
        case let .obj(o):
            s += "{"
            for (k, (key, v)) in o.enumerated() { if k > 0 { s += "," }; Self.quote(key, into: &s); s += ":"; v.write(&s) }
            s += "}"
        }
    }

    private static func format(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    private static func quote(_ v: String, into s: inout String) {
        s += "\""
        for u in v.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 { s += String(format: "\\u%04x", u.value) } else { s.unicodeScalars.append(u) }
            }
        }
        s += "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral v: String) { self = .str(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(integerLiteral v: Int) { self = .num(Double(v)) }
    init(floatLiteral v: Double) { self = .num(v) }
    init(arrayLiteral v: JSON...) { self = .arr(v) }
    init(dictionaryLiteral v: (String, JSON)...) { self = .obj(v) }
}

extension JSON {
    static func opt(_ s: String?) -> JSON { s.map(JSON.str) ?? .null }
    static func opt(_ d: Double?) -> JSON { d.flatMap { $0.isFinite ? JSON.num($0) : nil } ?? .null }
    static func opt(_ d: Decimal?) -> JSON { d.map(JSON.dec) ?? .null }
    static func int(_ i: Int) -> JSON { .num(Double(i)) }
    /// Rounded percentage / pp figure for agents (2 decimals is plenty and stable across runs).
    static func pct(_ d: Double?, _ digits: Int = 2) -> JSON {
        guard let d, d.isFinite else { return .null }
        let m = pow(10, Double(digits))
        return .num((d * m).rounded() / m)
    }
    static func date(_ d: Date?) -> JSON { d.map { .str(ISO8601DateFormatter().string(from: $0)) } ?? .null }

    /// An object without the fields whose value is `nil` (omitted, not null: redacted fields vanish).
    static func compact(_ pairs: [(String, JSON?)]) -> JSON { .obj(pairs.compactMap { k, v in v.map { (k, $0) } }) }
}
