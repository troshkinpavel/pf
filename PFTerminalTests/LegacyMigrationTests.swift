import Foundation
import Testing
@testable import PFTerminal

struct LegacyMigrationTests {
    struct Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-mig-\(UUID().uuidString)")
        var legacy: URL { root.appendingPathComponent("old/pf") }
        var prefs: URL { root.appendingPathComponent("old/prefs.plist") }
        var new: URL { root.appendingPathComponent("new/pf") }
        let defaults = UserDefaults(suiteName: "pf-mig-\(UUID().uuidString)")!
        var migration: LegacyMigration { LegacyMigration(legacyDir: legacy, legacyPrefs: prefs, newDir: new, defaults: defaults) }

        func write(_ name: String, _ s: String, in dir: URL) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(s.utf8).write(to: dir.appendingPathComponent(name))
        }
        func read(_ name: String) -> String? {
            (try? Data(contentsOf: new.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    static let ledger = String(decoding: try! PortfolioDocument.fresh().encoded(), as: UTF8.self)

    @Test func copiesLedgerBackupsCacheAndPrefsExactly() throws {
        let e = Env()
        try e.write("portfolio.json", Self.ledger, in: e.legacy)
        try e.write("portfolio.v1-backup.json", "{\"schemaVersion\":1}", in: e.legacy)
        try e.write("market.store", "sqlite", in: e.legacy)
        try e.write("sync-state.json", "{}", in: e.legacy)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["pf.context.v1": "all", "pf.settings.v1": Data([1, 2]), "NSWindow Frame x": "1"], format: .binary, options: 0)
        try plist.write(to: e.prefs)
        e.defaults.set("keep", forKey: "pf.context.v1")   // newer value in the new domain wins

        #expect(e.migration.run() == .migrated(files: 3, preferences: 1))
        #expect(e.read("portfolio.json") == Self.ledger)                 // byte-identical: ids and timestamps preserved
        #expect(e.read("portfolio.v1-backup.json") != nil && e.read("market.store") == "sqlite")
        #expect(e.read("sync-state.json") == nil)                         // provisional container's state is not carried over
        #expect(e.defaults.string(forKey: "pf.context.v1") == "keep")
        #expect(e.defaults.data(forKey: "pf.settings.v1") == Data([1, 2]))
        #expect(e.defaults.object(forKey: "NSWindow Frame x") == nil)
        #expect(FileManager.default.fileExists(atPath: e.legacy.appendingPathComponent("portfolio.json").path))   // original untouched
        #expect(try PortfolioStore(directory: e.new).load() != nil)
    }

    @Test func idempotent() throws {
        let e = Env()
        try e.write("portfolio.json", Self.ledger, in: e.legacy)
        #expect(e.migration.run() == .migrated(files: 1, preferences: 0))
        try e.write("portfolio.json", "changed later in the new app", in: e.new)
        #expect(e.migration.run() == .alreadyDone)
        #expect(e.read("portfolio.json") == "changed later in the new app")
    }

    @Test func neverOverwritesExistingData() throws {
        let e = Env()
        try e.write("portfolio.json", Self.ledger, in: e.legacy)
        try e.write("portfolio.json", "newer", in: e.new)
        #expect(e.migration.run() == .skippedNewerData)
        #expect(e.read("portfolio.json") == "newer")
        #expect(e.migration.run() == .alreadyDone)
    }

    @Test func nothingToMigrate() throws {
        let e = Env()
        #expect(e.migration.run() == .noLegacyData)
        try e.write("market.store", "x", in: e.legacy)   // cache alone is not a portfolio
        #expect(e.migration.run() == .noLegacyData)
        #expect(e.read("market.store") == nil)
    }
}
