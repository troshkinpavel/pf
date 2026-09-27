import Foundation

// Platform-neutral sync layer (Foundation only). Reused as-is by a future iOS target.
//
// What syncs: durable, user-owned domain records — portfolios, transactions, asset identities.
// What never syncs: market prices and caches, price history, widget snapshots, derived P&L,
// UI state, settings, Keychain secrets. Every device recomputes derived state itself.

enum SyncKind: String, Codable, CaseIterable, Sendable {
    case portfolio, transaction, asset
}

/// One synchronized domain object, as exchanged with the remote store.
/// `payload` is the object's JSON in the same Codable form as the backup format — portable
/// across platforms and migratable via `schemaVersion`. A tombstone has `deletedAt` and no payload.
struct SyncRecord: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var kind: SyncKind
    var id: String                 // stable identity: portfolio/transaction UUID, asset id — never a display name
    var schemaVersion: Int = SyncRecord.currentSchema
    var modifiedAt: Date
    var deletedAt: Date?
    var deviceID: String
    var deviceName: String?
    var payload: Data?
    var portfolioID: String?       // transactions only (queries, diagnostics)
    /// Opaque remote metadata (CloudKit system fields) and its version (change tag).
    /// Not part of identity or content.
    var remoteTag: Data?
    var remoteVersion: String?

    var key: String { SyncRecord.key(kind, id) }
    var isTombstone: Bool { deletedAt != nil }

    static func key(_ kind: SyncKind, _ id: String) -> String { kind.rawValue + "." + id }
}

enum SyncMode: String, Codable, Sendable { case localOnly, iCloud }

enum SyncAccountStatus: Equatable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, notConfigured, unknown
}

/// User-facing sync state. Settings translates it into short PF-style labels.
enum SyncStatus: Equatable, Sendable {
    case localOnly, checking, syncing, synced, offline, iCloudUnavailable, accountUnavailable
    case conflict(Int)
    case error(String)
}

enum SyncStoreError: Error, Equatable {
    case offline, notAuthenticated, notConfigured, quotaExceeded, cloudDataDeleted
    case accountChanged
    case unavailable(String)
}

struct SyncFetchResult: Sendable {
    var records: [SyncRecord]
    var token: Data?
}

enum SyncSaveOutcome: Sendable {
    case saved(key: String, tag: Data?, version: String?)
    case conflict(key: String, server: SyncRecord)   // server has a newer version than our tag
    case failed(key: String)
}

/// The remote side. CloudKit in the app; a deterministic in-memory store in tests.
protocol SyncRemoteStore: Sendable {
    func accountStatus() async -> SyncAccountStatus
    /// Identifies the signed-in account, to detect an account switch. nil if unknown.
    func accountID() async throws -> String?
    /// Changes since `token` (nil = everything), tombstones included.
    func fetchChanges(since token: Data?) async throws -> SyncFetchResult
    func save(_ records: [SyncRecord]) async throws -> [SyncSaveOutcome]
}

/// Local sync bookkeeping (device-local, never synced).
struct SyncState: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var hash: String            // content fingerprint at last sync / local edit ("" for tombstones)
        var modifiedAt: Date
        var deletedAt: Date?
        var pending: Bool           // local change not yet accepted by the remote store
        var tag: Data?
        var version: String?        // remote version this entry is based on
    }

    var mode: SyncMode = .localOnly
    var deviceID: String = UUID().uuidString
    var deviceName: String = ""
    var accountID: String?
    var token: Data?
    var lastSync: Date?
    var known: [String: Entry] = [:]
    var conflicts: [SyncConflict] = []
    /// Records from a newer sync schema than this build understands: never applied, never overwritten.
    var blocked: Set<String> = []

    var pendingCount: Int { known.values.filter(\.pending).count }
    var hasSynced: Bool { !known.isEmpty }
}

/// A concurrent edit that could not be merged without losing information. The kept version is
/// applied; the other one is preserved here so the user can restore it.
struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var key: String
    var kind: SyncKind
    var reason: String
    var other: SyncRecord          // the version that was not applied
    var detectedAt: Date
}
