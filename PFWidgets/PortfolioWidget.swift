import PFCore
import PFCoreUI
import SwiftUI
import WidgetKit

@main
struct PFWidgetsBundle: WidgetBundle {
    var body: some Widget { PortfolioWidget() }
}

struct PortfolioWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSnapshotStore.widgetKind, intent: PortfolioWidgetIntent.self, provider: PortfolioProvider()) { entry in
            PortfolioWidgetView(entry: entry)
                .containerBackground(Theme.bg, for: .widget)
        }
        .configurationDisplayName("PF Terminal")
        .description("Portfolio value, 24h performance and movers. Data comes from the PF Terminal app on this Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
