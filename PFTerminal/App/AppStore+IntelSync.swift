import PFCore
import PFCoreUI
import AppKit
import SwiftUI

// 0.8.3: watchlist, alerts and scenarios join iCloud sync (design §28), shared with PF for iPhone
// 1.1. They follow the ledger's iCloud switch; their records live in their own zone with their own
// state file. The alert log never syncs.

extension AppStore: IntelSyncHost {
    var intelSyncDocument: IntelDocument {
        get { intel }
        set {
            intelSyncApplying = true
            intel = newValue
            saveIntel()
            intelSyncApplying = false
        }
    }

    /// Never sync placeholders: watchlist / scenarios still locked, a newer file, a write waiting.
    var intelSyncCanPersist: Bool { intelReadOnly == nil && !intelPrivateDeferred && !intelPrivatePending }
}

extension AppStore {
    static func makeIntelSyncRemote() -> SyncRemoteStore? {
        guard Self.hasCloudEntitlement, let id = Self.cloudContainerID else { return nil }
        return CloudKitSyncStore(containerIdentifier: id, zoneName: IntelSyncEngine.zoneName)
    }

    func loadIntelSyncState() {
        if let s = SyncStateFile.load(from: files.directory, file: SyncStateFile.intelFile) { intelSyncState = s }
        intelSyncStatus = intelSyncState.mode == .iCloud ? .checking : .localOnly
        intelVerifyLoad()
    }

    func persistIntelSyncState() { SyncStateFile.save(intelSyncState, to: files.directory, file: SyncStateFile.intelFile) }

    /// After an intel save: queue the change, debounce the pass.
    func scheduleIntelSync() {
        guard syncEnabled, !intelSyncApplying, intelSyncState.mode == .iCloud, intelSyncCanPersist else { return }
        IntelSyncEngine.detectLocalChanges(intel, &intelSyncState, now: Date())
        intelSyncDebounce?.cancel()
        intelSyncDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.intelSyncNow()
        }
    }

    /// Runs after each successful ledger pass (same account check) and after intel edits.
    func intelSyncNow() {
        guard syncEnabled else {
            if intelSyncState.mode == .iCloud { intelSyncDisable() }
            return
        }
        guard intelSyncTask == nil, let remote = intelSyncRemote else { return }
        if intelSyncState.mode != .iCloud {
            // First pass on this Mac (upgrade or sync just turned on): a full fetch, then a merge.
            var st = SyncState()
            st.mode = .iCloud
            st.deviceID = syncState.deviceID; st.deviceName = syncState.deviceName
            st.environment = syncRemoteEnvironment ?? syncState.environment
            intelSyncState = st
            intelLoadUnverified = []   // nothing synced yet: nothing to rebase
        }
        if let env = syncRemoteEnvironment, !intelSyncState.matches(environment: env) {
            intelSyncStatus = .error("paused · sync state belongs to CloudKit \(intelSyncState.environment ?? SyncState.assumedEnvironment)")
            return
        }
        guard intelSyncCanPersist else { intelSyncStatus = .error("waiting for unlock"); return }
        intelSyncStatus = .syncing
        intelSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await IntelSyncEngine.cycle(self, remote: remote)
                self.intelSyncStatus = self.intelSyncState.conflicts.isEmpty ? .synced : .conflict(self.intelSyncState.conflicts.count)
                self.diagnostics.record(.sync, .info, "intel-pass-ok")
            } catch is SyncDeferredError {
                self.intelSyncStatus = .error("waiting for unlock")
            } catch is CancellationError {
                self.intelSyncStatus = self.syncEnabled ? .offline : .localOnly
            } catch {
                self.intelSyncStatus = SyncStatus.after(error).status
                self.diagnostics.record(.sync, .warning, "intel-pass-failed", error: error)
            }
            self.intelSyncTask = nil
            if self.syncEnabled, self.intelSyncCanPersist, self.intelSyncState.mode == .iCloud,
               IntelSyncEngine.detectLocalChanges(self.intel, &self.intelSyncState, now: Date()) > 0 { self.scheduleIntelSync() }
        }
    }

    func intelSyncDisable() {
        intelSyncTask?.cancel(); intelSyncTask = nil
        var st = SyncState()
        st.deviceID = intelSyncState.deviceID; st.deviceName = intelSyncState.deviceName
        intelSyncState = st
        intelSyncStatus = .localOnly
    }

    // MARK: conflicts (whole-record; "keep this Mac" / "keep <other Mac>")

    var intelConflict: SyncConflict? { intelSyncState.conflicts.first }

    func resolveIntelConflict(_ c: SyncConflict, keepOther: Bool) {
        var d = intel, st = intelSyncState
        IntelSyncEngine.resolve(c, useOther: keepOther, &d, &st)
        intelSyncState = st
        if d != intel { intelSyncDocument = d }
        if intelSyncState.conflicts.isEmpty, syncSheet == .intelConflict { syncSheet = nil }
        intelSyncStatus = intelSyncState.conflicts.isEmpty ? .synced : .conflict(intelSyncState.conflicts.count)
        message = "✓ kept " + (keepOther ? otherDevice(c) : "this Mac") + "'s version · " + intelConflictTitle(c)
        scheduleIntelSync()
    }

    func otherDevice(_ c: SyncConflict) -> String { (c.other.deviceName ?? "").isEmpty ? "the other Mac" : c.other.deviceName! }

    /// "alert #5 · TEL allocation"
    func intelConflictTitle(_ c: SyncConflict) -> String {
        let id = SyncEngine.split(c.key)?.1 ?? ""
        switch c.kind {
        case .alert:
            let r = intel.alerts.first { $0.id.uuidString == id } ?? c.other.payload.flatMap { try? PortfolioDocument.decoder.decode(AlertRule.self, from: $0) }
            return r.map { "alert #\($0.number) · " + alertSubjectLabel($0.subject) + " " + $0.kind.label } ?? "alert"
        case .watch:
            let w = intel.watchlist.first { $0.id.uuidString == id }
            return "watchlist · " + (w?.asset.symbol ?? "asset")
        case .scenario:
            return "scenario · " + (intel.scenarios.first { $0.id.uuidString == id }?.name ?? "scenario")
        default: return c.key
        }
    }

    /// One line per side: what differs, whole record (design: "CONDITION EDITED").
    func intelConflictLine(_ c: SyncConflict, other: Bool) -> String {
        let id = SyncEngine.split(c.key)?.1 ?? ""
        let dec = PortfolioDocument.decoder, f = Fmt.current
        let payload: Data? = other ? c.other.payload : IntelSyncEngine.localObjects(intel)[c.key]?.payload
        guard let payload else { return "deleted" }
        switch c.kind {
        case .alert:
            guard let r = try? dec.decode(AlertRule.self, from: payload) else { return "—" }
            return AlertEngine.condition(r, fmt: f) + " · repeat " + r.repeatMode.rawValue + (r.paused ? " · paused" : "")
        case .watch:
            guard let w = try? dec.decode(WatchItem.self, from: payload) else { return "—" }
            let parts = [w.entry.map { "entry " + f.money($0, 2) }, w.target.map { "target " + f.money($0, 2) }, w.note.map { "note “\($0.prefix(30))”" }, w.isActive ? nil : "archived"]
                .compactMap { $0 }
            return parts.isEmpty ? "watching" : parts.joined(separator: " · ")
        case .scenario:
            guard let s = try? dec.decode(PortfolioScenario.self, from: payload) else { return "—" }
            let t = s.targets.sorted { $0.key < $1.key }.prefix(3).map { (asset($0.key)?.symbol ?? $0.key) + " " + f.money($0.value.price, 0) }
            return s.name + " · \(s.targets.count) targets" + (t.isEmpty ? "" : " · " + t.joined(separator: " · "))
        default: _ = id; return "—"
        }
    }

    /// The other side is newer: it's the default (⌘↵).
    func intelConflictOtherIsNewer(_ c: SyncConflict) -> Bool {
        (intelSyncState.known[c.key]?.modifiedAt ?? .distantPast) <= c.other.modifiedAt
    }

    // MARK: header indicator (watchlist / alerts / scenarios; nothing per row)

    /// nil: hide. Synced shows dim; syncing, local only and conflicts stay visible.
    var intelSyncIndicator: (text: String, color: Color, action: () -> Void)? {
        let open: () -> Void = { [weak self] in self?.go(.settings); self?.selectSettingsSection("sync") }
        guard syncEnabled else { return ("local only", Theme.t4, open) }
        if !intelSyncState.conflicts.isEmpty {
            let n = intelSyncState.conflicts.count
            return ("! \(n) conflict\(n == 1 ? "" : "s")", Theme.acc, { [weak self] in self?.syncSheet = .intelConflict })
        }
        switch intelSyncStatus {
        case .syncing, .checking: return ("⟳ syncing", Theme.acc, open)
        case .synced: return ("✓ synced", Theme.t4, open)
        case .localOnly: return ("local only", Theme.t4, open)
        case .offline: return ("offline · \(intelSyncState.pendingCount) queued", Theme.t3, open)
        default: return ("! sync paused", Theme.neg, open)
        }
    }

    /// Settings › data + sync › DOMAINS row value for one intel kind.
    func intelDomainStatus(_ kind: SyncKind) -> (String, SettingRow.Kind) {
        guard syncEnabled else { return ("this Mac only · iCloud off", .muted) }
        let n = intelSyncState.conflicts.filter { $0.kind == kind }.count
        if n > 0 { return ("\(n) conflict\(n == 1 ? "" : "s") · review", .bad) }
        if intelSyncState.lastSync == nil { return ("first sync pending", .info) }
        switch intelSyncStatus {
        case .synced, .syncing, .checking: return ("synced", .ok)
        case .offline: return ("offline · queued", .info)
        default: return (syncStatusLabelFor(intelSyncStatus), .bad)
        }
    }

    func syncStatusLabelFor(_ s: SyncStatus) -> String {
        if case let .error(m) = s { return m }
        return "unavailable"
    }
}
