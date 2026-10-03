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
        case .unavailable: "watchlist, alerts and scenarios can't be read right now · they wait, nothing is overwritten"
        case let .newerSchema(v): "intel data is from a newer PF (schema \(v)) · watchlist, alerts and scenarios are read-only"
        case .unreadable: "intel data could not be read · it was set aside"
        }
    }
}

/// Two files, two protection classes (0.7 release hardening):
/// - `alerts.json` — rules, their log, migration markers: what alert evaluation reads and writes
///   from the menu bar while the Mac is locked. "Until first unlock" protection.
/// - `intel.json` (schema 2) — watchlist (entries, targets, notes) and scenarios: user-authored,
///   never needed while locked. "Complete" protection, like the ledger.
/// Atomic writes, previous versions kept as `*.prev.json`. A file from a newer schema is never
/// overwritten; an unreadable file is set aside, never deleted; a file that can't be read right
/// now is never treated as missing.
public struct IntelStore {
    public init(directory: URL) { self.directory = directory }
    public let directory: URL
    /// Private part (watchlist, scenarios). In schema 1 it held everything.
    public var url: URL { directory.appendingPathComponent("intel.json") }
    public var runtimeURL: URL { directory.appendingPathComponent("alerts.json") }
    public static let privateSchema = 2, runtimeSchema = 1

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    struct RuntimeFile: Codable {
        var schemaVersion = IntelStore.runtimeSchema
        var alerts: [AlertRule] = [], alertLog: [AlertEvent] = [], migrations: [String] = []
        init(alerts: [AlertRule], alertLog: [AlertEvent], migrations: [String]) { self.alerts = alerts; self.alertLog = alertLog; self.migrations = migrations }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? IntelStore.runtimeSchema
            alerts = try c.decodeIfPresent([AlertRule].self, forKey: .alerts) ?? []
            alertLog = try c.decodeIfPresent([AlertEvent].self, forKey: .alertLog) ?? []
            migrations = try c.decodeIfPresent([String].self, forKey: .migrations) ?? []
        }
    }
    struct PrivateFile: Codable {
        var schemaVersion = IntelStore.privateSchema
        var watchlist: [WatchItem] = [], scenarios: [PortfolioScenario] = []
        init(watchlist: [WatchItem], scenarios: [PortfolioScenario]) { self.watchlist = watchlist; self.scenarios = scenarios }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? IntelStore.privateSchema
            watchlist = try c.decodeIfPresent([WatchItem].self, forKey: .watchlist) ?? []
            scenarios = try c.decodeIfPresent([PortfolioScenario].self, forKey: .scenarios) ?? []
        }
    }

    public struct Loaded: Equatable {
        public var doc: IntelDocument
        /// intel.json exists but can't be read yet (locked): watchlist and scenarios are empty
        /// placeholders and must not be written.
        public var privateDeferred = false
        /// A schema 1 intel.json: write both files once.
        public var needsSplit = false
        /// Files that were unreadable and moved aside.
        public var setAside: [String] = []
    }

    /// nil: neither file yet (first 0.7 launch).
    public func load() throws -> Loaded? {
        let fm = FileManager.default
        let hasRuntime = fm.fileExists(atPath: runtimeURL.path), hasPrivate = fm.fileExists(atPath: url.path)
        guard hasRuntime || hasPrivate else { return nil }
        var out = Loaded(doc: IntelDocument())
        if hasRuntime {
            guard let data = try? Data(contentsOf: runtimeURL) else { throw IntelStoreError.unavailable }
            let v = Self.schema(data)
            if v > Self.runtimeSchema { throw IntelStoreError.newerSchema(v) }
            if let r = try? Self.decoder.decode(RuntimeFile.self, from: data) {
                out.doc.alerts = r.alerts; out.doc.alertLog = r.alertLog; out.doc.migrations = r.migrations
            } else {
                out.setAside.append(setAside(runtimeURL, "alerts"))
            }
        }
        if hasPrivate {
            guard let data = try? Data(contentsOf: url) else {
                // Locked. Without alerts.json the rules may only exist in this file: wait for all of it.
                guard hasRuntime else { throw IntelStoreError.unavailable }
                out.privateDeferred = true
                return out
            }
            let v = Self.schema(data)
            if v > Self.privateSchema { throw IntelStoreError.newerSchema(v) }
            if v <= 1, let legacy = try? Self.decoder.decode(IntelDocument.self, from: data) {
                out.doc.watchlist = legacy.watchlist; out.doc.scenarios = legacy.scenarios
                // alerts.json wins if a split was interrupted after writing it.
                if !hasRuntime { out.doc.alerts = legacy.alerts; out.doc.alertLog = legacy.alertLog; out.doc.migrations = legacy.migrations }
                out.needsSplit = true
            } else if v > 1, let p = try? Self.decoder.decode(PrivateFile.self, from: data) {
                out.doc.watchlist = p.watchlist; out.doc.scenarios = p.scenarios
            } else {
                out.setAside.append(setAside(url, "intel"))
            }
        }
        return out
    }

    /// Rules, log and migrations. Runs while locked.
    public func saveRuntime(_ d: IntelDocument) throws {
        try write(RuntimeFile(alerts: d.alerts, alertLog: d.alertLog, migrations: d.migrations), to: runtimeURL,
                  prev: "alerts.prev.json", protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    /// Watchlist and scenarios. Fails while locked (protected data unavailable).
    public func savePrivate(_ d: IntelDocument) throws {
        try write(PrivateFile(watchlist: d.watchlist, scenarios: d.scenarios), to: url, prev: "intel.prev.json", protection: .completeFileProtection)
    }

    /// Both parts; runtime first, so an interrupted schema 1 → 2 split resolves to alerts.json.
    public func save(_ d: IntelDocument) throws { try saveRuntime(d); try savePrivate(d) }

    private func write<T: Encodable>(_ v: T, to file: URL, prev: String, protection: Data.WritingOptions) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(v)
        if fm.fileExists(atPath: file.path) {
            let p = directory.appendingPathComponent(prev)
            try? fm.removeItem(at: p)
            try? fm.copyItem(at: file, to: p)
        }
        try data.write(to: file, options: [.atomic, protection])
    }

    private static func schema(_ data: Data) -> Int {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] as? Int ?? 0
    }

    private func setAside(_ file: URL, _ name: String) -> String {
        let dst = "\(name).unreadable-\(Int(Date().timeIntervalSince1970)).json"
        try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(dst))
        return dst
    }
}

extension IntelDocument {
    public static let moveNote = "from 0.6 · 24h move alert"

    /// 0.6 had two notification settings; 0.7 makes them alert rules (design §13:
    /// "Notifications → Alerts"). Applied once; the 0.6 settings are left as they were so a
    /// downgrade to 0.6 still behaves the same.
    public mutating func migrateNotifications(alertThreshold: Double, depegAlerts: Bool, now: Date) {
        let key = "0.6-notifications"
        // An early 0.7 build migrated the 24h alert to "any held asset". 0.6 watched the active
        // portfolio's 24h change: put that back, once, keeping the rule's number and state.
        let fix = "0.6-move-portfolio"
        if migrations.contains(key), !migrations.contains(fix) {
            migrations.append(fix)
            for i in alerts.indices where alerts[i].kind == .move24h && alerts[i].subject == .anyHeld && alerts[i].note == Self.moveNote {
                alerts[i].subject = .portfolio(AlertSubject.activePortfolio)
            }
        }
        guard !migrations.contains(key) else { return }
        migrations += [key, fix]
        if alertThreshold > 0 {
            // Same semantics as 0.6: |active portfolio 24h change| ≥ threshold, at most once a day,
            // with 0.6's notification text.
            alerts.append(AlertRule(number: nextAlertNumber, kind: .move24h, subject: .portfolio(AlertSubject.activePortfolio), threshold: alertThreshold,
                                    repeatMode: .daily, createdAt: now, note: Self.moveNote))
        }
        if depegAlerts {
            alerts.append(AlertRule(number: nextAlertNumber, kind: .depeg, subject: .anyStablecoin, threshold: Double(truncating: Stablecoins.tolerance * 100 as NSNumber),
                                    repeatMode: .cross, createdAt: now, note: "from 0.6 · depeg alert"))
        }
    }
}
