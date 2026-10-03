import PFCore
import PFCoreUI
import AppKit

// Locked Mac (Priority 0 of the 0.7 hardening). The ledger and recovery snapshots keep
// "complete" file protection, so while the Mac is locked they can be neither read nor written.
// That is a wait: the ledger is never treated as missing or corrupt, never replaced, never
// synced from an unloaded or unsaved state, and the sync token never moves past what is on disk.
extension AppStore {
    /// One diagnostic event and one message per episode, not per attempt.
    func enterProtectedWait(_ code: StaticString) {
        guard !protectedDataWaiting else { return }
        protectedDataWaiting = true
        protectedRetryAt = Date().addingTimeInterval(30)
        diagnostics.record(.ledger, .warning, code)
        message = "protected data unavailable — waiting for unlock"
    }

    /// Unlock, session active, app active, and every 30 s while waiting. Safe to call any time.
    func resumeProtectedData() {
        guard protectedDataWaiting else { return }
        protectedRetryAt = Date().addingTimeInterval(30)
        if ledgerLoadDeferred {
            ledgerLoadDeferred = false
            loadFromDisk()
            guard !ledgerLoadDeferred else { return }          // still locked
            context = doc.validContext(context)
            recompute()
        }
        if pendingLedgerSave {
            do {
                if let e = ledgerFault?() { throw e }
                try files.save(doc)
                pendingLedgerSave = false
            } catch {
                if !ProtectedData.isUnavailable(error) {
                    pendingLedgerSave = false
                    message = "✗ could not save portfolio · \(error.localizedDescription)"
                    diagnostics.record(.ledger, .error, "save-failed", error: error)
                }
                return
            }
        }
        guard resumeIntelPrivate() else { return }
        protectedDataWaiting = false
        diagnostics.record(.ledger, .info, "protected-data-resumed")
        message = "✓ unlocked · ledger available"
        reloadSnapshots()
        syncNow(reason: .active)
        scheduleRollingSnapshot(delay: 5)
    }

    func startProtectedDataObservers() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeProtectedData() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeProtectedData() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeProtectedData() }
        }
    }
}

extension AppStore {
    /// SyncHost: no pass while the ledger isn't loaded or a save is waiting.
    var syncCanPersist: Bool { !ledgerLoadDeferred && !pendingLedgerSave }
}
