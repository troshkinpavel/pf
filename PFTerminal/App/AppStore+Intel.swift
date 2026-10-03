import PFCore
import PFCoreUI
import Foundation

// intel.json lifecycle: load at launch (with the one-time 0.6 → 0.7 migration), save on
// every change. A file from a newer PF is shown read-only and never overwritten.
extension AppStore {
    func loadIntel() {
        do {
            var d = try intelStore.load() ?? IntelDocument()
            let before = d
            d.migrateNotifications(alertThreshold: settings.alertThreshold, depegAlerts: settings.depegAlerts, now: Date())
            // A coin 0.6 already notified about (still off peg) shouldn't notify again after the upgrade.
            if before.alerts.isEmpty, !(defaults.stringArray(forKey: "pf.depeg.alerted") ?? []).isEmpty {
                for i in d.alerts.indices where d.alerts[i].kind == .depeg { d.alerts[i].state = .fired; d.alerts[i].firedAt = Date() }
            }
            intel = d
            if d != before { saveIntel() }
        } catch let e as IntelStoreError {
            intelReadOnly = e.description
            intelRetry = e == .unavailable
            if case .unreadable = e { intelReadOnly = nil; intel = IntelDocument(); saveIntel() }
            message = "✗ " + e.description
            diagnostics.record(.ledger, .warning, "intel-load-failed", error: e)
        } catch {
            intelReadOnly = "intel.json could not be read"
        }
    }

    /// After `.unavailable` (file protection while locked): try again, never start empty.
    func retryIntelIfNeeded() {
        guard intelRetry else { return }
        intelRetry = false; intelReadOnly = nil
        loadIntel()
    }

    /// Mutate the intel document and persist it. Refused while read-only.
    @discardableResult
    func updateIntel(_ change: (inout IntelDocument) -> Void) -> Bool {
        guard intelReadOnly == nil else { message = "✗ " + (intelReadOnly ?? "read-only"); return false }
        var d = intel
        change(&d)
        guard d != intel else { return true }
        intel = d
        saveIntel()
        return true
    }

    /// The scenario shown on the Scenarios screen (default: Base, else the first).
    var currentScenario: PortfolioScenario? {
        intel.scenarios.first { $0.id == scenarioID } ?? Scenarios.base(intel)
    }

    func saveIntel() {
        guard intelReadOnly == nil else { return }
        do { try intelStore.save(intel) }
        catch {
            message = "✗ could not save watchlist / alerts / scenarios · \(error.localizedDescription)"
            diagnostics.record(.ledger, .error, "intel-save-failed", error: error)
        }
    }
}
