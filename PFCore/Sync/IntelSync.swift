import Foundation

/// Whoever owns the live watchlist / alerts / scenarios (AppStore on macOS; a mock in tests).
@MainActor public protocol IntelSyncHost: AnyObject {
    var intelSyncDocument: IntelDocument { get set }
    var intelSyncState: SyncState { get set }
    /// False while intel.json can't be read or written (locked, newer schema): a pass stops first.
    var intelSyncCanPersist: Bool { get }
}

/// 0.9: the watchlist, alert rules and scenarios in iCloud. Same record format and rules as the
/// ledger (`SyncEngine`), in their own CloudKit zone (`PFIntelZone`, same `PFRecord` type: no
/// schema change) with their own state file, so clients before 0.9 never see these records and a
/// downgrade never meets an intel conflict in `sync-state.json`. The alert log never syncs;
/// automation rules never sync.
///
/// Conflicts are whole-record and held: until the user picks a side, this Mac keeps (and
/// evaluates) its own version and doesn't send it; no fields are merged. Exceptions:
/// - an alert whose definitions match and only its state (fired / armed / seen / paused) differs → newer wins, silently;
/// - edit vs delete → the edit is kept (no data loss);
/// - a remote version older than the one held here → ours is kept and re-sent.
public enum IntelSyncEngine {
    public static let zoneName = "PFIntelZone"
    public static let kinds: Set<SyncKind> = [.watch, .alert, .scenario]

    public static func localObjects(_ d: IntelDocument) -> [String: SyncEngine.LocalObject] {
        var out: [String: SyncEngine.LocalObject] = [:]
        func add<T: Encodable>(_ kind: SyncKind, _ id: UUID, _ v: T) {
            guard let e = try? SyncEngine.encoder.encode(v) else { return }
            out[SyncRecord.key(kind, id.uuidString)] = .init(kind: kind, id: id.uuidString, payload: e, hash: SyncEngine.hash(e))
        }
        for w in d.watchlist { add(.watch, w.id, w) }
        for a in d.alerts { add(.alert, a.id, a) }
        for s in d.scenarios { add(.scenario, s.id, s) }
        return out
    }

    // MARK: - pure steps

    /// Diffs the document against the last synced state. A record that is gone is a deletion
    /// (a tombstone is queued), so an empty watchlist, alert list or scenario list is an intentional
    /// delete-all and propagates. Hence the host's duty: never hand over a placeholder (locked,
    /// unreadable, newer file → `intelSyncCanPersist` false), and call `rebase` for a domain whose
    /// file was set aside or went missing, before the next pass.
    @discardableResult
    public static func detectLocalChanges(_ doc: IntelDocument, _ st: inout SyncState, now: Date) -> Int {
        let local = localObjects(doc)
        var n = 0
        for (k, o) in local where !st.blocked.contains(k) {
            let e = st.known[k]
            if let e, e.deletedAt == nil, e.hash == o.hash { continue }
            st.known[k] = .init(hash: o.hash, modifiedAt: SyncEngine.stamp(now, after: e), deletedAt: nil, pending: true, tag: e?.tag, version: e?.version)
            n += 1
        }
        for (k, e) in st.known where e.deletedAt == nil && local[k] == nil && !st.blocked.contains(k) {
            let t = SyncEngine.stamp(now, after: e)
            st.known[k] = .init(hash: "", modifiedAt: t, deletedAt: t, pending: true, tag: e.tag, version: e.version)
            n += 1
        }
        return n
    }

    /// The local data of these kinds was replaced, not edited (its file was unreadable and set
    /// aside, or is missing): forget what was synced for them instead of tombstoning it, and fetch
    /// everything again so iCloud's records come back. Deletions queued before stay queued.
    public static func rebase(_ st: inout SyncState, kinds: Set<SyncKind>) {
        st.known = st.known.filter { k, e in
            guard let kind = SyncEngine.split(k)?.0, kinds.contains(kind) else { return true }
            return e.pending && e.deletedAt != nil
        }
        st.conflicts.removeAll { kinds.contains($0.kind) }
        st.token = nil
    }

    /// Kinds with live records this state knows from iCloud.
    public static func knownLiveKinds(_ st: SyncState) -> Set<SyncKind> {
        Set(st.known.filter { $0.value.deletedAt == nil }.keys.compactMap { SyncEngine.split($0)?.0 })
    }

    public static func record(_ key: String, _ doc: IntelDocument, _ st: SyncState, local: [String: SyncEngine.LocalObject]? = nil) -> SyncRecord? {
        guard let (kind, id) = SyncEngine.split(key), let e = st.known[key] else { return nil }
        let o = (local ?? localObjects(doc))[key]
        return SyncRecord(kind: kind, id: id, modifiedAt: e.modifiedAt, deletedAt: o == nil ? (e.deletedAt ?? e.modifiedAt) : nil,
                          deviceID: st.deviceID, deviceName: st.deviceName, payload: o?.payload, remoteTag: e.tag, remoteVersion: e.version)
    }

    /// Queued changes, except records held in a conflict (sent once the user picks a side).
    public static func pendingRecords(_ doc: IntelDocument, _ st: SyncState) -> [SyncRecord] {
        let local = localObjects(doc), held = Set(st.conflicts.map(\.key))
        return st.known.filter { $0.value.pending && !st.blocked.contains($0.key) && !held.contains($0.key) }.keys.sorted()
            .compactMap { record($0, doc, st, local: local) }
    }

    /// An alert's definition: what it watches and how. State (fired, seen, paused) and the
    /// display number are not part of it.
    static func definition(_ payload: Data?) -> AlertRule? {
        guard let p = payload, var r = try? PortfolioDocument.decoder.decode(AlertRule.self, from: p) else { return nil }
        r.state = .armed; r.firedAt = nil; r.unseen = false; r.paused = false; r.number = 0
        return r
    }

    public static func applyRemote(_ records: [SyncRecord], _ doc: inout IntelDocument, _ st: inout SyncState, now: Date) {
        SyncEngine.noteDevices(records, &st)
        for r in records where kinds.contains(r.kind) {
            let k = r.key
            if r.schemaVersion > SyncRecord.currentSchema { st.blocked.insert(k); continue }
            let rh = r.isTombstone ? "" : SyncEngine.hash(r.payload ?? Data())
            let e = st.known[k]
            if let e, let v = r.remoteVersion, v == e.version { continue }
            let accepted = SyncState.Entry(hash: rh, modifiedAt: r.modifiedAt, deletedAt: r.deletedAt, pending: false, tag: r.remoteTag, version: r.remoteVersion)
            guard let e, e.pending || r.modifiedAt < e.modifiedAt else {
                if apply(r, &doc) { st.known[k] = accepted; st.blocked.remove(k); st.conflicts.removeAll { $0.key == k } } else { st.blocked.insert(k) }
                continue
            }
            if e.hash == rh { st.known[k] = accepted; st.conflicts.removeAll { $0.key == k }; continue }
            let from = (r.deviceName ?? "").isEmpty ? "another Mac" : r.deviceName!
            func keepMine(hold reason: String?) {
                st.known[k]?.tag = r.remoteTag
                st.known[k]?.version = r.remoteVersion
                st.known[k]?.modifiedAt = max(e.modifiedAt, r.modifiedAt.addingTimeInterval(0.001))
                st.known[k]?.pending = true
                if let reason { hold(&st, k, r, reason, now) }
            }
            if !e.pending { keepMine(hold: nil); continue }                       // stale remote: ours is newer, re-send
            switch (e.deletedAt != nil, r.isTombstone) {
            case (false, true): keepMine(hold: nil)                              // deleted there, edited here: keep the edit
            case (true, false):                                                  // deleted here, edited there: keep the edit
                if apply(r, &doc) { st.known[k] = accepted } else { st.blocked.insert(k) }
            default:
                let mine = localObjects(doc)[k]
                if r.kind == .alert, let a = definition(mine?.payload), let b = definition(r.payload), a == b {
                    // Only state differs (fired on one Mac, seen on another): newer wins.
                    if r.modifiedAt > e.modifiedAt { if apply(r, &doc) { st.known[k] = accepted } } else { keepMine(hold: nil) }
                } else {
                    keepMine(hold: "edited on this Mac and on \(from) before they synced")
                }
            }
        }
    }

    static func hold(_ st: inout SyncState, _ key: String, _ other: SyncRecord, _ reason: String, _ now: Date) {
        var o = other
        o.remoteTag = nil
        st.conflicts.removeAll { $0.key == key }
        st.conflicts.append(SyncConflict(key: key, kind: other.kind, reason: reason, other: o, detectedAt: now))
    }

    @discardableResult
    public static func apply(_ r: SyncRecord, _ doc: inout IntelDocument) -> Bool {
        let dec = PortfolioDocument.decoder
        guard let id = UUID(uuidString: r.id) else { return false }
        switch r.kind {
        case .watch:
            if r.isTombstone { doc.watchlist.removeAll { $0.id == id }; return true }
            guard let w = try? dec.decode(WatchItem.self, from: r.payload ?? Data()), w.id == id else { return false }
            if let i = doc.watchlist.firstIndex(where: { $0.id == id }) { doc.watchlist[i] = w } else { doc.watchlist.append(w) }
        case .alert:
            if r.isTombstone { doc.alerts.removeAll { $0.id == id }; return true }
            guard let a = try? dec.decode(AlertRule.self, from: r.payload ?? Data()), a.id == id else { return false }
            if let i = doc.alerts.firstIndex(where: { $0.id == id }) { doc.alerts[i] = a } else { doc.alerts.append(a) }
        case .scenario:
            if r.isTombstone { doc.scenarios.removeAll { $0.id == id }; return true }
            guard let s = try? dec.decode(PortfolioScenario.self, from: r.payload ?? Data()), s.id == id else { return false }
            if let i = doc.scenarios.firstIndex(where: { $0.id == id }) { doc.scenarios[i] = s } else { doc.scenarios.append(s) }
        default: return false
        }
        return true
    }

    /// Two Macs' data side by side after the first merge. Deterministic (no clock), so both Macs
    /// normalizing the same records produce the same records.
    public static func normalize(_ doc: inout IntelDocument) {
        // Presets created on both Macs: the first (by id) keeps the switch key, the others become "BASE 2".
        var seenKeys = Set<String>()
        for i in doc.scenarios.indices.sorted(by: { doc.scenarios[$0].id.uuidString < doc.scenarios[$1].id.uuidString }) {
            guard let k = doc.scenarios[i].key else { continue }
            if seenKeys.contains(k) { doc.scenarios[i].key = nil } else { seenKeys.insert(k) }
        }
        var names = Set<String>()
        for i in doc.scenarios.indices.sorted(by: { (doc.scenarios[$0].key == nil ? 1 : 0, doc.scenarios[$0].id.uuidString) < (doc.scenarios[$1].key == nil ? 1 : 0, doc.scenarios[$1].id.uuidString) }) {
            var name = doc.scenarios[i].name, n = 2
            while names.contains(name) { name = "\(doc.scenarios[i].name) \(n)"; n += 1 }
            doc.scenarios[i].name = name
            names.insert(name)
        }
        // The same coin watched on both Macs: the earliest stays, the others are archived (not deleted).
        var watched = Set<AssetID>()
        for i in doc.watchlist.indices.sorted(by: { (doc.watchlist[$0].addedAt, doc.watchlist[$0].id.uuidString) < (doc.watchlist[$1].addedAt, doc.watchlist[$1].id.uuidString) })
        where doc.watchlist[i].isActive {
            if watched.contains(doc.watchlist[i].assetID) { doc.watchlist[i].archivedAt = doc.watchlist[i].addedAt } else { watched.insert(doc.watchlist[i].assetID) }
        }
        // The 0.6 → 0.7 migration ran on both Macs: identical migrated rules become one.
        let byAge = doc.alerts.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var kept: [AlertRule] = [], drop = Set<UUID>()
        for a in byAge {
            if (a.note ?? "").hasPrefix("from 0.6"), kept.contains(where: { $0.kind == a.kind && $0.subject == a.subject && $0.threshold == a.threshold && $0.note == a.note }) {
                drop.insert(a.id)
            } else { kept.append(a) }
        }
        doc.alerts.removeAll { drop.contains($0.id) }
        // "#5" twice: the older rule keeps it, the newer one gets the next free number.
        var numbers = Set<Int>()
        var next = (doc.alerts.map(\.number).max() ?? 0) + 1
        for i in doc.alerts.indices.sorted(by: { (doc.alerts[$0].createdAt, doc.alerts[$0].id.uuidString) < (doc.alerts[$1].createdAt, doc.alerts[$1].id.uuidString) }) {
            if numbers.contains(doc.alerts[i].number) { doc.alerts[i].number = next; next += 1 }
            numbers.insert(doc.alerts[i].number)
        }
    }

    public static func applySaveOutcomes(sent: [SyncRecord], _ outcomes: [SyncSaveOutcome], _ doc: inout IntelDocument, _ st: inout SyncState, now: Date) {
        let sentHash = Dictionary(sent.map { ($0.key, $0.isTombstone ? "" : SyncEngine.hash($0.payload ?? Data())) }, uniquingKeysWith: { a, _ in a })
        var conflicts: [SyncRecord] = []
        for o in outcomes {
            switch o {
            case let .saved(k, tag, version):
                guard st.known[k] != nil else { continue }
                st.known[k]?.tag = tag
                st.known[k]?.version = version
                if st.known[k]?.hash == sentHash[k] { st.known[k]?.pending = false }
            case let .conflict(_, server): conflicts.append(server)
            case .failed: break
            }
        }
        if !conflicts.isEmpty { applyRemote(conflicts, &doc, &st, now: now) }
    }

    /// The user's pick in a held conflict. `useOther`: apply the other Mac's version; else this
    /// Mac's version stands and is sent (it is already rebased on the other one).
    public static func resolve(_ c: SyncConflict, useOther: Bool, _ doc: inout IntelDocument, _ st: inout SyncState) {
        st.conflicts.removeAll { $0.id == c.id }
        guard useOther else { return }
        var r = c.other
        if r.isTombstone { r.payload = nil }
        apply(r, &doc)
        // Ours was rebased on that version: nothing to send.
        st.known[c.key]?.hash = r.isTombstone ? "" : SyncEngine.hash(r.payload ?? Data())
        st.known[c.key]?.deletedAt = r.deletedAt
        st.known[c.key]?.pending = false
    }

    // MARK: - cycle

    @MainActor private static var running: [ObjectIdentifier: Task<Void, Error>] = [:]

    /// fetch → merge → push, like the ledger. Serialized per host; stops without writing when
    /// cancelled, when sync is off, or when the host can't persist.
    @MainActor
    public static func cycle(_ host: IntelSyncHost, remote: SyncRemoteStore, now: @escaping () -> Date = Date.init) async throws {
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

    @MainActor
    private static func runCycle(_ host: IntelSyncHost, remote: SyncRemoteStore, now: @escaping () -> Date) async throws {
        func active() throws {
            try Task.checkCancellation()
            guard host.intelSyncState.mode == .iCloud else { throw CancellationError() }
            guard host.intelSyncCanPersist else { throw SyncDeferredError() }
        }
        try active()
        detectLocalChanges(host.intelSyncDocument, &host.intelSyncState, now: now())
        let fetched = try await remote.fetchChanges(since: host.intelSyncState.token)
        try active()
        var doc = host.intelSyncDocument, st = host.intelSyncState
        detectLocalChanges(doc, &st, now: now())
        applyRemote(fetched.records, &doc, &st, now: now())
        normalize(&doc)
        detectLocalChanges(doc, &st, now: now())
        st.token = fetched.token
        try commit(host, doc, st)
        for _ in 0..<3 {
            let sent = pendingRecords(host.intelSyncDocument, host.intelSyncState)
            if sent.isEmpty { break }
            let outcomes = try await remote.save(sent)
            try active()
            doc = host.intelSyncDocument; st = host.intelSyncState
            detectLocalChanges(doc, &st, now: now())
            applySaveOutcomes(sent: sent, outcomes, &doc, &st, now: now())
            normalize(&doc)
            detectLocalChanges(doc, &st, now: now())
            try commit(host, doc, st)
            if !outcomes.contains(where: { if case .conflict = $0 { true } else { false } }) { break }
        }
        host.intelSyncState.lastSync = now()
    }

    @MainActor
    private static func commit(_ host: IntelSyncHost, _ doc: IntelDocument, _ st: SyncState) throws {
        if doc != host.intelSyncDocument {
            let before = host.intelSyncDocument
            host.intelSyncDocument = doc
            guard host.intelSyncCanPersist else { host.intelSyncDocument = before; throw SyncDeferredError() }
        }
        host.intelSyncState = st
    }
}
