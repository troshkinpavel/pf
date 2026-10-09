import Foundation

// Platform-neutral sync layer (Foundation only). Reused as-is by a future iOS target.
//
// What syncs: durable, user-owned domain records — portfolios, transactions, asset identities.
// What never syncs: market prices and caches, price history, widget snapshots, derived P&L,
// UI state, settings, Keychain secrets. Every device recomputes derived state itself.

public enum SyncKind: String, Codable, CaseIterable, Sendable {
    case portfolio, transaction, asset
    /// 0.8.3: watchlist items, alert rules, scenarios (their own zone; see IntelSyncEngine).
    case watch, alert, scenario
}

/// One synchronized domain object, as exchanged with the remote store.
/// `payload` is the object's JSON in the same Codable form as the backup format — portable
/// across platforms and migratable via `schemaVersion`. A tombstone has `deletedAt` and no payload.
public struct SyncRecord: Codable, Equatable, Sendable {
    public init(kind: SyncKind, id: String, schemaVersion: Int = SyncRecord.currentSchema, modifiedAt: Date, deletedAt: Date? = nil, deviceID: String, deviceName: String? = nil, payload: Data? = nil, portfolioID: String? = nil, remoteTag: Data? = nil, remoteVersion: String? = nil) { self.kind = kind; self.id = id; self.schemaVersion = schemaVersion; self.modifiedAt = modifiedAt; self.deletedAt = deletedAt; self.deviceID = deviceID; self.deviceName = deviceName; self.payload = payload; self.portfolioID = portfolioID; self.remoteTag = remoteTag; self.remoteVersion = remoteVersion }
    public static let currentSchema = 1

    public var kind: SyncKind
    public var id: String                 // stable identity: portfolio/transaction UUID, asset id — never a display name
    public var schemaVersion: Int = SyncRecord.currentSchema
    public var modifiedAt: Date
    public var deletedAt: Date?
    public var deviceID: String
    public var deviceName: String?
    public var payload: Data?
    public var portfolioID: String?       // transactions only (queries, diagnostics)
    /// Opaque remote metadata (CloudKit system fields) and its version (change tag).
    /// Not part of identity or content.
    public var remoteTag: Data?
    public var remoteVersion: String?

    public var key: String { SyncRecord.key(kind, id) }
    public var isTombstone: Bool { deletedAt != nil }

    public static func key(_ kind: SyncKind, _ id: String) -> String { kind.rawValue + "." + id }
}

public enum SyncMode: String, Codable, Sendable { case localOnly, iCloud }

public enum SyncAccountStatus: Equatable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, notConfigured, unknown
}

/// User-facing sync state. Settings translates it into short PF-style labels.
public enum SyncStatus: Equatable, Sendable {
    case localOnly, checking, syncing, synced, offline, iCloudUnavailable, accountUnavailable
    case conflict(Int)
    case error(String)
}

public enum SyncStoreError: Error, Equatable {
    case offline, notAuthenticated, notConfigured, quotaExceeded, cloudDataDeleted
    case accountChanged
    case unavailable(String)
}

public struct SyncFetchResult: Sendable {
    public init(records: [SyncRecord], token: Data? = nil) { self.records = records; self.token = token }
    public var records: [SyncRecord]
    public var token: Data?
}

public enum SyncSaveOutcome: Sendable {
    case saved(key: String, tag: Data?, version: String?)
    case conflict(key: String, server: SyncRecord)   // server has a newer version than our tag
    /// 0.8.4: the server has no record for the tag sent (CloudKit `unknownItem`): it was never in this zone.
    case missing(key: String)
    /// `kind`: the store's error code for diagnostics (e.g. "ck14"), never a message or an id.
    case failed(key: String, kind: String? = nil)
}

/// The remote side. CloudKit in the app; a deterministic in-memory store in tests.
public protocol SyncRemoteStore: Sendable {
    func accountStatus() async -> SyncAccountStatus
    /// Identifies the signed-in account, to detect an account switch. nil if unknown.
    func accountID() async throws -> String?
    /// Changes since `token` (nil = everything), tombstones included.
    func fetchChanges(since token: Data?) async throws -> SyncFetchResult
    func save(_ records: [SyncRecord]) async throws -> [SyncSaveOutcome]
}

/// Local sync bookkeeping (device-local, never synced).
public struct SyncState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public init(hash: String, modifiedAt: Date, deletedAt: Date? = nil, pending: Bool, tag: Data? = nil, version: String? = nil) { self.hash = hash; self.modifiedAt = modifiedAt; self.deletedAt = deletedAt; self.pending = pending; self.tag = tag; self.version = version }
        public var hash: String            // content fingerprint at last sync / local edit ("" for tombstones)
        public var modifiedAt: Date
        public var deletedAt: Date?
        public var pending: Bool           // local change not yet accepted by the remote store
        public var tag: Data?
        public var version: String?        // remote version this entry is based on
    }

    public var mode: SyncMode = .localOnly
    public var deviceID: String = UUID().uuidString
    public var deviceName: String = ""
    public var accountID: String?
    public var token: Data?
    public var lastSync: Date?
    public var known: [String: Entry] = [:]
    public var conflicts: [SyncConflict] = []
    /// Records from a newer sync schema than this build understands: never applied, never overwritten.
    public var blocked: Set<String> = []
    /// Most recent change received from another device, and when each device last changed
    /// something (status lines only). Optional: older state files decode without them.
    public var lastRemoteChange: SyncDeviceStamp?
    public var devices: [String: Date]?
    /// Set when the local document was found replaced; the next fetch is a full one and merges
    /// iCloud's records back (`adoptCloud`: the local document was empty). Cleared after it.
    public var recovering: Recovery?
    /// CloudKit environment ("Production" / "Development") this state was built against. nil:
    /// written by 0.4–0.5 release builds, i.e. Production. A build signed for another
    /// environment must not sync with this state (its tokens and change tags mean nothing there).
    public var environment: String?
    public static let assumedEnvironment = "Production"
    public func matches(environment env: String) -> Bool { (environment ?? Self.assumedEnvironment) == env }
    public enum Recovery: String, Codable, Sendable { case merge, adoptCloud }

    public init() {}

    public var pendingCount: Int { known.values.filter(\.pending).count }
    public var hasSynced: Bool { !known.isEmpty }
}

/// Which device made a change, and when (by the originating device's clock).
public struct SyncDeviceStamp: Codable, Equatable, Sendable {
    public init(device: String, at: Date) { self.device = device; self.at = at }
    public var device: String
    public var at: Date
}

/// A concurrent edit that could not be merged without losing information. The kept version is
/// applied; the other one is preserved here so the user can restore it.
public struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), key: String, kind: SyncKind, reason: String, other: SyncRecord, detectedAt: Date) {
        self.id = id; self.key = key; self.kind = kind; self.reason = reason; self.other = other; self.detectedAt = detectedAt
    }
    public var id = UUID()
    public var key: String
    public var kind: SyncKind
    public var reason: String
    public var other: SyncRecord          // the version that was not applied
    public var detectedAt: Date
}
