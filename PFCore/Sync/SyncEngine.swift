import CryptoKit
import Foundation

/// Whoever owns the live document (AppStore on macOS; a mock in tests; a future iOS store).
/// Every pure step runs on the main actor between awaits and always reads the *current*
/// document, so edits made while a network call is in flight are never lost.
@MainActor public protocol SyncHost: AnyObject {
    var syncDocument: PortfolioDocument { get set }
    var syncState: SyncState { get set }
    /// False while the host can't durably write its ledger (protected data unavailable while the
    /// Mac is locked, a failed save waiting to be retried). A pass then stops before anything,
    /// including the change token, moves past what is safely on disk.
    var syncCanPersist: Bool { get }
}

extension SyncHost {
    public var syncCanPersist: Bool { true }
}

/// A pass stopped because the host can't persist right now. Nothing was committed; the same
/// remote changes are fetched again on the next pass.
public struct SyncDeferredError: Error, Equatable {
    public init() {}
}

/// Record-level sync: every portfolio, transaction and asset is its own record keyed by its
/// stable id. Deletions are tombstones. Local edits are detected by content hash against the
/// last synced version and queued (`pending`) until the remote store accepts them — offline
/// edits simply stay queued in `sync-state.json`.
///
/// Conflicts (same record changed on two devices before either synced):
/// - edit vs delete → the edit is kept (no data loss); the delete is kept for review.
/// - edit vs edit   → the newer edit wins; the other version is kept for review.
/// - a local copy never based on any iCloud version (merge, restored backup) vs the record
///   in iCloud → iCloud wins, tombstones included (no resurrection); the local copy is kept for review.
/// - a remote version older than the one held locally (stale) → the local one is kept and re-sent.
/// - assets (identity metadata) → newer wins, no review.
///
/// Safety rules: a local document that shares no portfolio with the synced set was replaced
/// (unreadable file, reset, unrelated import) — its missing records are re-fetched, never
/// tombstoned. An empty or failed fetch never removes local data. Cycles per host are serialized.
public enum SyncEngine {
    // MARK: - local objects

    public struct LocalObject {
        public init(kind: SyncKind, id: String, payload: Data, hash: String, portfolioID: String? = nil) { self.kind = kind; self.id = id; self.payload = payload; self.hash = hash; self.portfolioID = portfolioID }
        public var kind: SyncKind
        public var id: String
        public var payload: Data
        public var hash: String
        public var portfolioID: String?
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func localObjects(_ d: PortfolioDocument) -> [String: LocalObject] {
        var out: [String: LocalObject] = [:]
        out.reserveCapacity(d.transactions.count + d.portfolios.count + d.assets.count)
        func add<T: Encodable & Hashable>(_ kind: SyncKind, _ id: String, _ v: T, pid: String? = nil) {
            // Encoding + hashing every record is the cost of change detection; an unchanged value
            // reuses its last encoding (keyed by the value itself, so any edit misses the cache).
            let key = AnyHashable(v)
            let (data, h): (Data, String)
            if let hit = payloadCache.get(key) { (data, h) = hit } else {
                guard let e = try? encoder.encode(v) else { return }
                (data, h) = (e, hash(e))
                payloadCache.put(key, (e, h))
            }
            out[SyncRecord.key(kind, id)] = LocalObject(kind: kind, id: id, payload: data, hash: h, portfolioID: pid)
        }
        for p in d.portfolios { add(.portfolio, p.id.uuidString, p) }
        for t in d.transactions { add(.transaction, t.id.uuidString, t, pid: t.portfolioID.uuidString) }
        for a in d.assets { add(.asset, a.id, a) }
        return out
    }

    /// ponytail: one process-wide cache, cleared wholesale past `limit` entries; an LRU if ledgers outgrow it.
    final class PayloadCache: @unchecked Sendable {
        private var map: [AnyHashable: (Data, String)] = [:]
        private let lock = NSLock()
        let limit = 60_000
        func get(_ k: AnyHashable) -> (Data, String)? { lock.lock(); defer { lock.unlock() }; return map[k] }
        func put(_ k: AnyHashable, _ v: (Data, String)) { lock.lock(); defer { lock.unlock() }; if map.count >= limit { map.removeAll(keepingCapacity: true) }; map[k] = v }
    }
    static let payloadCache = PayloadCache()

    public static func split(_ key: String) -> (SyncKind, String)? {
        guard let dot = key.firstIndex(of: "."), let k = SyncKind(rawValue: String(key[..<dot])) else { return nil }
        return (k, String(key[key.index(after: dot)...]))
    }

    // MARK: - pure steps

    /// Compare the document with the last known state; queue what changed. Returns the count.
    @discardableResult
    public static func detectLocalChanges(_ doc: PortfolioDocument, _ st: inout SyncState, now: Date) -> Int {
        let local = localObjects(doc)
        if isReplaced(local, st) { rebase(local, &st, emptyLocal: isEmpty(doc)) }
        var n = 0
        for (k, o) in local where !st.blocked.contains(k) {
            let e = st.known[k]
            if let e, e.deletedAt == nil, e.hash == o.hash { continue }
            st.known[k] = .init(hash: o.hash, modifiedAt: stamp(now, after: e), deletedAt: nil, pending: true, tag: e?.tag, version: e?.version)
            n += 1
        }
        // Assets are shared identities and are pruned locally when unused: never tombstoned.
        for (k, e) in st.known where e.deletedAt == nil && local[k] == nil && !k.hasPrefix("asset.") && !st.blocked.contains(k) {
            let t = stamp(now, after: e)
            st.known[k] = .init(hash: "", modifiedAt: t, deletedAt: t, pending: true, tag: e.tag, version: e.version)
            n += 1
        }
        return n
    }

    /// A local change is always newer than the version it was based on, even if this device's
    /// clock is behind the device that wrote that version.
    static func stamp(_ now: Date, after e: SyncState.Entry?) -> Date {
        guard let e, e.version != nil else { return now }
        return max(now, e.modifiedAt.addingTimeInterval(0.001))
    }

    /// Every portfolio this device knows as live in iCloud is missing locally: the document was
    /// replaced (unreadable file set aside, reset, unrelated import), not edited. Users can't
    /// delete their last active portfolio, so normal edits never get here.
    public static func isReplaced(_ local: [String: LocalObject], _ st: SyncState) -> Bool {
        let live = st.known.filter { $0.key.hasPrefix("portfolio.") && $0.value.deletedAt == nil && !st.blocked.contains($0.key) }.keys
        return !live.isEmpty && !live.contains { local[$0] != nil }
    }

    /// Forget (don't tombstone) what the replaced document lacks, and re-fetch everything so
    /// iCloud's records come back into it. Queued deletions made before stay queued.
    static func rebase(_ local: [String: LocalObject], _ st: inout SyncState, emptyLocal: Bool) {
        st.known = st.known.filter { local[$0.key] != nil || ($0.value.pending && $0.value.deletedAt != nil) }
        st.token = nil
        st.recovering = emptyLocal ? .adoptCloud : .merge
    }

    /// The local version of a record (payload or tombstone), as it would be sent.
    public static func record(_ key: String, _ doc: PortfolioDocument, _ st: SyncState, local: [String: LocalObject]? = nil) -> SyncRecord? {
        guard let (kind, id) = split(key), let e = st.known[key] else { return nil }
        let o = (local ?? localObjects(doc))[key]
        return SyncRecord(kind: kind, id: id, modifiedAt: e.modifiedAt, deletedAt: o == nil ? (e.deletedAt ?? e.modifiedAt) : nil,
                          deviceID: st.deviceID, deviceName: st.deviceName, payload: o?.payload,
                          portfolioID: o?.portfolioID, remoteTag: e.tag, remoteVersion: e.version)
    }

    public static func pendingRecords(_ doc: PortfolioDocument, _ st: SyncState) -> [SyncRecord] {
        let local = localObjects(doc)
        return st.known.filter { $0.value.pending && !st.blocked.contains($0.key) }.keys.sorted()
            .compactMap { record($0, doc, st, local: local) }
    }

    /// Apply fetched records. Local pending changes are resolved per the rules above.
    public static func applyRemote(_ records: [SyncRecord], _ doc: inout PortfolioDocument, _ st: inout SyncState, now: Date) {
        noteDevices(records, &st)
        for r in records {
            let k = r.key
            if r.schemaVersion > SyncRecord.currentSchema { st.blocked.insert(k); continue }
            let rh = r.isTombstone ? "" : hash(r.payload ?? Data())
            let e = st.known[k]
            // Our own write echoed back, or a version we already hold.
            if let e, let v = r.remoteVersion, v == e.version { continue }
            let accepted = SyncState.Entry(hash: rh, modifiedAt: r.modifiedAt, deletedAt: r.deletedAt, pending: false, tag: r.remoteTag, version: r.remoteVersion)
            let from = r.deviceName.map { $0.isEmpty ? "another device" : $0 } ?? "another device"

            guard let e, e.pending || r.modifiedAt < e.modifiedAt else {
                if apply(r, &doc) { st.known[k] = accepted; st.blocked.remove(k) } else { st.blocked.insert(k) }
                continue
            }
            if e.hash == rh { st.known[k] = accepted; continue }   // same content on both sides

            // Concurrent change: decide which version stays, keep the other for review.
            let mine = record(k, doc, st)
            let keepMine: Bool
            let reason: String
            if !e.pending {
                // Older than what this device already holds: stale. Keep ours and send it again.
                keepMine = true
                reason = "older version from \(from) · kept the newer one here"
                st.known[k]?.pending = true
            } else if e.version == nil {
                // Never based on iCloud's copy (merge, restored backup): iCloud's version stands.
                keepMine = false
                reason = r.isTombstone ? "deleted on \(from) · older copy here · kept the delete" : "older copy here · kept the iCloud version"
            } else {
                switch (e.deletedAt != nil, r.isTombstone) {
                case (false, true):  keepMine = true;  reason = "deleted on \(from) · edited here · kept the edit"
                case (true, false):  keepMine = false; reason = "deleted here · edited on \(from) · kept the edit"
                default:
                    keepMine = e.modifiedAt >= r.modifiedAt
                    reason = "edited here and on \(from) · kept the \(keepMine ? "local" : "\(from)") version"
                }
            }
            if keepMine {
                st.known[k]?.tag = r.remoteTag           // rebase: next save overwrites the server version
                st.known[k]?.version = r.remoteVersion
                st.known[k]?.modifiedAt = max(e.modifiedAt, r.modifiedAt.addingTimeInterval(0.001))
                if r.kind != .asset { addConflict(&st, key: k, kind: r.kind, reason: reason, other: r, now: now) }
            } else {
                guard apply(r, &doc) else { st.blocked.insert(k); continue }
                st.known[k] = accepted
                if r.kind != .asset, let mine { addConflict(&st, key: k, kind: r.kind, reason: reason, other: mine, now: now) }
            }
        }
    }

    /// Remembers which other devices changed data, for "last change · MacBook Pro · 2m ago".
    public static func noteDevices(_ records: [SyncRecord], _ st: inout SyncState) {
        for r in records where r.deviceID != st.deviceID {
            let name = (r.deviceName ?? "").isEmpty ? "another device" : r.deviceName!
            var d = st.devices ?? [:]
            if (d[name] ?? .distantPast) < r.modifiedAt { d[name] = r.modifiedAt }
            st.devices = d
            if (st.lastRemoteChange?.at ?? .distantPast) < r.modifiedAt { st.lastRemoteChange = SyncDeviceStamp(device: name, at: r.modifiedAt) }
        }
    }

    private static func addConflict(_ st: inout SyncState, key: String, kind: SyncKind, reason: String, other: SyncRecord, now: Date) {
        var o = other
        o.remoteTag = nil
        st.conflicts.removeAll { $0.key == key }
        st.conflicts.append(SyncConflict(key: key, kind: kind, reason: reason, other: o, detectedAt: now))
    }

    /// Upsert or remove one record in the document. False if the payload can't be decoded.
    @discardableResult
    public static func apply(_ r: SyncRecord, _ doc: inout PortfolioDocument) -> Bool {
        let dec = PortfolioDocument.decoder
        switch r.kind {
        case .portfolio:
            guard let id = UUID(uuidString: r.id) else { return false }
            if r.isTombstone { doc.portfolios.removeAll { $0.id == id }; return true }
            guard let p = try? dec.decode(PortfolioInfo.self, from: r.payload ?? Data()), p.id == id else { return false }
            if let i = doc.portfolios.firstIndex(where: { $0.id == id }) { doc.portfolios[i] = p } else { doc.portfolios.append(p) }
        case .transaction:
            guard let id = UUID(uuidString: r.id) else { return false }
            if r.isTombstone { doc.transactions.removeAll { $0.id == id }; return true }
            guard let t = try? dec.decode(Transaction.self, from: r.payload ?? Data()), t.id == id else { return false }
            if let i = doc.transactions.firstIndex(where: { $0.id == id }) { doc.transactions[i] = t } else { doc.transactions.append(t) }
        case .asset:
            if r.isTombstone { return true }
            guard let a = try? dec.decode(Asset.self, from: r.payload ?? Data()), a.id == r.id else { return false }
            if let i = doc.assets.firstIndex(where: { $0.id == a.id }) { doc.assets[i] = a } else { doc.assets.append(a) }
        case .watch, .alert, .scenario:
            return false   // intel records live in their own zone (IntelSyncEngine); never in the ledger
        }
        return true
    }

    /// Restore document invariants after a merge. Deterministic, so two devices normalizing
    /// the same data produce the same records.
    public static func normalize(_ doc: inout PortfolioDocument, _ st: SyncState, now: Date) {
        // A transaction whose portfolio was deleted elsewhere: keep it in a recovered portfolio.
        let pids = Set(doc.portfolios.map(\.id))
        let orphaned = Set(doc.transactions.map(\.portfolioID)).subtracting(pids)
            .filter { st.known[SyncRecord.key(.portfolio, $0.uuidString)]?.deletedAt != nil }
        for id in orphaned.sorted(by: { $0.uuidString < $1.uuidString }) {
            doc.portfolios.append(PortfolioInfo(id: id, name: "RECOVERED", glyph: PortfolioGlyphs.newDefault, createdAt: PortfolioInfo.stamp(now)))
        }
        // Same name created on two devices: the later one gets a suffix.
        let order = doc.portfolios.indices.sorted {
            (doc.portfolios[$0].createdAt, doc.portfolios[$0].id.uuidString) < (doc.portfolios[$1].createdAt, doc.portfolios[$1].id.uuidString)
        }
        var used = Set<String>()
        for i in order {
            var name = doc.portfolios[i].name, n = 2
            while used.contains(name) { name = "\(doc.portfolios[i].name) \(n)"; n += 1 }
            doc.portfolios[i].name = name
            used.insert(name)
        }
    }

    public static func applySaveOutcomes(sent: [SyncRecord], _ outcomes: [SyncSaveOutcome], _ doc: inout PortfolioDocument, _ st: inout SyncState, now: Date) {
        let sentHash = Dictionary(sent.map { ($0.key, $0.isTombstone ? "" : hash($0.payload ?? Data())) }, uniquingKeysWith: { a, _ in a })
        var conflicts: [SyncRecord] = []
        for o in outcomes {
            switch o {
            case let .saved(k, tag, version):
                guard st.known[k] != nil else { continue }
                st.known[k]?.tag = tag
                st.known[k]?.version = version
                if st.known[k]?.hash == sentHash[k] { st.known[k]?.pending = false }   // unless edited again meanwhile
            case let .conflict(_, server):
                conflicts.append(server)
            case .failed:
                break   // stays queued
            }
        }
        if !conflicts.isEmpty { applyRemote(conflicts, &doc, &st, now: now) }
    }

    // MARK: - cycle

    /// One full sync: fetch → merge → push, retrying server conflicts. Throws on account
    /// or network problems; local pending changes stay queued either way.
    ///
    /// Cycles for the same host never overlap: a second call waits for the running one. A cycle
    /// stops without writing anything if it is cancelled or sync is turned off meanwhile.
    @MainActor
    public static func cycle(_ host: SyncHost, remote: SyncRemoteStore, now: @escaping () -> Date = Date.init) async throws {
        let id = ObjectIdentifier(host)
        let previous = running[id]
        let task = Task { @MainActor in
            _ = await previous?.result
            try await runCycle(host, remote: remote, now: now)
        }
        running[id] = task
        defer { if running[id] == task { running[id] = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    @MainActor private static var running: [ObjectIdentifier: Task<Void, Error>] = [:]

    @MainActor
    private static func runCycle(_ host: SyncHost, remote: SyncRemoteStore, now: @escaping () -> Date) async throws {
        try stillActive(host)
        guard host.syncCanPersist else { throw SyncDeferredError() }
        // Replaced document noticed before the fetch, so the fetch is the full one.
        detectLocalChanges(host.syncDocument, &host.syncState, now: now())
        try await checkAccount(host, remote)
        try stillActive(host)
        let fetched = try await remote.fetchChanges(since: host.syncState.token)
        try stillActive(host)
        var doc = host.syncDocument, st = host.syncState
        detectLocalChanges(doc, &st, now: now())
        applyRemote(fetched.records, &doc, &st, now: now())
        if st.recovering == .adoptCloud { dropPlaceholders(&doc, &st) }
        st.recovering = nil
        normalize(&doc, st, now: now())
        detectLocalChanges(doc, &st, now: now())
        st.token = fetched.token
        try commit(host, doc, st)

        for _ in 0..<3 {
            let sent = pendingRecords(host.syncDocument, host.syncState)
            if sent.isEmpty { break }
            let outcomes = try await remote.save(sent)
            try stillActive(host)
            doc = host.syncDocument; st = host.syncState
            detectLocalChanges(doc, &st, now: now())
            applySaveOutcomes(sent: sent, outcomes, &doc, &st, now: now())
            normalize(&doc, st, now: now())
            detectLocalChanges(doc, &st, now: now())
            try commit(host, doc, st)
            if !outcomes.contains(where: { if case .conflict = $0 { true } else { false } }) { break }
        }
        host.syncState.lastSync = now()
    }

    @MainActor
    private static func stillActive(_ host: SyncHost) throws {
        try Task.checkCancellation()
        guard host.syncState.mode == .iCloud else { throw CancellationError() }
    }

    /// The local document was empty when it was replaced (e.g. a fresh MAIN after an unreadable
    /// file): once iCloud's portfolios are back, its never-synced empty portfolio is dropped.
    static func dropPlaceholders(_ doc: inout PortfolioDocument, _ st: inout SyncState) {
        let used = Set(doc.transactions.map(\.portfolioID))
        let drop = Set(doc.portfolios.map(\.id).filter { id in
            guard let e = st.known[SyncRecord.key(.portfolio, id.uuidString)] else { return false }
            return e.pending && e.version == nil && !used.contains(id)
        })
        guard !drop.isEmpty, doc.portfolios.count > drop.count else { return }
        for id in drop { st.known[SyncRecord.key(.portfolio, id.uuidString)] = nil }
        doc.portfolios.removeAll { drop.contains($0.id) }
    }

    @MainActor
    private static func commit(_ host: SyncHost, _ doc: PortfolioDocument, _ st: SyncState) throws {
        if doc != host.syncDocument {
            let before = host.syncDocument
            host.syncDocument = doc
            // The ledger write failed (e.g. locked Mac): put the on-disk version back and keep the
            // old bookkeeping, so the token never moves past data that isn't persisted.
            guard host.syncCanPersist else {
                host.syncDocument = before
                throw SyncDeferredError()
            }
        }
        host.syncState = st
    }

    @MainActor
    private static func checkAccount(_ host: SyncHost, _ remote: SyncRemoteStore) async throws {
        switch await remote.accountStatus() {
        case .available: break
        case .notConfigured: throw SyncStoreError.notConfigured
        case .temporarilyUnavailable: throw SyncStoreError.offline
        default: throw SyncStoreError.notAuthenticated
        }
        let id = try await remote.accountID()
        if let id, let known = host.syncState.accountID, id != known { throw SyncStoreError.accountChanged }
        if host.syncState.accountID == nil { host.syncState.accountID = id }
    }

    // MARK: - enabling

    public enum Plan: Equatable, Sendable {
        case upload        // iCloud is empty: upload this Mac's data
        case useCloud      // this Mac is empty: download iCloud's data
        case choose        // both have data: MERGE or USE ICLOUD (or cancel)
        case resume        // both hold the same records already
    }

    public enum Choice: Sendable { case upload, useCloud, merge }

    public struct Inspection: Equatable, Sendable {
        public init(plan: Plan, localPortfolios: Int = 0, localTransactions: Int = 0, cloudPortfolios: Int = 0, cloudTransactions: Int = 0,
                    cloudDevices: [String] = [], cloudDocument: PortfolioDocument? = nil, lastChange: SyncDeviceStamp? = nil) {
            self.plan = plan; self.localPortfolios = localPortfolios; self.localTransactions = localTransactions
            self.cloudPortfolios = cloudPortfolios; self.cloudTransactions = cloudTransactions; self.cloudDevices = cloudDevices
            self.cloudDocument = cloudDocument; self.lastChange = lastChange
        }
        public var plan: Plan
        public var localPortfolios = 0, localTransactions = 0
        public var cloudPortfolios = 0, cloudTransactions = 0
        public var cloudDevices: [String] = []
        /// What iCloud holds, decoded for display only (nothing is applied by `inspect`).
        public var cloudDocument: PortfolioDocument?
        public var lastChange: SyncDeviceStamp?
    }

    public static func isEmpty(_ d: PortfolioDocument) -> Bool {
        d.transactions.isEmpty && d.portfolios.count <= 1
    }

    /// Read-only look at both sides before anything is uploaded or replaced.
    @MainActor
    public static func inspect(_ host: SyncHost, remote: SyncRemoteStore) async throws -> Inspection {
        var probe = host.syncState
        probe.accountID = nil
        let tmp = ProbeHost(doc: host.syncDocument, state: probe)
        try await checkAccount(tmp, remote)
        let all = try await remote.fetchChanges(since: nil).records.filter { !$0.isTombstone && $0.schemaVersion <= SyncRecord.currentSchema }
        let doc = host.syncDocument
        var i = Inspection(plan: .upload,
                           localPortfolios: doc.portfolios.count, localTransactions: doc.transactions.count,
                           cloudPortfolios: all.filter { $0.kind == .portfolio }.count,
                           cloudTransactions: all.filter { $0.kind == .transaction }.count,
                           cloudDevices: Array(Set(all.compactMap(\.deviceName).filter { !$0.isEmpty })).sorted())
        let cloudEmpty = i.cloudPortfolios == 0 && i.cloudTransactions == 0
        let local = localObjects(doc).filter { $0.value.kind != .asset }.mapValues(\.hash)
        let cloud = Dictionary(all.filter { $0.kind != .asset }.map { ($0.key, hash($0.payload ?? Data())) }, uniquingKeysWith: { a, _ in a })
        var preview = PortfolioDocument(portfolios: [])
        var scratch = SyncState()
        scratch.deviceID = host.syncState.deviceID
        applyRemote(all, &preview, &scratch, now: Date())
        i.cloudDocument = preview
        i.lastChange = all.max { $0.modifiedAt < $1.modifiedAt }.map {
            SyncDeviceStamp(device: ($0.deviceName ?? "").isEmpty ? "another device" : $0.deviceName!, at: $0.modifiedAt)
        }
        if cloudEmpty { i.plan = .upload }
        else if local == cloud { i.plan = .resume }
        else if isEmpty(doc) { i.plan = .useCloud }
        else { i.plan = .choose }
        return i
    }

    /// Turn sync on. `useCloud` replaces the local document with iCloud's (the caller backs
    /// the local file up first); `upload` and `merge` both union by record id: local records
    /// are queued, remote ones applied; where both hold the same id with different content,
    /// iCloud's version stands and the local copy is kept for review.
    @MainActor
    public static func enable(_ host: SyncHost, remote: SyncRemoteStore, choice: Choice, deviceName: String,
                       now: @escaping () -> Date = Date.init) async throws {
        guard host.syncCanPersist else { throw SyncDeferredError() }
        var st = SyncState()
        st.mode = .iCloud
        st.deviceID = host.syncState.deviceID
        st.deviceName = deviceName
        if choice == .useCloud {
            // Fetch everything first: the local document is replaced only once iCloud's data is in hand.
            let all = try await remote.fetchChanges(since: nil)
            var d = PortfolioDocument(portfolios: [])
            d.settings = host.syncDocument.settings
            applyRemote(all.records, &d, &st, now: now())
            normalize(&d, st, now: now())
            guard !d.portfolios.isEmpty else { throw SyncStoreError.unavailable("iCloud has no portfolios") }
            st.token = all.token
            // Document first, then the state carrying the token: never a token ahead of the disk.
            let before = host.syncDocument
            host.syncDocument = d
            guard host.syncCanPersist else { host.syncDocument = before; throw SyncDeferredError() }
            host.syncState = st
        } else {
            host.syncState = st
        }
        try await cycle(host, remote: remote, now: now)
    }

    /// Turn sync off. Local data is untouched; iCloud data is left as is.
    @MainActor
    public static func disable(_ host: SyncHost) {
        var st = SyncState()
        st.deviceID = host.syncState.deviceID
        st.deviceName = host.syncState.deviceName
        host.syncState = st
    }

    /// Apply the version kept aside in a conflict instead of the current one.
    public static func restore(_ c: SyncConflict, _ doc: inout PortfolioDocument, _ st: inout SyncState) {
        var r = c.other
        if r.isTombstone { r.payload = nil }
        apply(r, &doc)
        if r.kind == .portfolio, r.isTombstone, let id = UUID(uuidString: r.id) { doc.transactions.removeAll { $0.portfolioID == id } }
        st.conflicts.removeAll { $0.id == c.id }
    }
}

@MainActor
private final class ProbeHost: SyncHost {
    public var syncDocument: PortfolioDocument
    public var syncState: SyncState
    public init(doc: PortfolioDocument, state: SyncState) { syncDocument = doc; syncState = state }
}
