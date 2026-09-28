import PFCore
import PFCoreUI
import AppIntents
import OSLog
import SwiftUI
import WidgetKit

// Widget configuration (App Intents) and timeline provider.

// MARK: - Configuration (App Intents)

// Intent enums: same type names and cases as before the package split, so widgets that users
// already configured keep their settings.
enum WidgetDisplay: String, AppEnum { case valueAnd24h, performanceOnly, valueOnly }
enum WidgetValuePrivacy: String, AppEnum { case visible, hidden }
enum WidgetMoversKind: String, AppEnum { case gainers, impact }

extension WidgetDisplay {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Display"
    static var caseDisplayRepresentations: [WidgetDisplay: DisplayRepresentation] = [
        .valueAnd24h: "Portfolio value + 24h", .performanceOnly: "24h performance only", .valueOnly: "Portfolio value only",
    ]
}

extension WidgetValuePrivacy {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Privacy"
    static var caseDisplayRepresentations: [WidgetValuePrivacy: DisplayRepresentation] = [
        .visible: "Value visible", .hidden: "Hide portfolio value",
    ]
}

extension WidgetMoversKind {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Movers"
    static var caseDisplayRepresentations: [WidgetMoversKind: DisplayRepresentation] = [
        .gainers: "Top gainers", .impact: "Biggest portfolio impact",
    ]
}

struct PortfolioWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "PF Portfolio"
    static var description = IntentDescription("Choose what the PF Terminal widget shows.")

    @Parameter(title: "Display", default: .valueAnd24h) var display: WidgetDisplay
    @Parameter(title: "Privacy", default: .visible) var privacy: WidgetValuePrivacy
    @Parameter(title: "Movers", default: .gainers) var movers: WidgetMoversKind
    /// Empty = follow the app's active portfolio.
    @Parameter(title: "Portfolio") var portfolio: WidgetPortfolioEntity?
}

/// A portfolio (or ALL) published by the app in widget-portfolios.json. Identity is the
/// portfolio UUID, so renames never break a configured widget.
struct WidgetPortfolioEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Portfolio"
    static var defaultQuery = WidgetPortfolioQuery()
    let id: String
    let name: String
    let glyph: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(glyph) \(name)") }
}

struct WidgetPortfolioQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetPortfolioEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetPortfolioEntity] {
        WidgetSnapshotStore.readIndex().map { WidgetPortfolioEntity(id: $0.id, name: $0.name, glyph: $0.glyph) }
    }
}

extension WidgetOptions {
    init(_ i: PortfolioWidgetIntent) {
        self.init(display: WidgetDisplayOption(rawValue: i.display.rawValue) ?? .valueAnd24h,
                  privacy: WidgetValueOption(rawValue: i.privacy.rawValue) ?? .visible,
                  movers: WidgetMoversOption(rawValue: i.movers.rawValue) ?? .gainers)
    }
}

struct PortfolioProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: .now, snapshot: .previewPositive(now: .now), options: WidgetOptions())
    }

    /// A pinned portfolio reads its own file; a removed/archived one falls back to "follow active".
    private func read(_ c: PortfolioWidgetIntent) -> WidgetPortfolioSnapshot? {
        let s = (c.portfolio?.id).flatMap { WidgetSnapshotStore.read(from: WidgetSnapshotStore.url(for: $0)) }
            ?? WidgetSnapshotStore.read(from: WidgetSnapshotStore.defaultURL)
        // Diagnostics only: whether the App Group snapshot was readable. Never amounts or names.
        Self.log.info("snapshot read: \(s == nil ? "none" : "ok", privacy: .public) group=\(WidgetSnapshotStore.containerURL == nil ? "unavailable" : "ok", privacy: .public) context=\(s?.contextID ?? "-", privacy: .private) positions=\(s?.positions.count ?? 0, privacy: .public)")
        return s
    }
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pf.widgets", category: "snapshot")

    func snapshot(for configuration: PortfolioWidgetIntent, in context: Context) async -> PortfolioEntry {
        let stored = read(configuration)
        // The gallery preview shows sample data only when the app has not written a snapshot yet.
        return PortfolioEntry(date: .now, snapshot: stored ?? (context.isPreview ? .previewPositive(now: .now) : nil), options: WidgetOptions(configuration))
    }

    /// The app reloads timelines whenever it writes a new snapshot; these entries only advance the
    /// "upd 5m" age label while nothing new arrives. WidgetKit decides actual scheduling.
    func timeline(for configuration: PortfolioWidgetIntent, in context: Context) async -> Timeline<PortfolioEntry> {
        let snap = read(configuration)
        let now = Date(), opts = WidgetOptions(configuration)
        let entries = (0...12).map { PortfolioEntry(date: now.addingTimeInterval(Double($0) * 300), snapshot: snap, options: opts) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600)))
    }
}
