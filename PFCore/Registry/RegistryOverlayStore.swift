import Foundation

/// Rare, validated registry overlay updates. The bundled snapshot is always the baseline; an
/// overlay only patches it, is cached locally, and is ignored whenever it doesn't validate.
///
/// Policy: at most one check every `minInterval` (5 days); never on the startup path; any
/// failure keeps the current state. 0.5.0 ships with no `remoteURL` (no backend exists), so
/// no request is ever made until one is configured.
public final class RegistryOverlayStore: @unchecked Sendable {
    public static let minInterval: TimeInterval = 5 * 86400
    public static let maxBytes = 2_000_000
    /// Where a published overlay would live (e.g. a file in this repository). nil = disabled.
    public static let remoteURL: URL? = nil

    public static let `default` = RegistryOverlayStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pf/registry", isDirectory: true))

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var overlayURL: URL { directory.appendingPathComponent("overlay.json") }
    private var stampURL: URL { directory.appendingPathComponent("last-check") }

    public var lastCheck: Date? {
        (try? String(contentsOf: stampURL, encoding: .utf8)).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    public func shouldCheck(now: Date = Date()) -> Bool {
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= Self.minInterval
    }

    /// The cached overlay, if it still validates against the bundled snapshot.
    public func cachedOverlay(base: RegistrySnapshot? = AssetRegistry.bundledSnapshot()) -> RegistryOverlay? {
        guard let data = try? Data(contentsOf: overlayURL), let base else { return nil }
        return Self.decodeValid(data, base: base)
    }

    static func decodeValid(_ data: Data, base: RegistrySnapshot) -> RegistryOverlay? {
        guard data.count <= maxBytes, let o = try? JSONDecoder().decode(RegistryOverlay.self, from: data),
              (try? o.validate(against: base)) != nil else { return nil }
        return o
    }

    public enum Outcome: Equatable { case skipped, updated(String), rejected, failed }

    /// One check, only when due. Takes effect on next launch (the registry is immutable).
    @discardableResult
    public func refreshIfDue(fetch: () async throws -> Data, base: RegistrySnapshot, now: Date = Date()) async -> Outcome {
        guard shouldCheck(now: now) else { return .skipped }
        stamp(now)
        guard let data = try? await fetch() else { return .failed }
        guard let o = Self.decodeValid(data, base: base) else { return .rejected }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: overlayURL, options: .atomic)) != nil else { return .failed }
        return .updated(o.overlayVersion)
    }

    private func stamp(_ now: Date) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(now.timeIntervalSince1970).write(to: stampURL, atomically: true, encoding: .utf8)
    }
}
