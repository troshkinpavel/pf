import CryptoKit
import Foundation

/// Local recovery snapshots of the ledger, independent of iCloud: `backups/` next to
/// `portfolio.json`. Each file is a versioned envelope around the same Codable document the
/// app saves. It holds no settings, keys, price or chart caches, widget snapshots or UI state.
/// Every snapshot is read back and compared before it counts as written.
public struct LedgerSnapshot: Codable, Equatable {
    public static let format = "pf-ledger-snapshot"
    public static let currentVersion = 1

    public var format = LedgerSnapshot.format
    public var version = LedgerSnapshot.currentVersion
    public var createdAt: Date
    public var reason: String
    public var appVersion: String?
    public var contentHash: String
    public var portfolios: Int
    public var transactions: Int
    public var document: PortfolioDocument
}

public struct SnapshotInfo: Identifiable, Equatable, Sendable {
    public var id: String { url.lastPathComponent }
    public let url: URL
    public let createdAt: Date
    public let reason: String
    public let portfolios: Int
    public let transactions: Int
    public let bytes: Int
    public let contentHash: String
    /// Taken right before a destructive operation (import, restore, remove…), not by the rolling schedule.
    public var isSafety: Bool { reason.hasPrefix("before-") }
}

public enum SnapshotError: Error, Equatable, CustomStringConvertible {
    case writeFailed(String), verificationFailed, unreadable, newerFormat(Int), invalid(String)
    public var description: String {
        switch self {
        case let .writeFailed(m): "could not write the snapshot (\(m))"
        case .verificationFailed: "the written snapshot did not read back identically"
        case .unreadable: "not a PF snapshot"
        case let .newerFormat(v): "snapshot format v\(v) is newer than this app"
        case let .invalid(m): m
        }
    }
}

public struct SnapshotStore {
    public enum Reason: String, CaseIterable, Sendable {
        case auto, daily
        case beforeImport = "before-import", beforeRestore = "before-restore", beforeICloud = "before-icloud"
        case beforeRemovePosition = "before-remove-position", beforeDeletePortfolio = "before-delete-portfolio"
        /// 0.8: before an agent's confirmed edit or deletion of a transaction.
        case beforeAgent = "before-agent"
    }

    /// Retention: newest `recent` rolling snapshots, one per day for `days` days, newest `safety`
    /// pre-operation snapshots, and never more than `maxBytes` in total (the newest 3 always stay).
    public struct Policy: Sendable {
        public init(recent: Int = 8, days: Int = 14, safety: Int = 8, maxBytes: Int = 64 << 20) { self.recent = recent; self.days = days; self.safety = safety; self.maxBytes = maxBytes }
        public var recent, days, safety, maxBytes: Int
    }

    public init(directory: URL, policy: Policy = Policy()) { self.directory = directory.appendingPathComponent("backups", isDirectory: true); self.policy = policy }
    public let directory: URL
    public let policy: Policy

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // compact: snapshots are many, not edited by hand
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// The ledger as snapshotted: no settings, no export stamp.
    public static func ledger(_ doc: PortfolioDocument) -> PortfolioDocument {
        var d = doc; d.settings = nil; d.exportedAt = nil; return d
    }

    public static func contentHash(_ doc: PortfolioDocument) -> String {
        let data = (try? encoder.encode(ledger(doc))) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes, reads back and compares; throws if any step fails (the caller then must not go on
    /// with the operation that needed the snapshot).
    @discardableResult
    public func create(_ doc: PortfolioDocument, reason: Reason, now: Date = Date(), appVersion: String? = nil) throws -> SnapshotInfo {
        let ledger = Self.ledger(doc)
        let snap = LedgerSnapshot(createdAt: now, reason: reason.rawValue, appVersion: appVersion, contentHash: Self.contentHash(ledger),
                                  portfolios: ledger.portfolios.count, transactions: ledger.transactions.count, document: ledger)
        let fm = FileManager.default
        var url: URL
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
            url = directory.appendingPathComponent("pf-\(f.string(from: now))-\(reason.rawValue).json")
            var n = 2
            while fm.fileExists(atPath: url.path) { url = directory.appendingPathComponent("pf-\(f.string(from: now))-\(reason.rawValue)-\(n).json"); n += 1 }
            try Self.encoder.encode(snap).write(to: url, options: [.atomic, .completeFileProtection])
        } catch { throw SnapshotError.writeFailed(ProtectedData.isUnavailable(error) ? ProtectedData.reason : String(describing: type(of: error))) }
        // Compared as encoded (the file format keeps whole seconds), byte for byte via the hash.
        guard let back = try? read(url), back.contentHash == snap.contentHash, Self.contentHash(back.document) == snap.contentHash else {
            try? fm.removeItem(at: url)
            throw SnapshotError.verificationFailed
        }
        prune(now: now)
        return info(back, url)
    }

    /// A rolling snapshot, unless the newest one already holds this exact ledger.
    @discardableResult
    public func snapshotIfChanged(_ doc: PortfolioDocument, reason: Reason = .auto, now: Date = Date(), appVersion: String? = nil) throws -> SnapshotInfo? {
        guard !doc.transactions.isEmpty || doc.portfolios.count > 1 else { return nil }
        if list().first?.contentHash == Self.contentHash(doc) { return nil }
        return try create(doc, reason: reason, now: now, appVersion: appVersion)
    }

    public func list() -> [SnapshotInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("pf-") }
            .compactMap { u in (try? read(u)).map { info($0, u) } }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id }
    }

    /// Decodes and validates a snapshot for restore. Nothing is applied.
    public func load(_ s: SnapshotInfo) throws -> PortfolioDocument {
        let snap = try read(s.url)
        let doc = PortfolioDocument.migrate(snap.document)
        if let e = doc.validationErrors(ledger: false).first { throw SnapshotError.invalid(e) }
        return doc
    }

    func read(_ url: URL) throws -> LedgerSnapshot {
        guard let data = try? Data(contentsOf: url),
              let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              probe["format"] as? String == LedgerSnapshot.format else { throw SnapshotError.unreadable }
        let v = probe["version"] as? Int ?? 0
        guard v <= LedgerSnapshot.currentVersion else { throw SnapshotError.newerFormat(v) }
        guard let s = try? PortfolioDocument.decoder.decode(LedgerSnapshot.self, from: data) else { throw SnapshotError.unreadable }
        return s
    }

    private func info(_ s: LedgerSnapshot, _ u: URL) -> SnapshotInfo {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        return SnapshotInfo(url: u, createdAt: s.createdAt, reason: s.reason, portfolios: s.portfolios, transactions: s.transactions,
                            bytes: bytes, contentHash: s.contentHash)
    }

    public func prune(now: Date = Date()) {
        let all = list()
        var keep = Set<String>()
        let rolling = all.filter { !$0.isSafety }
        rolling.prefix(policy.recent).forEach { keep.insert($0.id) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        var days = Set<DateComponents>()
        for s in rolling where now.timeIntervalSince(s.createdAt) < Double(policy.days) * 86400 {
            if days.insert(cal.dateComponents([.year, .month, .day], from: s.createdAt)).inserted { keep.insert(s.id) }
        }
        all.filter(\.isSafety).prefix(policy.safety).forEach { keep.insert($0.id) }
        var bytes = 0
        for (i, s) in all.enumerated() where keep.contains(s.id) {
            bytes += s.bytes
            if bytes > policy.maxBytes && i >= 3 { keep.remove(s.id) }
        }
        for s in all where !keep.contains(s.id) { try? FileManager.default.removeItem(at: s.url) }
    }
}
