import PFCore
import PFCoreUI
import SwiftUI
import WidgetKit

// Previews: deterministic samples (Shared/Widget/WidgetSamples.swift), no live data.

private func entry(_ make: (Date) -> WidgetPortfolioSnapshot?, _ o: WidgetOptions = WidgetOptions()) -> PortfolioEntry {
    let now = Date()
    return PortfolioEntry(date: now, snapshot: make(now), options: o)
}

private let hideValueImpact: WidgetOptions = { var o = WidgetOptions(); o.hideValue = true; o.movers = .impact; return o }()

#Preview("Small", as: .systemSmall) { PortfolioWidget() } timeline: {
    entry(WidgetPortfolioSnapshot.previewPositive); entry(WidgetPortfolioSnapshot.previewNegative); entry(WidgetPortfolioSnapshot.previewPrivacy)
    entry(WidgetPortfolioSnapshot.previewStale); entry(WidgetPortfolioSnapshot.previewEmpty); entry { _ in nil }
}
#Preview("Medium", as: .systemMedium) { PortfolioWidget() } timeline: {
    entry(WidgetPortfolioSnapshot.previewPositive); entry(WidgetPortfolioSnapshot.previewNegative); entry(WidgetPortfolioSnapshot.previewPrivacy)
    entry(WidgetPortfolioSnapshot.previewStale); entry(WidgetPortfolioSnapshot.previewEmpty); entry(WidgetPortfolioSnapshot.previewPositive, hideValueImpact)
}
#Preview("Large", as: .systemLarge) { PortfolioWidget() } timeline: {
    entry(WidgetPortfolioSnapshot.previewPositive); entry(WidgetPortfolioSnapshot.previewNegative); entry(WidgetPortfolioSnapshot.previewPrivacy)
    entry(WidgetPortfolioSnapshot.previewStale); entry(WidgetPortfolioSnapshot.previewEmpty)
}
