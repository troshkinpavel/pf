#if DEBUG
import PFCore
import PFCoreUI
import AppKit
import WidgetKit

/// DEBUG only: `--widget-check` writes this store's widget snapshots through the normal path,
/// reads them back from the App Group, lists placed PF widgets and asks WidgetKit to reload them.
/// Prints counts and statuses only — no amounts or names.
enum WidgetCheck {
    @MainActor
    static func runIfRequested(_ store: AppStore) {
        guard ProcessInfo.processInfo.arguments.contains("--widget-check") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)   // let quotes arrive
            print("app group (Info.plist):", WidgetSnapshotStore.appGroup ?? "none")
            print("container:", WidgetSnapshotStore.containerURL == nil ? "unavailable" : "resolved")
            store.lastWidgetKey = ""
            store.writeWidgetSnapshot()
            print("write status:", store.widgetStatus)
            let index = WidgetSnapshotStore.readIndex()
            print("index contexts:", index.count, "· expected", store.doc.livePortfolios.count + 1)
            for ref in index {
                let s = WidgetSnapshotStore.read(from: WidgetSnapshotStore.url(for: ref.id))
                print("read back \(ref.id == "all" ? "ALL" : "portfolio"):", s == nil ? "MISSING" : "ok · \(s!.positions.count) positions · hasValue=\(s!.portfolioValue != nil)")
            }
            let configs: [WidgetInfo] = await withCheckedContinuation { c in
                WidgetCenter.shared.getCurrentConfigurations { c.resume(returning: (try? $0.get()) ?? []) }
            }
            print("placed PF widgets:", configs.filter { $0.kind == WidgetSnapshotStore.widgetKind }.map { "\($0.family)" })
            WidgetCenter.shared.reloadAllTimelines()
            print("WIDGET CHECK DONE")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            exit(0)
        }
    }
}
#endif
