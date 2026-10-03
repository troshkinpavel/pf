import PFCore
import PFCoreUI
import AppKit
import SwiftUI
import UserNotifications

@main
struct PFTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: AppStore

    init() {
        let args = ProcessInfo.processInfo.arguments
        var o = AppStore.Options()
        o.mockMarket = args.contains("--mock-market")
        o.seedDemo = args.contains("--demo")
        // Unit tests run inside this app: the host must not open the user's ledger or sync it.
        let hostedTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        AppDelegate.isTestHost = hostedTests && !args.contains("--ui-testing")
        if args.contains("--ui-testing") || hostedTests {
            // Isolated, throwaway state: never touches the user's portfolio or preferences.
            o.inMemory = true
            o.directory = FileManager.default.temporaryDirectory.appendingPathComponent("pf-uitest-\(UUID().uuidString)")
            let d = UserDefaults(suiteName: "pf.uitest")!
            d.removePersistentDomain(forName: "pf.uitest")
            o.defaults = d
            o.publishWidgets = false
        }
        let s = AppStore(o)
        #if DEBUG
        // `--theme light|midnight|graphite|system`: snapshots and manual checks of each theme.
        if let i = args.firstIndex(of: "--theme"), i + 1 < args.count, let t = AppTheme(rawValue: args[i + 1]) { s.settings.theme = t }
        #endif
        _store = State(initialValue: s)
        AppDelegate.store = s
    }

    var body: some Scene {
        Window("PF Terminal", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1120, minHeight: 720)
                .onOpenURL { store.handleDeepLink($0) }
        }
        .handlesExternalEvents(matching: ["pfterminal"])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(store: store) }

        MenuBarExtra {
            MenuBarPopover().environment(store)
        } label: {
            TrayLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar label. It exists from launch, so it also makes sure the main window opens at launch:
/// SwiftUI restores a `Window` scene as closed if it was closed when the app last quit (PF keeps
/// running in the menu bar), which would otherwise leave a launch with no window at all.
private struct TrayLabel: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    @MainActor private static var launched = false

    var body: some View {
        Text(store.trayText())
            .task {
                store.openMainWindowAction = { openWindow(id: "main") }   // used by presentMainWindow()
                guard !Self.launched else { return }
                Self.launched = true
                try? await Task.sleep(nanoseconds: 300_000_000)   // let window restoration finish
                if store.mainWindow?.isVisible != true { store.presentMainWindow() }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var store: AppStore?
    @MainActor static var isTestHost = false
    private var monitor: Any?

    @MainActor func applicationDidFinishLaunching(_ n: Notification) {
        if AppDelegate.isTestHost { return }   // isolated store, nothing started (no network, no sync)
        AppDelegate.store?.start()
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        if let s = AppDelegate.store { DebugSnapshots.runIfRequested(s) }
        CloudKitSelfTest.runIfRequested()
        CloudKitSelfTest.listZoneIfRequested()
        SyncE2E.runIfRequested()
        if let s = AppDelegate.store { SyncE2E.renderConflicts(s) }
        if let s = AppDelegate.store { WidgetCheck.runIfRequested(s) }
        #endif
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { (AppDelegate.store?.handleKey(e) ?? false) ? nil : e }
        }
    }

    /// Closing the window keeps the menu bar companion running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click / launching the app again from Finder or Spotlight while it runs.
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppDelegate.store?.presentMainWindow()
        return false
    }

    /// Clicking a PF notification opens the main window (also from menu-bar-only state).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppDelegate.store?.presentMainWindow() }
    }
}

struct AppCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { show(); store.go(.settings); store.checkForUpdates() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { show(); store.go(.settings) }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Transaction") { show(); store.openTx() }.keyboardShortcut("n")
            Divider()
            Button("Import into Current Portfolio…") { show(); store.importIntoCurrentPortfolio() }
            Button("Import Backup (Replace)…") { show(); store.importBackup() }
            Button("Export Backup…") { store.exportBackup() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Restore Recovery Snapshot…") { show(); store.openRestore() }
            Button("Copy Diagnostic Report") { store.copyDiagnosticReport() }
        }
        CommandMenu("Go") {
            Button("Portfolio") { show(); store.goTab(0) }.keyboardShortcut("1")
            Button("Changes") { show(); store.goTab(1) }.keyboardShortcut("2")
            Button("Analytics") { show(); store.goTab(2) }.keyboardShortcut("3")
            Button("Watchlist") { show(); store.goTab(3) }.keyboardShortcut("4")
            Divider()
            Button("What Changed  g c") { show(); store.leaderKey("c") }
            Button("Movers  g m") { show(); store.leaderKey("m") }
            Button("Benchmark  g b") { show(); store.leaderKey("b") }
            Button("Alerts  g a") { show(); store.go(.alerts) }
            Button("Scenarios  g s") { show(); store.go(.scenarios) }
            Button("Manage Portfolios  g p") { show(); store.go(.portfolios) }
            Button("Keyboard Shortcuts") { show(); store.keysOverlay = true }.keyboardShortcut("/", modifiers: [.command, .shift])
            Divider()
            Button("Command Palette") { show(); store.openPalette() }.keyboardShortcut("k")
            Button("Switch Portfolio…") { show(); store.openSwitcher() }.keyboardShortcut("p")
            Button("Quick Share") { show(); store.quickShare = true }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Refresh Market Data") { Task { await store.refresh(auto: false) } }.keyboardShortcut("r")
        }
    }

    private func show() { store.presentMainWindow() }
}
