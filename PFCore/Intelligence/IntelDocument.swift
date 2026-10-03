import Foundation

/// 0.7 "Portfolio Intelligence" data: the watchlist, alert rules (+ their log) and saved
/// scenarios. Stored in `intel.json` next to `portfolio.json`; local to this Mac in 0.7.0
/// (see docs/PLAN-0.7.md · decisions). The ledger never depends on it: deleting or
/// corrupting this file can't change a transaction.
public struct IntelDocument: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion = IntelDocument.currentSchema
    public var watchlist: [WatchItem] = []
    public var alerts: [AlertRule] = []
    public var alertLog: [AlertEvent] = []
    public var scenarios: [PortfolioScenario] = []
    /// One-time migrations already applied (idempotence), e.g. "0.6-notifications".
    public var migrations: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        watchlist = try c.decodeIfPresent([WatchItem].self, forKey: .watchlist) ?? []
        alerts = try c.decodeIfPresent([AlertRule].self, forKey: .alerts) ?? []
        alertLog = try c.decodeIfPresent([AlertEvent].self, forKey: .alertLog) ?? []
        scenarios = try c.decodeIfPresent([PortfolioScenario].self, forKey: .scenarios) ?? []
        migrations = try c.decodeIfPresent([String].self, forKey: .migrations) ?? []
    }

    public var nextAlertNumber: Int { (alerts.map(\.number).max() ?? 0) + 1 }

    /// Keeps the log bounded: the last 30 days, at most 200 entries.
    public mutating func trimLog(now: Date) {
        alertLog.removeAll { now.timeIntervalSince($0.at) > 30 * 86400 }
        if alertLog.count > 200 { alertLog.removeFirst(alertLog.count - 200) }
    }
}

public enum IntelStoreError: Error, Equatable, CustomStringConvertible {
    case newerSchema(Int), unreadable
    /// The file exists but can't be read right now (e.g. file protection while locked).
    /// Nothing is overwritten; the caller retries later.
    case unavailable
    public var description: String {
        switch self {
        case .unavailable: "intel.json can't be read right now · watchlist, alerts and scenarios wait, nothing is overwritten"
        case let .newerSchema(v): "intel.json is from a newer PF (schema \(v)) · watchlist, alerts and scenarios are read-only"
        case .unreadable: "intel.json could not be read · it was set aside and a fresh one started"
        }
    }
}

/// `intel.json`: atomic writes, the previous version kept as `intel.prev.json`. A file from a
/// newer schema is never overwritten (the app goes read-only for this data instead).
public struct IntelStore {
    public init(directory: URL) { self.directory = directory }
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("intel.json") }
    var prevURL: URL { directory.appendingPathComponent("intel.prev.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// nil: no file yet (first 0.7 launch). A file that exists but can't be read is never
    /// treated as missing (that would start empty and overwrite it).
    public func load() throws -> IntelDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw IntelStoreError.unavailable }
        let v = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] as? Int ?? 0
        if v > IntelDocument.currentSchema { throw IntelStoreError.newerSchema(v) }
        guard let d = try? Self.decoder.decode(IntelDocument.self, from: data) else {
            try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("intel.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            throw IntelStoreError.unreadable
        }
        return d
    }

    public func save(_ d: IntelDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: prevURL)
            try? FileManager.default.copyItem(at: url, to: prevURL)
        }
        // Alerts are evaluated (and saved) from the menu bar while the Mac is locked, when
        // "complete" protection refuses to create or read files. Encrypted at rest until the
        // first unlock after boot.
        try Self.encoder.encode(d).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension IntelDocument {
    /// 0.6 had two notification settings; 0.7 makes them alert rules (design §13:
    /// "Notifications → Alerts"). Applied once; the 0.6 settings are left as they were so a
    /// downgrade to 0.6 still behaves the same.
    public mutating func migrateNotifications(alertThreshold: Double, depegAlerts: Bool, now: Date) {
        let key = "0.6-notifications"
        guard !migrations.contains(key) else { return }
        migrations.append(key)
        if alertThreshold > 0 {
            alerts.append(AlertRule(number: nextAlertNumber, kind: .move24h, subject: .anyHeld, threshold: alertThreshold,
                                    repeatMode: .daily, createdAt: now, note: "from 0.6 · 24h move alert"))
        }
        if depegAlerts {
            alerts.append(AlertRule(number: nextAlertNumber, kind: .depeg, subject: .anyStablecoin, threshold: Double(truncating: Stablecoins.tolerance * 100 as NSNumber),
                                    repeatMode: .cross, createdAt: now, note: "from 0.6 · depeg alert"))
        }
    }
}
