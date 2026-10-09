import CloudKit
import Foundation

/// `SyncRemoteStore` backed by the user's CloudKit **private** database, in a custom zone
/// (custom zones support change tokens and atomic per-zone changes). One CKRecord per
/// SyncRecord; the record name is the sync key. The JSON payload is stored in an
/// `encryptedValues` field. Nothing is ever written to the public database.
///
/// Only construct this when the app is signed with the iCloud entitlement — CKContainer
/// traps without it. The app checks that first (see AppStore+Sync).
public final class CloudKitSyncStore: SyncRemoteStore, @unchecked Sendable {
    public static let recordType = "PFRecord"
    public static let zoneName = "PFZone"
    public let zoneID: CKRecordZone.ID

    private let container: CKContainer
    private var db: CKDatabase { container.privateCloudDatabase }

    /// `zoneName` is overridable only for the DEBUG CloudKit self-test, which uses its own zone.
    public init(containerIdentifier: String, zoneName: String = CloudKitSyncStore.zoneName) {
        container = CKContainer(identifier: containerIdentifier)
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Removes this store's zone and everything in it (DEBUG self-test cleanup).
    public func deleteZone() async throws {
        _ = try await db.modifyRecordZones(saving: [], deleting: [zoneID])
        zoneReady = false
    }

    public func accountStatus() async -> SyncAccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .unknown
            @unknown default: return .unknown
            }
        } catch {
            return Self.map(error) == .notConfigured ? .notConfigured : .unknown
        }
    }

    public func accountID() async throws -> String? {
        do { return try await container.userRecordID().recordName }
        catch { throw Self.map(error) }
    }

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        var serverToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        var out: [SyncRecord] = []
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
            } catch let e as CKError where e.code == .zoneNotFound {
                // Synced before, now the zone is gone: stop instead of re-uploading or treating
                // iCloud as empty. Never synced: first use, create the zone.
                if token != nil { throw SyncStoreError.cloudDataDeleted }
                try await ensureZone()
                return SyncFetchResult(records: [], token: nil)
            } catch let e as CKError where e.code == .userDeletedZone {
                throw SyncStoreError.cloudDataDeleted
            } catch let e as CKError where e.code == .changeTokenExpired {
                serverToken = nil
                out = []
                continue
            } catch { throw Self.map(error) }
            for (_, r) in changes.modificationResultsByID {
                if case let .success(m) = r, let rec = Self.record(m.record) { out.append(rec) }
            }
            serverToken = changes.changeToken
            if !changes.moreComing { break }
        }
        let t = serverToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return SyncFetchResult(records: out, token: t)
    }

    public func save(_ records: [SyncRecord]) async throws -> [SyncSaveOutcome] {
        try await ensureZone()
        var out: [SyncSaveOutcome] = []
        for chunk in stride(from: 0, to: records.count, by: 300).map({ Array(records[$0..<min($0 + 300, records.count)]) }) {
            let results: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                results = try await db.modifyRecords(saving: chunk.map(ckRecord), deleting: [],
                                                     savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults
            } catch { throw Self.map(error) }
            for (id, r) in results {
                let key = id.recordName
                switch r {
                case let .success(rec):
                    out.append(.saved(key: key, tag: Self.systemFields(rec), version: rec.recordChangeTag))
                case let .failure(e as CKError) where e.code == .serverRecordChanged:
                    if let server = e.serverRecord.flatMap(Self.record) { out.append(.conflict(key: key, server: server)) }
                    else { out.append(.failed(key: key, kind: "ck\(e.code.rawValue)-noServerRecord")) }
                case let .failure(e as CKError) where e.code == .unknownItem:
                    out.append(.missing(key: key))
                case let .failure(e):
                    let m = Self.map(e)
                    if m == .offline || m == .notAuthenticated || m == .quotaExceeded { throw m }
                    out.append(.failed(key: key, kind: (e as? CKError).map { "ck\($0.code.rawValue)" } ?? "other"))
                }
            }
        }
        return out
    }

    private var zoneReady = false
    private func ensureZone() async throws {
        guard !zoneReady else { return }
        do { _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }
        catch { throw Self.map(error) }
        zoneReady = true
    }

    // MARK: mapping

    public func ckRecord(_ r: SyncRecord) -> CKRecord { Self.ckRecord(r, zoneID: zoneID) }

    /// SyncRecord → CKRecord. Static (no container) so both platforms' tests can check the
    /// exact field mapping without iCloud.
    public static func ckRecord(_ r: SyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let rec: CKRecord
        if let tag = r.remoteTag, let coder = try? NSKeyedUnarchiver(forReadingFrom: tag) {
            coder.requiresSecureCoding = true
            rec = CKRecord(coder: coder) ?? CKRecord(recordType: Self.recordType, recordID: .init(recordName: r.key, zoneID: zoneID))
            coder.finishDecoding()
        } else {
            rec = CKRecord(recordType: Self.recordType, recordID: .init(recordName: r.key, zoneID: zoneID))
        }
        rec["kind"] = r.kind.rawValue
        rec["id"] = r.id
        rec["schemaVersion"] = r.schemaVersion
        rec["modifiedAt"] = r.modifiedAt
        rec["deletedAt"] = r.deletedAt
        rec["deviceID"] = r.deviceID
        rec["deviceName"] = r.deviceName
        rec["portfolioID"] = r.portfolioID
        rec.encryptedValues["payload"] = r.payload
        return rec
    }

    public static func record(_ c: CKRecord) -> SyncRecord? {
        guard let k = (c["kind"] as? String).flatMap(SyncKind.init), let id = c["id"] as? String,
              let mod = c["modifiedAt"] as? Date else { return nil }
        return SyncRecord(kind: k, id: id, schemaVersion: c["schemaVersion"] as? Int ?? 1, modifiedAt: mod,
                          deletedAt: c["deletedAt"] as? Date, deviceID: c["deviceID"] as? String ?? "",
                          deviceName: c["deviceName"] as? String, payload: c.encryptedValues["payload"] as? Data,
                          portfolioID: c["portfolioID"] as? String, remoteTag: systemFields(c), remoteVersion: c.recordChangeTag)
    }

    public static func systemFields(_ c: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        c.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func map(_ error: Error) -> SyncStoreError {
        guard let e = error as? CKError else { return .unavailable(error.localizedDescription) }
        switch e.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy: return .offline
        case .notAuthenticated, .accountTemporarilyUnavailable: return .notAuthenticated
        case .quotaExceeded: return .quotaExceeded
        case .badContainer, .missingEntitlement, .permissionFailure: return .notConfigured
        case .userDeletedZone: return .cloudDataDeleted
        default: return .unavailable(e.localizedDescription)
        }
    }
}
