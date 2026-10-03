import PFCore
import PFCoreUI
import AppKit
import SwiftUI

/// Window chrome: title bar with breadcrumbs + status, the active screen, overlays, tmux-style status bar.
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            ZStack(alignment: .top) {
                Group {
                    if store.ledgerLoadDeferred { ProtectedDataWaitView() }
                    else if !store.hasPortfolio { OnboardingView() }
                    else if store.summary.isEmpty && store.summary.closed.isEmpty && [.overview, .asset, .target, .movers, .analytics, .changes, .benchmark].contains(store.screen) {
                        EmptyPortfolioView()
                    } else {
                        switch store.screen {
                        case .overview: OverviewView()
                        case .asset: AssetDetailView()
                        case .target: TargetView()
                        case .movers: MoversView()
                        case .analytics: AnalyticsView()
                        case .settings: SettingsView()
                        case .share: ShareView()
                        case .portfolios: PortfoliosView()
                        case .changes: ChangesView()
                        case .benchmark: AnalyticsView(benchmark: true)
                        case .watch: WatchView()
                        case .alerts: AlertsView()
                        case .scenarios: ScenariosView()
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if store.quickShare { Scrim { store.quickShare = false } content: { QuickShareView() } }
                if store.tx != nil { Scrim(top: 40, dismiss: nil) { TransactionSheet() } }
                if store.alertSetup != nil { Scrim(top: 40) { store.alertSetup = nil } content: { AlertSetupSheet() } }
                if store.watchDraft != nil { Scrim(top: 40) { store.watchDraft = nil } content: { WatchSheet() } }
                if store.palette != nil { Scrim(top: 40) { store.palette = nil } content: { CommandPaletteView() } }
                if store.sourcePicker != nil { Scrim(top: 40) { store.sourcePicker = nil } content: { SourcePickerView() } }
                if store.switcher != nil { Scrim(top: 40) { store.switcher = nil } content: { PortfolioSwitcherView() } }
                if store.newPortfolio != nil { Scrim(top: 40, dismiss: nil) { NewPortfolioView() } }
                if store.syncSheet != nil { Scrim(top: 40, dismiss: nil) { SyncSheetView() } }
                if store.restore != nil { Scrim(top: 40, dismiss: nil) { RestoreSheet() } }
                if store.importPreview != nil { Scrim(top: 40, dismiss: nil) { ImportPreviewSheet() } }
                if let k = store.apiKeyEntry { Scrim(top: 40) { store.apiKeyEntry = nil } content: { APIKeySheet(initial: k) } }
                if store.healthPopover {
                    ZStack(alignment: .bottomTrailing) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { store.healthPopover = false }
                        HealthPopover().padding(.trailing, 10).padding(.bottom, 6)
                    }
                }
                if store.keysOverlay { Scrim(top: 40) { store.keysOverlay = false } content: { KeysOverlay() } }
                if store.locked { LockView() }
            }
            .clipped()
            StatusBar()
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .font(Theme.mono(12))
        .background(WindowAccessor { w in store.attachMainWindow(w) })
        .preferredColorScheme(store.colorScheme)
        .id(store.themeID)          // theme switch: every view reads the new tokens
        .alert("Replace current portfolio?", isPresented: Binding(get: { store.pendingImport != nil }, set: { if !$0 { store.pendingImport = nil } }), presenting: store.pendingImport) { d in
            Button("Replace", role: .destructive) { store.applyImport() }
            Button("Cancel", role: .cancel) { store.pendingImport = nil }
        } message: { d in
            Text("A verified recovery snapshot of the current ledger is saved first (Settings → DATA RECOVERY). The backup contains \(d.portfolios.count) portfolio\(d.portfolios.count == 1 ? "" : "s") and \(d.transactions.count) transactions\(d.portfolios.contains(where: \.isDemo) ? " (demo data)" : ""). All current portfolios (\(store.doc.portfolios.count), \(store.doc.transactions.count) transactions) will be replaced\(store.syncEnabled ? " here and on every device syncing with your iCloud; records that match by id are updated, not duplicated" : ""). To add a backup to one portfolio instead, with duplicate detection, use ⌘K → import into current portfolio.")
        }
        .alert("Delete transaction?", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.pendingDelete = nil } }), presenting: store.pendingDelete) { t in
            Button("Delete", role: .destructive) { store.deleteTx(t) }
            Button("Cancel", role: .cancel) { store.pendingDelete = nil }
        } message: { t in
            Text("\(t.type.short) \(Fmt.current.amount(t.quantity)) \(store.asset(t.assetID)?.symbol ?? "") on \(DateFmt.ymd(t.timestamp)). Holdings, P&L and history will be recalculated.")
        }
        .alert("Remove position?", isPresented: Binding(get: { store.pendingRemovePosition != nil }, set: { if !$0 { store.pendingRemovePosition = nil } }),
               presenting: store.pendingRemovePosition) { r in
            Button("Remove", role: .destructive) { store.removePosition(r.asset, from: r.portfolio) }
            Button("Cancel", role: .cancel) { store.pendingRemovePosition = nil }
        } message: { r in
            let n = store.doc.transactions.filter { $0.assetID == r.asset && $0.portfolioID == r.portfolio }.count
            Text("Deletes all \(n) \(store.asset(r.asset)?.symbol ?? "") transaction\(n == 1 ? "" : "s") in \(store.doc.portfolio(r.portfolio)?.name ?? "this portfolio"). Other portfolios keep theirs. A recovery snapshot is saved first, so this can be undone in Settings → DATA RECOVERY.")
        }
        .onAppear {
            if store.hasPortfolio { store.loadHistory(store.assetsHeld(during: store.overviewRange), store.overviewRange) }
        }
    }
}

/// Dimmed backdrop with a top-anchored panel, as in the prototype's modals.
struct Scrim<Content: View>: View {
    var top: CGFloat = 36
    let dismiss: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Theme.scrim.contentShape(Rectangle()).onTapGesture { dismiss?() }
            content
                .background(Theme.raised)
                .overlay(Rectangle().strokeBorder(Theme.overlayBorder, lineWidth: 1))
                .shadow(color: .black.opacity(Theme.isLight ? 0.16 : 0.65), radius: 30, y: 20)
                .padding(.top, top)
        }
        .transition(.asymmetric(insertion: .opacity.animation(.linear(duration: 0.08)), removal: .identity))
    }
}

struct TitleBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 18) {
            Color.clear.frame(width: 60, height: 1)   // traffic lights
            HStack(spacing: 0) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                    if i > 0 { TT(" / ", 12, Theme.t5) }
                    TermButton(action: c.1) { TT(c.0, 12, i == 0 && store.hasPortfolio ? Theme.acc : i == crumbs.count - 1 ? Theme.t1 : Theme.t2) }
                        .accessibilityIdentifier(i == 0 ? "context-crumb" : "crumb-\(i)")
                }
            }
            if store.doc.isDemo(store.context) { tag("DEMO") }
            if store.mockMarket { tag("MOCK DATA") }
            Spacer()
            // 0.7: LIVE / upd moved to the status bar's health zone (⑤).
            HStack(spacing: 16) {
                chip("share", "⌘⇧S") { store.quickShare = false; store.go(.share) }
                chip("commands", "⌘K") { store.openPalette() }
                chip("settings", "⌘,") { store.go(.settings) }
            }
            .disabled(!store.hasPortfolio)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeBorder).frame(height: 1) }
    }

    private func tag(_ s: String) -> some View {
        TT(s, 10, Theme.acc, tracking: 0.8).padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Rectangle().strokeBorder(Theme.acc.opacity(0.5), lineWidth: 1))
    }

    private func chip(_ label: String, _ key: String, _ a: @escaping () -> Void) -> some View {
        TermButton(action: a) { HStack(spacing: 6) { TT(label, 11, Theme.t2); Kbd(key) } }
    }

    /// First crumb is the context itself: `◆ main ▾` opens the switcher.
    private var crumbs: [(String, () -> Void)] {
        guard store.hasPortfolio else { return [("pf", {})] }
        var c: [(String, () -> Void)] = [(store.contextGlyph + " " + store.contextName.lowercased() + " ▾", { store.openSwitcher() })]
        switch store.screen {
        case .overview: c.append(("overview", {}))
        case .asset: c.append((store.currentAsset?.asset.symbol ?? "asset", {}))
        case .target:
            let sym = store.targetValuation?.asset.symbol ?? ""
            c.append((sym, { if let id = store.targetValuation?.asset.id { store.openAsset(id) } }))
            c.append(("target", {}))
        case .movers: c.append(("changes", { store.go(.changes) })); c.append(("movers", {}))
        case .changes: c.append(("changes", {})); c.append(("what changed", {}))
        case .benchmark: c.append(("analytics", { store.go(.analytics) })); c.append(("benchmark", {}))
        case .watch: c.append(("watchlist", {}))
        case .alerts: c.append(("alerts", {}))
        case .scenarios: c.append(("scenarios", {})); if let s = store.currentScenario { c.append((s.name.lowercased(), {})) }
        case .analytics: c.append(("analytics", {}))
        case .settings: c.append(("settings", {}))
        case .share: c.append(("share", {}))
        case .portfolios: c.append(("portfolios", {}))
        }
        return c
    }
}

/// Exposes the hosting NSWindow and places the traffic lights in the 38pt title bar.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            onWindow(w)
            w.isMovableByWindowBackground = false
            w.titlebarAppearsTransparent = true
            w.backgroundColor = NSColor(red: 0x0e / 255, green: 0x0f / 255, blue: 0x11 / 255, alpha: 1)
            context.coordinator.attach(w)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        func attach(_ w: NSWindow) {
            layout(w)
            for n in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.layout(w) })
            }
        }
        private func layout(_ w: NSWindow) {
            guard !w.styleMask.contains(.fullScreen),
                  let close = w.standardWindowButton(.closeButton), let container = close.superview?.superview else { return }
            let barH: CGFloat = 38
            var f = container.frame
            f.size.height = barH
            f.origin.y = w.frame.height - barH
            container.frame = f
            for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let b = w.standardWindowButton(t) else { continue }
                b.setFrameOrigin(NSPoint(x: 14 + CGFloat(i) * 20, y: (barH - b.frame.height) / 2))
            }
        }
    }
}
