import Foundation

/// Identifiers PF Terminal used before the canonical `io.github.troskinpavel.pf` namespace.
/// Used ONLY to find and migrate data from that earlier identity — never for new data.
enum LegacyIdentifiers {
    static let bundleID = "io.github.pfterminal.PFTerminal"
    static let keychainService = "io.github.pfterminal"
    // For reference: widgets were `io.github.pfterminal.PFTerminal.PFWidgets`, the App Group
    // `<TEAM>.io.github.pfterminal` (widget snapshots only — regenerated, not migrated), and the
    // provisional CloudKit container `iCloud.io.github.pfterminal` (never registered, never used).

    /// The real home directory (inside the sandbox, NSHomeDirectory() is the container).
    static var realHome: URL {
        URL(fileURLWithPath: getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory(), isDirectory: true)
    }
    static var containerData: URL { realHome.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true) }
    static var dataDirectory: URL { containerData.appendingPathComponent("Application Support/pf", isDirectory: true) }
    static var preferences: URL { containerData.appendingPathComponent("Preferences/\(bundleID).plist") }
}

/// One-time copy of the previous identity's data into this app's container.
///
/// - Copies ledger + backups (`portfolio*.json`) and the market cache byte-for-byte, so every
///   portfolio id, transaction id and timestamp is preserved exactly.
/// - Never overwrites: if this container already has a ledger, nothing is copied.
/// - Copies `pf.*` preferences only where the new domain has no value.
/// - Leaves the old container untouched (recovery path) and records what it did in
///   `legacy-migration.json`; once that marker exists it never runs again.
/// - `sync-state.json` is not copied: it belonged to the provisional (never registered) container.
struct LegacyMigration {
    enum Outcome: Equatable {
        case alreadyDone, noLegacyData
        case skippedNewerData          // this container already had a ledger
        case migrated(files: Int, preferences: Int)
        case legacyUnreadable(String)  // exists but not accessible (sandbox/TCC); nothing changed
    }

    var legacyDir: URL
    var legacyPrefs: URL
    var newDir: URL
    var defaults: UserDefaults
    var fm = FileManager.default

    static let markerName = "legacy-migration.json"

    static func live(newDir: URL, defaults: UserDefaults) -> LegacyMigration {
        LegacyMigration(legacyDir: LegacyIdentifiers.dataDirectory, legacyPrefs: LegacyIdentifiers.preferences, newDir: newDir, defaults: defaults)
    }

    func run(now: Date = Date()) -> Outcome {
        let marker = newDir.appendingPathComponent(Self.markerName)
        if fm.fileExists(atPath: marker.path) { return .alreadyDone }

        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: legacyDir.path) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            return .noLegacyData
        } catch {
            return fm.fileExists(atPath: legacyDir.path) ? .legacyUnreadable(error.localizedDescription) : .noLegacyData
        }
        guard names.contains("portfolio.json") else { return .noLegacyData }

        var outcome: Outcome
        var copied: [String] = []
        if fm.fileExists(atPath: newDir.appendingPathComponent("portfolio.json").path) {
            outcome = .skippedNewerData
        } else {
            let wanted = names.filter { ($0.hasPrefix("portfolio") && $0.hasSuffix(".json")) || $0.hasPrefix("market.store") }.sorted()
            do {
                try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
                // Ledger last: its presence is what "migrated" means if a copy is interrupted.
                for n in wanted.filter({ $0 != "portfolio.json" }) + ["portfolio.json"] {
                    let dst = newDir.appendingPathComponent(n)
                    if fm.fileExists(atPath: dst.path) { continue }
                    try fm.copyItem(at: legacyDir.appendingPathComponent(n), to: dst)
                    copied.append(n)
                }
            } catch {
                // Partial copies of side files are harmless; retried next launch (no marker yet).
                if let i = copied.firstIndex(of: "portfolio.json") { copied.remove(at: i) }
                return .legacyUnreadable(error.localizedDescription)
            }
            outcome = .migrated(files: copied.count, preferences: copyPreferences())
        }

        let record: [String: Any] = ["from": LegacyIdentifiers.bundleID, "source": legacyDir.path,
                                     "date": ISO8601DateFormatter().string(from: now), "copied": copied,
                                     "result": "\(outcome)"]
        if let d = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: marker, options: .atomic)
        }
        return outcome
    }

    private func copyPreferences() -> Int {
        guard let data = try? Data(contentsOf: legacyPrefs),
              let old = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return 0 }
        var n = 0
        for (k, v) in old where k.hasPrefix("pf.") && defaults.object(forKey: k) == nil {
            defaults.set(v, forKey: k)
            n += 1
        }
        return n
    }
}
