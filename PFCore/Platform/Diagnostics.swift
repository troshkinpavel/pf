import Foundation
import os

/// Privacy-safe operational log: a bounded ring of events (`diagnostics.json` next to the
/// ledger) mirrored to the unified log. An event is a category, a level, a fixed code from the
/// source (`StaticString`, so no runtime text can get in) and optionally an error *kind* — the
/// enum case name, never its message. Nothing here can carry names, amounts, notes, paths or
/// account identifiers.
@MainActor
public final class DiagnosticLog {
    public enum Category: String, Codable, CaseIterable, Sendable { case app, sync, market, backup, ledger, lock, alert }
    public enum Level: String, Codable, Sendable { case info, warning, error }

    public struct Event: Codable, Equatable, Sendable {
        public let at: Date
        public let category: Category
        public let level: Level
        public let code: String
        public let kind: String?
    }

    public static let capacity = 200
    public private(set) var events: [Event] = []
    private let url: URL?

    public init(directory: URL?) {
        url = directory?.appendingPathComponent("diagnostics.json")
        if let url, let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Event].self, from: d) { events = Array(e.suffix(Self.capacity)) }
    }

    /// `kind`: an error code the caller built from fixed parts (e.g. "ck11"), never runtime text.
    public func record(_ category: Category, _ level: Level, _ code: StaticString, error: Error? = nil, kind detail: String? = nil, source: MarketSource? = nil, now: Date = Date()) {
        var kind = error.map(Self.kind) ?? detail
        if let source { kind = source.rawValue + (kind.map { " " + $0 } ?? "") }
        let e = Event(at: now, category: category, level: level, code: "\(code)", kind: kind)
        events.append(e)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
        let log = Logger(subsystem: "io.github.troskinpavel.pf", category: category.rawValue)
        let line = e.code + (e.kind.map { " · " + $0 } ?? "")
        switch level {
        case .info: log.info("\(line, privacy: .public)")
        case .warning: log.warning("\(line, privacy: .public)")
        case .error: log.error("\(line, privacy: .public)")
        }
        if let url, let d = try? JSONEncoder().encode(events) { try? d.write(to: url, options: .atomic) }
    }

    /// The error's case or type name only — `unavailable("…")` becomes "unavailable".
    public nonisolated static func kind(_ e: Error) -> String {
        switch e {
        case let m as MarketError:
            switch m { case .offline: return "offline"; case .rateLimited: return "rateLimited"; case .unavailable(let c): return "unavailable\(c)"
                       case .decoding: return "decoding"; case .unsupported: return "unsupported" }
        case let i as PortfolioDocument.ImportError:
            switch i { case .unreadable: return "unreadable"; case .newerSchema: return "newerSchema"; case .invalid: return "invalid" }
        case let s as SnapshotError:
            switch s { case .writeFailed: return "writeFailed"; case .verificationFailed: return "verificationFailed"; case .unreadable: return "unreadable"
                       case .newerFormat: return "newerFormat"; case .invalid: return "invalid" }
        case let s as SyncStoreError:
            if case .unavailable = s { return "unavailable" }
            return "\(s)"   // payload-free cases only
        default:
            return String(describing: type(of: e))
        }
    }
}

/// Plain-text report for bug reports. Only operational facts; see `DiagnosticLog`.
public enum DiagnosticReport {
    public struct Input: Sendable {
        public init() {}
        public var app = "", build = "", os = "", registry = ""
        public var transactionBucket = ""            // "1–99", not a count
        public var flags: [(String, String)] = []    // settings that change behaviour
        public var sync: [(String, String)] = []
        public var market: [(String, String)] = []
        public var backups: [(String, String)] = []
        public var health: [String] = []
        public var events: [DiagnosticLog.Event] = []
        public var now = Date()
    }

    public static func bucket(_ n: Int) -> String {
        switch n { case 0: "0"; case ..<100: "1–99"; case ..<1000: "100–999"; case ..<10000: "1k–9.9k"; default: "10k+" }
    }

    public static func age(_ d: Date?, now: Date) -> String {
        guard let d else { return "never" }
        let s = Int(now.timeIntervalSince(d))
        switch s { case ..<60: return "\(max(0, s))s ago"; case ..<3600: return "\(s / 60)m ago"; case ..<86400: return "\(s / 3600)h ago"; default: return "\(s / 86400)d ago" }
    }

    public static func make(_ i: Input) -> String {
        var out = ["PF TERMINAL DIAGNOSTIC REPORT", "contains no portfolio names, values, quantities, notes, keys or account ids", ""]
        func section(_ t: String, _ rows: [(String, String)]) {
            out.append(t)
            out += rows.map { "  " + $0.0.padding(toLength: 18, withPad: " ", startingAt: 0) + $0.1 }
            out.append("")
        }
        section("APP", [("version", "\(i.app) (\(i.build))"), ("macos", i.os), ("registry", i.registry), ("transactions", i.transactionBucket)])
        section("SETTINGS", i.flags)
        section("SYNC", i.sync)
        section("MARKET DATA", i.market)
        section("RECOVERY", i.backups)
        out.append("DATA HEALTH"); out += i.health.map { "  " + $0 }; out.append("")
        out.append("RECENT EVENTS (\(i.events.count))")
        let f = ISO8601DateFormatter()
        out += i.events.suffix(60).reversed().map { "  \(f.string(from: $0.at))  \($0.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \($0.category.rawValue).\($0.code)" + ($0.kind.map { " · " + $0 } ?? "") }
        return out.joined(separator: "\n")
    }
}
