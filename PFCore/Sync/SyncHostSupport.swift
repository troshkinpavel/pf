import Foundation

// Host-side helpers every platform's SyncHost uses the same way: the device-local state file,
// what a failed cycle means for the status, and user-facing error text.

/// `sync-state.json`, next to `portfolio.json`. Device-local, never synced.
public enum SyncStateFile {
    public static func url(in dir: URL) -> URL { dir.appendingPathComponent("sync-state.json") }

    public static func load(from dir: URL) -> SyncState? {
        guard let d = try? Data(contentsOf: url(in: dir)) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: d)
    }

    public static func save(_ s: SyncState, to dir: URL) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: url(in: dir), options: .atomic)
    }
}

extension SyncStatus {
    /// Status after a failed cycle. `turnsSyncOff`: the account changed or the PF zone was deleted
    /// in iCloud settings; sync must stop instead of pushing data anywhere.
    public static func after(_ error: Error) -> (status: SyncStatus, turnsSyncOff: Bool) {
        switch error as? SyncStoreError {
        case .offline?: (.offline, false)
        case .notAuthenticated?: (.accountUnavailable, false)
        case .notConfigured?: (.iCloudUnavailable, false)
        case .accountChanged?: (.accountUnavailable, true)
        case .cloudDataDeleted?: (.error("iCloud data was deleted · sync turned off"), true)
        case .quotaExceeded?: (.error("iCloud storage full"), false)
        case let .unavailable(m)?: (.error(String(m.prefix(60))), false)
        case nil: (.error(String(error.localizedDescription.prefix(60))), false)
        }
    }

    /// Changes stay queued locally in these states.
    public var isWaiting: Bool {
        switch self { case .offline, .accountUnavailable, .iCloudUnavailable, .error: true; default: false }
    }
}

extension SyncStoreError {
    /// One-line explanation. `signInHint` names where the platform's Apple Account settings are.
    public static func describe(_ error: Error, signInHint: String) -> String {
        switch error as? SyncStoreError {
        case .offline?: "iCloud can't be reached · check the network and try again"
        case .notAuthenticated?: "no iCloud account · sign in via \(signInHint), then try again"
        case .notConfigured?: "this build isn't set up for iCloud (CloudKit container not provisioned)"
        case .quotaExceeded?: "iCloud storage is full"
        case .accountChanged?: "the iCloud account changed"
        case .cloudDataDeleted?: "PF data was deleted from iCloud"
        case let .unavailable(m)?: m
        case nil: error.localizedDescription
        }
    }
}
