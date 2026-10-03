import PFCore
import PFCoreUI
import AppKit
import SwiftUI

// 0.6 "a ledger you can trust": local recovery snapshots, safety snapshots before anything that
// replaces or removes ledger data, restore, import preview, data health, privacy-safe
// diagnostics, depeg alerts, app-lock lifecycle and remove position.

/// Restore overlay: pick a snapshot, see what changes, confirm.
struct RestoreState {
    var sel = 0
    var doc: PortfolioDocument?
    var error: String?
}

/// Import into one portfolio, after classification.
struct ImportPreviewState {
    let portfolioID: UUID
    let plan: ImportPlanner.Plan
    let assets: [Asset]
}

extension AppStore {
    // MARK: snapshots

    func reloadSnapshots() { snapshotList = snapshots.list() }

    /// Verified snapshot before an operation that replaces or removes ledger data. false: the
    /// snapshot failed and the caller must not go on.
    @discardableResult
    func safetySnapshot(_ r: SnapshotStore.Reason) -> Bool {
        guard !doc.transactions.isEmpty || doc.portfolios.count > 1 else { return true }   // nothing to lose
        do {
            try snapshots.create(doc, reason: r, appVersion: installedVersion.display)
            diagnostics.record(.backup, .info, "safety-snapshot")
            reloadSnapshots()
            return true
        } catch {
            diagnostics.record(.backup, .error, "safety-snapshot-failed", error: error)
            message = "✗ could not save a safety snapshot first · nothing was changed · \(error)"
            return false
        }
    }

    /// Rolling snapshot shortly after ledger edits settle (only when the ledger changed).
    func scheduleRollingSnapshot(delay: TimeInterval = 20) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rollingSnapshotNow()
        }
    }

    func rollingSnapshotNow(reason: SnapshotStore.Reason = .auto) {
        guard hasPortfolio, !doc.isDemo(.all) else { return }
        do {
            if try snapshots.snapshotIfChanged(doc, reason: reason, appVersion: installedVersion.display) != nil {
                diagnostics.record(.backup, .info, "rolling-snapshot")
                reloadSnapshots()
            }
        } catch {
            diagnostics.record(.backup, .error, "rolling-snapshot-failed", error: error)
        }
    }

    // MARK: restore

    func openRestore() {
        reloadSnapshots()
        restore = RestoreState()
        loadRestorePreview()
    }

    func moveRestoreSelection(_ d: Int) {
        guard var r = restore, !snapshotList.isEmpty else { return }
        r.sel = max(0, min(snapshotList.count - 1, r.sel + d))
        restore = r
        loadRestorePreview()
    }

    func loadRestorePreview() {
        guard let r = restore, let s = snapshotList[safe: r.sel] else { restore?.doc = nil; return }
        do { restore?.doc = try snapshots.load(s); restore?.error = nil }
        catch { restore?.doc = nil; restore?.error = "\(error)" }
    }

    /// What a restore would change, by stable transaction id.
    func restoreDiff(_ d: PortfolioDocument) -> (added: Int, removed: Int, changed: Int) {
        let cur = Dictionary(doc.transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(d.transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (new.keys.filter { cur[$0] == nil }.count, cur.keys.filter { new[$0] == nil }.count,
                new.filter { cur[$0.key].map { $0 != new[$0.id] } ?? false }.count)
    }

    func confirmRestore() {
        guard let r = restore, let d = r.doc, let info = snapshotList[safe: r.sel] else { return }
        guard safetySnapshot(.beforeRestore) else { return }
        doc = d
        context = doc.validContext(context)
        persistContext()
        save()
        // Verify: what is on disk now is exactly the snapshot, and it is a valid ledger.
        let back = try? files.load()
        let ok = back?.transactions == d.transactions && back?.portfolios == d.portfolios && d.validationErrors(ledger: false).isEmpty
        cache.invalidateSnapshots(from: .distantPast)
        series = [:]
        restore = nil
        recompute()
        go(.overview)
        diagnostics.record(.backup, ok ? .info : .error, ok ? "restored" : "restore-verify-failed")
        message = ok ? "✓ restored the snapshot from \(DateFmt.ymd(info.createdAt)) \(DateFmt.hm(info.createdAt)) · verified · the previous state was saved as a snapshot first"
                     : "✗ restore written but verification failed · the previous state is in DATA RECOVERY"
        Task { await refresh(auto: false) }
    }

    // MARK: import preview (merge into one portfolio)

    func importIntoCurrentPortfolio() {
        guard let id = context.portfolioID else { message = "choose a portfolio first (⌘P) · import adds to one portfolio"; return }
        importIntoPortfolio(id)
    }

    /// Classify before merging: nothing is added until the user confirms the preview.
    func previewImport(_ src: PortfolioDocument, into id: UUID) {
        let known = Set(doc.assets.map(\.id)).union(src.assets.map(\.id))
        let plan = ImportPlanner.plan(src.transactions, into: id, doc: doc, knownAssets: known)
        importPreview = ImportPreviewState(portfolioID: id, plan: plan, assets: src.assets)
    }

    func applyImportPreview(includeReview: Bool) {
        guard let p = importPreview else { return }
        let statuses: Set<ImportPlanner.Status> = includeReview ? [.ready, .review] : [.ready]
        let txs = p.plan.transactions(statuses).map { var t = $0; t.id = UUID(); return t }
        var next = doc
        for a in p.assets where !next.assets.contains(where: { $0.id == a.id }) && txs.contains(where: { $0.assetID == a.id }) { next.assets.append(a) }
        next.transactions += txs
        if let e = next.validationErrors().first {
            message = "✗ import rejected · \(e) · nothing changed"
            diagnostics.record(.ledger, .warning, "import-rejected")
            return
        }
        importPreview = nil
        guard !txs.isEmpty else { message = "nothing imported"; return }
        doc = next
        save()
        cache.invalidateSnapshots(from: txs.map(\.timestamp).min() ?? .distantPast)
        recompute()
        diagnostics.record(.ledger, .info, "imported")
        let skipped = p.plan.items.count - txs.count
        message = "✓ imported \(txs.count) transactions into \(doc.portfolio(p.portfolioID)?.name ?? "")" + (skipped > 0 ? " · \(skipped) skipped (duplicates, invalid or not reviewed)" : "")
        Task { await refresh(auto: false) }
    }

    // MARK: remove position

    func requestRemovePosition(_ id: AssetID) {
        guard let pid = context.portfolioID else {
            message = "positions belong to portfolios · switch to one (⌘P) to remove a position there"
            return
        }
        pendingRemovePosition = (id, pid)
    }

    /// Deletes the asset's transactions in one portfolio (a ledger operation; holdings follow).
    func removePosition(_ id: AssetID, from pid: UUID) {
        pendingRemovePosition = nil
        let gone = doc.transactions.filter { $0.assetID == id && $0.portfolioID == pid }
        guard !gone.isEmpty, safetySnapshot(.beforeRemovePosition) else { return }
        doc.transactions.removeAll { $0.assetID == id && $0.portfolioID == pid }
        if !doc.transactions.contains(where: { $0.assetID == id }) { doc.assets.removeAll { $0.id == id } }
        save()
        cache.invalidateSnapshots(from: gone.map(\.timestamp).min() ?? .distantPast)
        recompute()
        if screen == .asset { go(.overview) }
        diagnostics.record(.ledger, .info, "position-removed")
        message = "✓ removed \(asset(id)?.symbol ?? id) from \(doc.portfolio(pid)?.name ?? "") · \(gone.count) transactions · undo: Settings → DATA RECOVERY"
    }

    // MARK: data health

    var dataHealth: [DataHealth.Finding] {
        var syncError = false
        if syncEnabled, case .error = syncStatus { syncError = true }
        return DataHealth.check(.init(doc: doc, quotes: quotes, marketDriven: marketDrivenAnywhere, now: now,
                                      staleAfter: max(15 * 60, 3 * TimeInterval(settings.refreshSeconds)),
                                      sync: syncEnabled ? syncState : nil, syncError: syncError,
                                      latestSnapshot: doc.isDemo(.all) ? now : snapshotList.first?.createdAt))   // demo data is never snapshotted
    }

    /// Held assets in any live portfolio that are valued at a market price.
    var marketDrivenAnywhere: [AssetID] {
        heldAnywhere.filter { !Stablecoins.isPegValued($0, quote: quotes[$0], currency: settings.currency) }.sorted()
    }

    func reviewFinding(_ f: DataHealth.Finding) {
        switch f.area {
        case .sync where !syncState.conflicts.isEmpty: syncSheet = .conflicts
        case .recovery: rollingSnapshotNow(reason: .daily); message = snapshotList.isEmpty ? "✗ no snapshot written" : "✓ recovery snapshot saved"
        default: if let a = f.asset, doc.assets.contains(where: { $0.id == a }) { openAsset(a) }
        }
    }

    // MARK: diagnostics

    func diagnosticReport() -> String {
        var i = DiagnosticReport.Input()
        let v = installedVersion
        i.app = v.display; i.build = v.build
        i.os = ProcessInfo.processInfo.operatingSystemVersionString
        i.registry = "\(AssetRegistry.shared.version) · \(AssetRegistry.shared.count) assets"
        i.transactionBucket = DiagnosticReport.bucket(doc.transactions.count)
        let s = settings
        i.flags = [("source", s.primaryProvider), ("live feeds", s.realtimeProvider == "off" ? "off" : "on"), ("refresh", "\(s.refreshSeconds)s"),
                   ("currency", s.currency), ("app lock", s.appLock ? "on" : "off"), ("alert rules", "\(intel.alerts.count)"),
                   ("alert delivery", s.alertBanner ? "banner" : "menu bar"), ("widget privacy", s.widgetPrivacy == .full ? "full" : "percent only"),
                   ("menu bar", "\(s.menuBar)")]
        let st = syncState
        i.sync = [("mode", st.mode.rawValue), ("status", syncStatusKind), ("last sync", DiagnosticReport.age(st.lastSync, now: i.now)),
                  ("queued", "\(st.pendingCount)"), ("conflicts", "\(st.conflicts.count)"), ("held back", "\(st.blocked.count)"),
                  ("recovering", st.recovering?.rawValue ?? "no"), ("known records", DiagnosticReport.bucket(st.known.count))]
        i.market = [("last success", DiagnosticReport.age(lastSuccess, now: i.now)), ("failures in a row", "\(consecutiveFailures)"),
                    ("last error", lastError.map(DiagnosticLog.kind) ?? "none"), ("online", online ? "yes" : "no"),
                    ("binance feed", feedKind(streamState)), ("bybit feed", feedKind(bybitState))]
            + providerHealth.map { h in ("backoff " + h.name.lowercased(), "\(h.failures) failures" + (h.blockedUntil.map { " · cooling down \(Int($0.timeIntervalSince(i.now)))s" } ?? "")) }
        i.backups = [("snapshots", "\(snapshotList.count)"), ("latest", DiagnosticReport.age(snapshotList.first?.createdAt, now: i.now)),
                     ("safety snapshots", "\(snapshotList.filter(\.isSafety).count)")]
        // Health by area and level only: the texts name assets.
        i.health = dataHealth.map { "\($0.level == .ok ? "ok" : $0.level == .warning ? "warning" : "problem") · \($0.area.rawValue)" }
        i.events = diagnostics.events
        return DiagnosticReport.make(i)
    }

    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport(), forType: .string)
        message = "✓ diagnostic report copied · no names, values, quantities, notes, keys or account ids"
    }

    /// The sync status case without its message (error texts can carry anything).
    var syncStatusKind: String {
        switch syncStatus {
        case .localOnly: "local only"; case .checking: "checking"; case .syncing: "syncing"; case .synced: "synced"; case .offline: "offline"
        case .iCloudUnavailable: "icloud unavailable"; case .accountUnavailable: "account unavailable"; case .conflict: "conflicts"; case .error: "error"
        }
    }

    private func feedKind(_ s: LiveFeed.State) -> String {
        switch s { case .off: "off"; case .connecting: "connecting"; case .connected: "connected"; case .disconnected: "retrying" }
    }

    func refreshProviderHealth() { Task { providerHealth = await router.health() } }

    // MARK: app lock

    /// Lock rules: at launch, immediately when turned on, when the Mac sleeps or the screen
    /// locks, and after `lockAfterInactive` in the background.
    func startLockObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfEnabled("sleep") }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfEnabled("screen-locked") }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inactiveSince = Date() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let t = self.inactiveSince, Date().timeIntervalSince(t) >= Self.lockAfterInactive { self.lockIfEnabled("inactive") }
                self.inactiveSince = nil
            }
        }
    }
    static let lockAfterInactive: TimeInterval = 5 * 60

    func lockIfEnabled(_ why: StaticString) {
        guard settings.appLock, !locked else { return }
        locked = true
        popoverOpen = false
        diagnostics.record(.lock, .info, why)
    }

    /// Turning the lock on checks that the system can actually authenticate, then locks at once.
    func appLockToggled() {
        if settings.appLock {
            if let why = AppLock.unavailableReason() {
                settings.appLock = false
                message = "✗ app lock needs Touch ID or a login password on this Mac · \(why)"
                return
            }
            lockIfEnabled("enabled")
            message = "✓ app lock on · locks now, on sleep, screen lock and after 5 min in the background"
        } else {
            lockError = nil
        }
    }

    func unlock() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            let r = await AppLock.evaluate()
            unlocking = false
            switch r {
            case .unlocked: locked = false; lockError = nil
            case .failed: lockError = nil; diagnostics.record(.lock, .warning, "unlock-failed")
            case let .unavailable(m): lockError = m; diagnostics.record(.lock, .error, "auth-unavailable")   // stays locked
            }
        }
    }
}
