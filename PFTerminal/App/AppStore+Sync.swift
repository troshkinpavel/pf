import PFCore
import PFCoreUI
import AppKit
import CloudKit
import Security
import SwiftUI

/// Confirmation and review overlays for iCloud sync. Nothing here changes data until the user
/// picks an explicit action in the overlay.
enum SyncSheet: Equatable {
    case checking
    case confirm(SyncEngine.Inspection)
    case working(String)
    case unavailable(String)
    case disable
    case conflicts
}

enum SyncTrigger { case launch, edit, network, timer, active, account, manual }

extension AppStore: SyncHost {
    /// Sync writes go straight to disk and recompute, without re-triggering sync.
    var syncDocument: PortfolioDocument {
        get { doc }
        set {
            syncApplying = true
            doc = newValue
            context = doc.validContext(context)
            persistContext()
            save()
            syncApplying = false
            recompute()
        }
    }
}

extension AppStore {
    // MARK: availability

    static var cloudContainerID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "PFCloudContainer") as? String).flatMap { $0.hasPrefix("iCloud.") ? $0 : nil }
    }

    /// True only when the running binary is signed with CloudKit for our container.
    /// Unsigned / ad hoc builds report "iCloud unavailable" instead of trapping in CKContainer.
    static var hasCloudEntitlement: Bool {
        guard let id = cloudContainerID, let task = SecTaskCreateFromSelf(nil) else { return false }
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String] ?? []
        let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] ?? []
        return services.contains("CloudKit") && containers.contains(id)
    }

    /// CloudKit environment this binary is signed for ("Development"/"Production").
    static var cloudEnvironment: String {
        guard let task = SecTaskCreateFromSelf(nil) else { return "unknown" }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil) as? String ?? "none"
    }

    /// A Debug build (CloudKit Development) shares the release app's container, and so its sync
    /// state (Production). Syncing that state against the other environment would mix tokens and
    /// change tags; such a build leaves sync paused instead. Injected test stores always match.
    var syncEnvironmentMatches: Bool { syncRemoteEnvironment.map { syncState.matches(environment: $0) } ?? true }

    static func makeSyncRemote() -> SyncRemoteStore? {
        guard Self.hasCloudEntitlement, let id = Self.cloudContainerID else { return nil }
        return CloudKitSyncStore(containerIdentifier: id)
    }

    var syncEnabled: Bool { syncState.mode == .iCloud }

    // MARK: state file (device-local, never synced)

    func loadSyncState() {
        if let s = SyncStateFile.load(from: files.directory) { syncState = s }
        if syncState.deviceName.isEmpty { syncState.deviceName = Host.current().localizedName ?? "Mac" }
        syncStatus = syncEnabled ? .checking : .localOnly
    }

    func persistSyncState() { SyncStateFile.save(syncState, to: files.directory) }

    // MARK: scheduling

    func startSync() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow(reason: .account) }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastSyncAttempt) > 60 else { return }
                self.syncNow(reason: .active)
            }
        }
        syncNow(reason: .launch)
    }

    /// After a local save: queue the change in sync-state.json right away (so it survives being
    /// offline or a restart, and "newer" means edit time), then debounce the actual sync.
    func scheduleSync() {
        guard syncEnabled, !syncApplying else { return }
        SyncEngine.detectLocalChanges(doc, &syncState, now: Date())
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.syncNow(reason: .edit)
        }
    }

    func syncNow(reason: SyncTrigger) {
        guard syncEnabled, syncTask == nil else { return }
        guard let remote = syncRemote else { syncStatus = .iCloudUnavailable; return }
        guard syncEnvironmentMatches else {
            syncStatus = .error("paused · sync state belongs to CloudKit \(syncState.environment ?? SyncState.assumedEnvironment)")
            diagnostics.record(.sync, .warning, "environment-mismatch")
            return
        }
        lastSyncAttempt = Date()
        syncStatus = .syncing
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let recovering = SyncEngine.isReplaced(SyncEngine.localObjects(self.doc), self.syncState) || self.syncState.recovering != nil
                try await SyncEngine.cycle(self, remote: remote)
                self.diagnostics.record(.sync, .info, recovering ? "pass-recovered" : "pass-ok")
                if recovering { self.message = "✓ portfolios restored from iCloud · \(self.doc.livePortfolios.count) portfolios · \(self.doc.transactions.count) transactions" }
                self.syncStatus = self.syncState.conflicts.isEmpty ? .synced : .conflict(self.syncState.conflicts.count)
            } catch {
                self.syncFailed(error)
            }
            self.syncTask = nil
            // Edits made after the last push of this cycle: go again. (Failed records wait for the timer.)
            if self.syncEnabled, SyncEngine.detectLocalChanges(self.doc, &self.syncState, now: Date()) > 0 { self.scheduleSync() }
        }
    }

    private func syncFailed(_ error: Error) {
        diagnostics.record(.sync, error is CancellationError ? .info : .warning, error is CancellationError ? "pass-cancelled" : "pass-failed", error: error)
        // Sync was turned off (or the pass superseded) mid-pass: nothing was written, nothing failed.
        if error is CancellationError { syncStatus = syncEnabled ? .offline : .localOnly; return }
        let (status, turnsOff) = SyncStatus.after(error)
        if turnsOff { SyncEngine.disable(self) }
        syncStatus = status
        switch error as? SyncStoreError {
        case .accountChanged?: message = "iCloud account changed · sync turned off · your portfolios stay on this Mac"
        case .cloudDataDeleted?: message = "✗ PF data was removed from iCloud · sync turned off · your portfolios stay on this Mac"
        default: break
        }
    }

    static func describe(_ error: Error) -> String {
        SyncStoreError.describe(error, signInHint: "System Settings › Apple Account")
    }

    // MARK: enable / disable (always via an explicit confirmation)

    func beginEnableSync() {
        guard let remote = syncRemote else {
            syncSheet = .unavailable("this build of PF isn't signed with the iCloud capability. release builds from GitHub include it once available; for source builds see docs/DEVELOPMENT.md → iCloud sync.")
            return
        }
        syncSheet = .checking
        syncStatus = .checking
        Task {
            do {
                let i = try await SyncEngine.inspect(self, remote: remote)
                if syncSheet == .checking { syncSheet = .confirm(i) }
            } catch {
                if syncSheet == .checking { syncSheet = .unavailable(Self.describe(error)) }
            }
            if !syncEnabled { syncStatus = .localOnly }
        }
    }

    func confirmEnableSync(_ choice: SyncEngine.Choice) {
        guard let remote = syncRemote, syncTask == nil else { return }
        if choice == .useCloud {
            // This Mac's ledger is replaced: a verified recovery snapshot first (Settings → DATA RECOVERY).
            guard safetySnapshot(.beforeICloud) else { syncSheet = .unavailable("could not back up this Mac's portfolios first · nothing was changed"); return }
        }
        syncSheet = .working(choice == .useCloud ? "downloading from iCloud…" : "syncing with iCloud…")
        syncStatus = .syncing
        lastSyncAttempt = Date()
        let name = Host.current().localizedName ?? "Mac"
        syncTask = Task {
            do {
                try await SyncEngine.enable(self, remote: remote, choice: choice, deviceName: name)
                syncState.environment = syncRemoteEnvironment
                syncStatus = syncState.conflicts.isEmpty ? .synced : .conflict(syncState.conflicts.count)
                syncSheet = syncState.conflicts.isEmpty ? nil : .conflicts
                message = "✓ iCloud sync on · \(doc.portfolios.count) portfolios · \(doc.transactions.count) transactions"
            } catch {
                if syncEnabled {
                    syncState.environment = syncRemoteEnvironment
                    // Turned on, but the first sync didn't finish: changes stay queued and retry.
                    syncFailed(error)
                    syncSheet = nil
                    message = "iCloud sync on · first sync pending · \(Self.describe(error))"
                } else {
                    syncStatus = .localOnly
                    syncSheet = .unavailable(Self.describe(error) + " · nothing was changed")
                }
            }
            syncTask = nil
        }
    }

    func confirmDisableSync() {
        syncTask?.cancel()
        syncTask = nil
        SyncEngine.disable(self)
        syncStatus = .localOnly
        syncSheet = nil
        message = "iCloud sync off · portfolios stay on this Mac · the iCloud copy is not deleted"
    }

    // MARK: conflicts

    func resolveConflict(_ c: SyncConflict, useOther: Bool) {
        if useOther {
            var d = doc, st = syncState
            SyncEngine.restore(c, &d, &st)
            syncState = st
            doc = d
            context = doc.validContext(context)
            save()
            recompute()
        } else {
            syncState.conflicts.removeAll { $0.id == c.id }
        }
        if syncState.conflicts.isEmpty {
            if syncSheet == .conflicts { syncSheet = nil }
            if case .conflict = syncStatus { syncStatus = .synced }
        } else if case .conflict = syncStatus {
            syncStatus = .conflict(syncState.conflicts.count)
        }
    }

    /// One-line description of what a conflict record is, for the review list.
    func conflictTitle(_ c: SyncConflict) -> String {
        guard let (_, id) = SyncEngine.split(c.key) else { return c.key }
        switch c.kind {
        case .portfolio:
            let p = c.other.payload.flatMap { try? PortfolioDocument.decoder.decode(PortfolioInfo.self, from: $0) }
            return "portfolio \(p?.name ?? UUID(uuidString: id).flatMap { doc.portfolio($0)?.name } ?? String(id.prefix(8)))"
        case .transaction:
            let t = c.other.payload.flatMap { try? PortfolioDocument.decoder.decode(Transaction.self, from: $0) }
                ?? doc.transactions.first { $0.id.uuidString == id }
            guard let t else { return "transaction \(id.prefix(8))" }
            return "\(t.type.short) \(Fmt.current.amount(t.quantity)) \(asset(t.assetID)?.symbol ?? "") · \(DateFmt.ymd(t.timestamp))"
        case .asset:
            return "asset \(id)"
        }
    }

    // MARK: labels

    var syncStatusLabel: String {
        switch syncStatus {
        case .localOnly: "off · local only"
        case .checking: "checking iCloud…"
        case .syncing: "syncing…"
        case .synced: "synced"
        case .offline: "offline · \(syncState.pendingCount) change\(syncState.pendingCount == 1 ? "" : "s") queued"
        case .iCloudUnavailable: "iCloud unavailable"
        case .accountUnavailable: "iCloud account unavailable"
        case let .conflict(n): "\(n) conflict\(n == 1 ? "" : "s") to review"
        case let .error(m): "error · \(m)"
        }
    }

    /// Status bar: one word, only while sync is on.
    var syncShortLabel: String? {
        guard syncEnabled else { return nil }
        switch syncStatus {
        case .synced: return "icloud: synced"
        case .syncing, .checking: return "icloud: syncing"
        case .offline: return "icloud: offline"
        case .conflict: return "icloud: review"
        default: return "icloud: sync error"
        }
    }

    var syncStatusColor: Color {
        switch syncStatus {
        case .synced: Theme.pos
        case .syncing, .checking, .conflict: Theme.acc
        case .localOnly: Theme.t2
        default: Theme.neg
        }
    }
}
