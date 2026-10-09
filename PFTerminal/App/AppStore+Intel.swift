import PFCore
import PFCoreUI
import Foundation

// Intel data lifecycle: alerts.json (rules, log — usable while locked) + intel.json (watchlist,
// scenarios — strict protection). Loaded at launch with the one-time 0.6 → 0.7 migration,
// saved on every change. Newer files are read-only and never overwritten.
extension AppStore {
    /// What lives in intel.json (written only when it changed: alert passes never touch it).
    struct IntelPrivate: Equatable { var watchlist: [WatchItem]; var scenarios: [PortfolioScenario] }
    var intelPrivate: IntelPrivate { IntelPrivate(watchlist: intel.watchlist, scenarios: intel.scenarios) }

    func loadIntel() {
        // Which files exist before anything is written: a domain whose file is missing or gets set
        // aside was replaced, not emptied by the user (see `intelVerifyLoad`).
        let fm = FileManager.default
        let hadRuntime = fm.fileExists(atPath: intelStore.runtimeURL.path), hadPrivate = fm.fileExists(atPath: intelStore.url.path)
        do {
            let loaded = try intelStore.load()
            var unverified = Self.intelKinds(setAside: loaded?.setAside ?? [])
            // A schema 1 intel.json holds the alerts too.
            if !hadRuntime && !(hadPrivate && loaded?.needsSplit == true) { unverified.insert(.alert) }
            if !hadPrivate { unverified.formUnion([.watch, .scenario]) }
            intelLoadUnverified.formUnion(unverified)
            var d = loaded?.doc ?? IntelDocument()
            intelPrivateDeferred = loaded?.privateDeferred ?? false
            let before = d
            d.migrateNotifications(alertThreshold: settings.alertThreshold, depegAlerts: settings.depegAlerts, now: Date())
            // A coin 0.6 already notified about (still off peg) shouldn't notify again after the upgrade.
            if before.alerts.isEmpty, !(defaults.stringArray(forKey: "pf.depeg.alerted") ?? []).isEmpty {
                for i in d.alerts.indices where d.alerts[i].kind == .depeg { d.alerts[i].state = .fired; d.alerts[i].firedAt = Date() }
            }
            intel = d
            // A schema 1 file is split once; otherwise intel.json is rewritten only when it changes.
            savedIntelPrivate = loaded?.needsSplit == true ? nil : intelPrivate
            if let aside = loaded?.setAside, !aside.isEmpty {
                message = "✗ unreadable intel data set aside (" + aside.joined(separator: ", ") + ") · the rest loaded"
                diagnostics.record(.ledger, .warning, "intel-set-aside")
            }
            if d != before || loaded?.needsSplit == true { saveIntel() }
            if intelPrivateDeferred { enterProtectedWait("intel-private-deferred") }
            intelVerifyLoad()
        } catch let e as IntelStoreError {
            intelReadOnly = e.description
            intelRetry = e == .unavailable
            message = "✗ " + e.description
            diagnostics.record(.ledger, .warning, "intel-load-failed", error: e)
        } catch {
            intelReadOnly = "intel data could not be read"
        }
    }

    /// After `.unavailable` (file protection while locked): try again, never start empty.
    func retryIntelIfNeeded() {
        guard intelRetry else { return }
        intelRetry = false; intelReadOnly = nil
        loadIntel()
    }

    /// On unlock: read the watchlist and scenarios that were locked at launch (the rules in
    /// memory stay, they may have fired meanwhile), and write a private part that waited.
    /// False while still unavailable.
    @discardableResult
    func resumeIntelPrivate() -> Bool {
        if intelPrivateDeferred {
            guard let l = try? intelStore.load(), !l.privateDeferred else { return false }
            // intel.json turned out unreadable (set aside): its empty placeholder is not a delete-all.
            intelLoadUnverified.formUnion(Self.intelKinds(setAside: l.setAside))
            intelVerifyLoad()
            intel.watchlist = l.doc.watchlist
            intel.scenarios = l.doc.scenarios
            intelPrivateDeferred = false
            savedIntelPrivate = intelPrivate
        }
        if intelPrivatePending {
            saveIntel()
            if intelPrivatePending { return false }
        }
        return true
    }

    /// Mutate the intel document and persist it. Refused while read-only, and for the
    /// watchlist / scenarios while they couldn't be read yet (never overwritten with placeholders).
    @discardableResult
    func updateIntel(_ change: (inout IntelDocument) -> Void) -> Bool {
        guard intelReadOnly == nil else { message = "✗ " + (intelReadOnly ?? "read-only"); return false }
        var d = intel
        change(&d)
        guard d != intel else { return true }
        if intelPrivateDeferred, d.watchlist != intel.watchlist || d.scenarios != intel.scenarios {
            message = "protected data unavailable — waiting for unlock"
            return false
        }
        intel = d
        saveIntel()
        return true
    }

    /// The scenario shown on the Scenarios screen (default: Base, else the first).
    var currentScenario: PortfolioScenario? {
        intel.scenarios.first { $0.id == scenarioID } ?? Scenarios.base(intel)
    }

    /// Kinds whose file was set aside as unreadable ("alerts.unreadable-…", "intel.unreadable-…").
    static func intelKinds(setAside: [String]) -> Set<SyncKind> {
        var k = Set<SyncKind>()
        if setAside.contains(where: { $0.hasPrefix("alerts.") }) { k.insert(.alert) }
        if setAside.contains(where: { $0.hasPrefix("intel.") }) { k.formUnion([.watch, .scenario]) }
        return k
    }

    /// Intel sync tells an intentional empty list (a delete-all: tombstones) from data that was
    /// replaced (missing or unreadable file: rebase and fetch iCloud's records back). Runs once the
    /// sync state is loaded; only kinds the state knows live records of are affected.
    func intelVerifyLoad() {
        guard !intelLoadUnverified.isEmpty, intelSyncState.mode == .iCloud else { return }
        let kinds = intelLoadUnverified.intersection(IntelSyncEngine.knownLiveKinds(intelSyncState))
        intelLoadUnverified = []
        guard !kinds.isEmpty else { return }
        IntelSyncEngine.rebase(&intelSyncState, kinds: kinds)
        diagnostics.record(.sync, .warning, "intel-rebase")
    }

    func saveIntel() {
        guard intelReadOnly == nil else { return }
        defer { if !intelSyncApplying { scheduleIntelSync() } }
        do { try intelStore.saveRuntime(intel) }
        catch {
            message = "✗ could not save alerts · \(error.localizedDescription)"
            diagnostics.record(.ledger, .error, "intel-save-failed", error: error)
        }
        guard !intelPrivateDeferred, intelPrivate != savedIntelPrivate else { return }
        do {
            try intelStore.savePrivate(intel)
            savedIntelPrivate = intelPrivate
            intelPrivatePending = false
        } catch where ProtectedData.isUnavailable(error) {
            intelPrivatePending = true
            enterProtectedWait("intel-private-save-deferred")
        } catch {
            message = "✗ could not save watchlist / scenarios · \(error.localizedDescription)"
            diagnostics.record(.ledger, .error, "intel-save-failed", error: error)
        }
    }
}
