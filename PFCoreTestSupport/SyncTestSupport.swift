import Foundation
import PFCore

// Test support shared by every client of PFCore (the macOS tests, the PFCore package tests
// and the iPhone app's tests): an in-memory CloudKit stand-in and a minimal sync host.
// Never touches real iCloud.

/// In-memory stand-in for the CloudKit private zone: versions per record (like change tags),
/// a change log for tokens, `ifServerRecordUnchanged` save semantics.
public actor MockRemote: SyncRemoteStore {
    public init() {}
    public private(set) var records: [String: SyncRecord] = [:]
    private var log: [String] = []          // keys in change order; token = log position
    public var offline = false
    public var account: SyncAccountStatus = .available
    public var userID = "user-1"
    public private(set) var saveCalls = 0
    /// Saves reach the store but the reply is lost (connection dropped mid-push).
    public var loseSaveReplies = false
    /// Delays fetches, to overlap sync passes in tests.
    public var fetchDelay: UInt64 = 0
    public private(set) var fetchCalls = 0, maxConcurrentFetches = 0
    private var fetching = 0

    public func setOffline(_ v: Bool) { offline = v }
    public func setLoseSaveReplies(_ v: Bool) { loseSaveReplies = v }
    public func setFetchDelay(_ ns: UInt64) { fetchDelay = ns }
    public func setUser(_ id: String) { userID = id }
    public func setAccount(_ a: SyncAccountStatus) { account = a }
    public func inject(_ r: SyncRecord) { var r = r; r.remoteVersion = "x\(log.count)"; records[r.key] = r; log.append(r.key) }

    public func accountStatus() async -> SyncAccountStatus { account }
    public func accountID() async throws -> String? { if offline { throw SyncStoreError.offline }; return userID }

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        if offline { throw SyncStoreError.offline }
        fetchCalls += 1; fetching += 1; maxConcurrentFetches = max(maxConcurrentFetches, fetching)
        defer { fetching -= 1 }
        if fetchDelay > 0 { try? await Task.sleep(nanoseconds: fetchDelay) }
        if offline { throw SyncStoreError.offline }
        let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let keys = Array(Set(log[min(from, log.count)...]))
        return SyncFetchResult(records: keys.compactMap { records[$0] }, token: Data("\(log.count)".utf8))
    }

    public func save(_ rs: [SyncRecord]) async throws -> [SyncSaveOutcome] {
        if offline { throw SyncStoreError.offline }
        saveCalls += 1
        let out: [SyncSaveOutcome] = rs.map { r in
            if let cur = records[r.key], cur.remoteVersion != r.remoteVersion { return .conflict(key: r.key, server: cur) }
            var s = r
            s.remoteVersion = "v\(log.count + 1)"
            s.remoteTag = Data(s.remoteVersion!.utf8)
            records[r.key] = s
            log.append(r.key)
            return .saved(key: r.key, tag: s.remoteTag, version: s.remoteVersion)
        }
        if loseSaveReplies { throw SyncStoreError.offline }
        return out
    }

    public var liveCount: (portfolios: Int, transactions: Int) {
        let live = records.values.filter { !$0.isTombstone }
        return (live.filter { $0.kind == .portfolio }.count, live.filter { $0.kind == .transaction }.count)
    }
}

@MainActor
public final class Device: SyncHost {
    public var syncDocument: PortfolioDocument
    public var syncState = SyncState()
    public let name: String
    public var clock: Date
    public init(_ name: String, _ doc: PortfolioDocument = .fresh(), clock: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.name = name; syncDocument = doc; self.clock = clock
    }
    public var doc: PortfolioDocument { get { syncDocument } set { syncDocument = newValue } }
    public func tick(_ s: TimeInterval = 10) { clock += s }
    public func sync(_ r: MockRemote) async throws { try await SyncEngine.cycle(self, remote: r, now: { [unowned self] in self.clock }) }
    public func enable(_ r: MockRemote, _ c: SyncEngine.Choice) async throws {
        try await SyncEngine.enable(self, remote: r, choice: c, deviceName: name, now: { [unowned self] in self.clock })
    }
}

/// 0.9: a Mac's watchlist / alerts / scenarios, synced through `IntelSyncEngine`.
@MainActor
public final class IntelDevice: IntelSyncHost {
    public var intelSyncDocument: IntelDocument
    public var intelSyncState = SyncState()
    public var intelSyncCanPersist = true
    public var clock: Date
    public init(_ name: String, _ doc: IntelDocument = IntelDocument(), clock: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        intelSyncDocument = doc; self.clock = clock
        intelSyncState.mode = .iCloud; intelSyncState.deviceName = name
    }
    public var doc: IntelDocument { get { intelSyncDocument } set { intelSyncDocument = newValue } }
    public func tick(_ s: TimeInterval = 10) { clock += s }
    public func sync(_ r: MockRemote) async throws { try await IntelSyncEngine.cycle(self, remote: r, now: { [unowned self] in self.clock }) }
}
