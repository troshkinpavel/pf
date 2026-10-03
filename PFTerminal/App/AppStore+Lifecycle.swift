import PFCore
import PFCoreUI
import AppKit
import SwiftUI

// Dock / menu bar lifecycle.
//
//   main window open        → regular app: Dock icon + menu bar item
//   last main window closed → keeps running as a menu bar item; Dock icon removed (.accessory)
//                             unless Settings → GENERAL → keep in Dock is on
//   any reopen path         → presentMainWindow(): .regular, open/focus the single main window, activate
//   ⌘Q                      → quits
//
// Reopen paths: menu bar "open", app menu commands, Dock/Finder reopen
// (applicationShouldHandleReopen), pfterminal:// deep links and widget taps (onOpenURL),
// notification clicks (UNUserNotificationCenter delegate). As a safety net, the main window
// becoming key always restores .regular.
extension AppStore {
    /// The one way to bring PF Terminal to the front.
    func presentMainWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        openMainWindowAction?()                       // `Window` scene: opens it, or focuses the existing one
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called once the main window exists (WindowAccessor).
    func attachMainWindow(_ w: NSWindow) {
        guard mainWindow !== w else { return }
        mainWindow = w
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        windowObservers = [
            nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mainWindowClosed() }
            },
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) } }
            },
        ]
    }

    private func mainWindowClosed() {
        // After the close completes: leave the Dock only if no other normal window is still open.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.settings.keepInDock else { return }
            let others = NSApp.windows.contains { $0 !== self.mainWindow && $0.isVisible && $0.canBecomeMain }
            if !others, self.mainWindow?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// Settings toggle: applies at once when the window is already closed.
    func keepInDockChanged() {
        if settings.keepInDock { if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) } }
        else if mainWindow?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: updates

    var installedVersion: InstalledVersion { .current }

    /// Manual check only. Never downloads or installs anything.
    func checkForUpdates() {
        guard updateState != .checking else { return }
        updateState = .checking
        let installed = installedVersion.marketing, checker = updateChecker
        Task {
            updateState = await Updates.check(installed: installed, using: checker)
        }
    }

    /// Opens the canonical GitHub release page in the browser; the user downloads from there.
    func openAvailableUpdate() {
        guard case let .updateAvailable(u) = updateState else { return }
        NSWorkspace.shared.open(u.releaseURL)
    }

    var updateStatusLabel: String {
        switch updateState {
        case .idle: "[ check for updates… ]"
        case .checking: "checking…"
        case .upToDate: "up to date · [ check again ]"
        case let .updateAvailable(u): "\(u.version) available · [ open release ]"
        case let .failed(m): "✗ \(m) · [ retry ]"
        }
    }
}

// MARK: - Appearance

extension AppStore {
    /// Resolves the theme setting to a palette and applies it everywhere at once: tokens, the
    /// window and menu chrome (NSApp.appearance, also used by alerts and menus), and `themeID`,
    /// which re-creates the SwiftUI trees so every view reads the new tokens. No restart.
    func applyTheme() {
        let p = settings.theme.palette(systemIsDark: systemIsDark)
        Theme.palette = p
        NSApp?.appearance = NSAppearance(named: p.isLight ? .aqua : .darkAqua)
        themeID = p.name
    }

    nonisolated static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// macOS light/dark changes, for `theme = system`. Read from the global setting, not
    /// NSApp.effectiveAppearance, which follows the appearance PF itself sets.
    func startAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsDark = Self.readSystemIsDark() }
        }
    }

    var colorScheme: ColorScheme { Theme.isLight ? .light : .dark }
}
