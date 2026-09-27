import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    private struct Row: Identifiable {
        let id = UUID()
        let k: String
        let v: String
        var c: Color = Theme.t1
        var action: (() -> Void)?
    }
    private struct Section: Identifiable { let id = UUID(); let title: String; let rows: [Row] }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    TT("SETTINGS", 15, Theme.t1, weight: .semibold, tracking: 0.6)
                    Spacer()
                    TT("click a value to cycle · changes apply immediately · no account", 12, Theme.t3)
                }
                .padding(.bottom, 14).overlay(alignment: .bottom) { Hairline() }
                Columns([.fr(1), .fr(1), .fr(1)], spacing: 18) {
                    column(col1).frame(maxHeight: .infinity, alignment: .top)
                    column(col2).frame(maxHeight: .infinity, alignment: .top)
                    column(col3).frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private func column(_ secs: [Section]) -> some View {
        VStack(spacing: 22) {
            ForEach(secs) { sec in
                Panel(title: sec.title, padding: .init(top: 14, leading: 6, bottom: 6, trailing: 6)) {
                    VStack(spacing: 0) {
                        ForEach(sec.rows) { r in
                            TermButton(action: { r.action?() }, hoverBg: r.action == nil ? .clear : Theme.selected) {
                                HStack(spacing: 12) {
                                    TT(r.k, 12, Theme.t3)
                                    Spacer(minLength: 8)
                                    TT(r.action != nil && r.c == Theme.t1 ? "‹ \(r.v) ›" : r.v, 12, r.c)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cycle<T: Equatable>(_ list: [T], _ cur: T, _ set: @escaping (T) -> Void) -> () -> Void {
        { set(list.cycled(from: cur)) }
    }

    private var col1: [Section] {
        let s = store.settings
        var providers = AppSettings.providerOptions
        #if DEBUG
        providers.append("Mock")
        #endif
        let ws: String = {
            switch store.streamState {
            case .off: return s.realtimeProvider == "off" ? "off" : (s.currency != "USD" ? "USD only" : "idle")
            case .connecting: return "connecting…"
            case .connected: return "connected"
            case let .disconnected(r): return "disconnected (\(r)) · retrying"
            }
        }()
        let wsColor: Color = store.streamState == .connected ? Theme.pos : (store.streamState == .off ? Theme.t2 : Theme.neg)
        let updateColor: Color = {
            switch store.updateState {
            case .updateAvailable: return Theme.acc
            case .failed: return Theme.neg
            case .checking, .upToDate: return Theme.t2
            case .idle: return Theme.acc
            }
        }()
        return [
            Section(title: "GENERAL", rows: [
                Row(k: "version", v: "PF Terminal " + store.installedVersion.display, c: Theme.t2),
                Row(k: "updates", v: store.updateStatusLabel, c: updateColor, action: {
                    if case .updateAvailable = store.updateState { store.openAvailableUpdate() } else { store.checkForUpdates() }
                }),
                Row(k: "keep in Dock when closed", v: s.keepInDock ? "on" : "off", action: { store.settings.keepInDock.toggle() }),
            ]),
            Section(title: "MARKET DATA", rows: [
                Row(k: "primary provider", v: s.primaryProvider, action: cycle(providers, s.primaryProvider) { store.settings.primaryProvider = $0 }),
                Row(k: "realtime provider", v: s.realtimeProvider, action: cycle(AppSettings.realtimeOptions, s.realtimeProvider) { store.settings.realtimeProvider = $0 }),
                Row(k: "fallback provider", v: s.fallbackProvider, action: cycle(AppSettings.fallbackOptions, s.fallbackProvider) { store.settings.fallbackProvider = $0 }),
                Row(k: "refresh interval", v: s.intervalLabel, action: cycle(AppSettings.intervalOptions, s.refreshSeconds) { store.settings.refreshSeconds = $0 }),
                Row(k: "currency", v: s.currency, action: { store.cycleCurrency() }),
                Row(k: "coingecko api key", v: store.hasAPIKey ? "[ in keychain · change ]" : "[ optional · add ]", c: Theme.acc, action: { store.apiKeyEntry = "" }),
                Row(k: "realtime stream", v: ws, c: wsColor),
                Row(k: "last update", v: (store.lastSuccess.map(DateFmt.hms) ?? "—") + " · next \(store.nextRefreshIn)s", c: Theme.t2),
                Row(k: "status", v: store.lastError.map { "\($0)" } ?? store.freshness.label.lowercased(), c: store.lastError == nil ? Theme.t2 : Theme.neg),
            ]),
            Section(title: "MENU BAR", rows: [
                Row(k: "display", v: s.menuBar.rawValue, action: cycle(MenuBarFormat.allCases, s.menuBar) { store.settings.menuBar = $0 }),
                Row(k: "portfolio", v: s.menuBarContext == "all" ? "ALL" : "follow active",
                    action: { store.settings.menuBarContext = s.menuBarContext == "all" ? "active" : "all" }),
                Row(k: "popover rows", v: "\(s.popoverRows)", action: cycle([3, 4, 6, 8], s.popoverRows) { store.settings.popoverRows = $0 }),
                Row(k: "preview", v: store.trayText(), c: Theme.t1),
            ]),
        ]
    }

    private var col2: [Section] {
        let s = store.settings
        return [
            Section(title: "APPEARANCE", rows: [
                Row(k: "theme", v: "dark", c: Theme.t2),
                Row(k: "density", v: s.density, action: cycle(["compact", "comfortable"], s.density) { store.settings.density = $0 }),
                Row(k: "charts", v: s.chartStyle.rawValue, action: cycle(AsciiChart.Style.allCases, s.chartStyle) { store.settings.chartStyle = $0 }),
                Row(k: "numbers", v: s.numbers.rawValue, action: cycle(NumberStyle.allCases, s.numbers) { store.settings.numbers = $0 }),
            ]),
            Section(title: "PRIVACY", rows: [
                Row(k: "account", v: "none required", c: Theme.t2),
                Row(k: "portfolio data", v: store.syncEnabled ? "this Mac + your iCloud" : "stored locally", c: Theme.t2),
                Row(k: "cloud sync", v: store.syncEnabled ? "iCloud private database" : "off", c: Theme.t2),
                Row(k: "app lock", v: s.appLock ? "Touch ID on open" : "off", action: { store.settings.appLock.toggle() }),
                Row(k: "share default", v: s.shareDefaultPrivacy.label, action: cycle([SharePrivacy.public, .value], s.shareDefaultPrivacy) {
                    store.settings.shareDefaultPrivacy = $0; store.share.privacy = $0
                }),
                Row(k: "telemetry", v: "none", c: Theme.t2),
            ]),
            Section(title: "WIDGET PRIVACY", rows: [
                Row(k: "show portfolio value", v: s.widgetPrivacy == .full ? "on" : "off",
                    action: { store.settings.widgetPrivacy = s.widgetPrivacy == .full ? .percentageOnly : .full }),
                Row(k: "off removes", v: "value · $ amounts", c: Theme.t4),
                Row(k: "snapshot", v: store.widgetStatus, c: Theme.t2),
            ]),
            Section(title: "NOTIFICATIONS", rows: [
                Row(k: "24h move alert", v: s.alertThreshold == 0 ? "off" : "±\(Int(s.alertThreshold))%", action: cycle(AppSettings.alertOptions, s.alertThreshold) { store.settings.alertThreshold = $0 }),
            ]),
        ]
    }

    private var col3: [Section] {
        let d = store.doc
        let kb = Double(store.files.byteSize) / 1024
        var data: [Row] = [
            Row(k: "portfolios", v: "[ manage · \(d.livePortfolios.count) active ]", c: Theme.acc, action: { store.go(.portfolios) }),
            Row(k: "location", v: store.dataDirectoryDisplay, c: Theme.t2),
            Row(k: "contents", v: "\(d.assets.count) assets · \(d.transactions.count) tx · \(Fmt.current.num(kb, 1)) KB", c: Theme.t2),
            Row(k: "export", v: "[ portfolio.json ]", c: Theme.acc, action: { store.exportBackup() }),
            Row(k: "import", v: "[ .json ]", c: Theme.acc, action: { store.importBackup() }),
        ]
        if d.portfolios.contains(where: \.isDemo) { data.append(Row(k: "demo data", v: "[ remove ]", c: Theme.acc, action: { store.removeDemo() })) }
        let keys: [(String, String)] = [("command palette", "⌘K"), ("add transaction", "⌘N"), ("refresh", "⌘R"), ("portfolio · movers · analytics", "⌘1 ⌘2 ⌘3"),
                                        ("settings", "⌘4 ⌘,"), ("switch portfolio", "⌘P"), ("prev / next portfolio", "[ ]"), ("navigate · open", "↑↓ ↵"), ("back / close", "esc"), ("search", "/"), ("quick share", "⌘⇧S"),
                                        ("copy card", "⌘C"), ("target (asset)", "t")]
        let st = store.syncState
        var sync: [Row] = [
            Row(k: "storage", v: store.syncEnabled ? "this Mac + iCloud (private)" : "this Mac only", c: Theme.t2),
            Row(k: "icloud sync", v: store.syncEnabled ? "[ on · turn off ]" : "[ off · turn on ]", c: Theme.acc,
                action: { store.syncEnabled ? (store.syncSheet = .disable) : store.beginEnableSync() }),
            Row(k: "status", v: store.syncStatusLabel, c: store.syncStatusColor),
        ]
        if store.syncEnabled {
            sync.append(Row(k: "last sync", v: st.lastSync.map { "\(DateFmt.ymd($0)) \(DateFmt.hms($0))" } ?? "not yet", c: Theme.t2))
            if st.pendingCount > 0 { sync.append(Row(k: "queued", v: "\(st.pendingCount) change\(st.pendingCount == 1 ? "" : "s")", c: Theme.t2)) }
            if !st.conflicts.isEmpty { sync.append(Row(k: "conflicts", v: "[ review · \(st.conflicts.count) ]", c: Theme.acc, action: { store.syncSheet = .conflicts })) }
            sync.append(Row(k: "sync now", v: "[ ⟳ ]", c: Theme.acc, action: { store.syncNow(reason: .manual) }))
        }
        sync += [
            Row(k: "syncs", v: "portfolios · transactions", c: Theme.t4),
            Row(k: "never syncs", v: "prices · keys · settings", c: Theme.t4),
            Row(k: "iPhone", v: "planned", c: Theme.t4),
        ]
        return [
            Section(title: "DATA", rows: data),
            Section(title: "DATA & SYNC", rows: sync),
            Section(title: "SHORTCUTS", rows: keys.map { Row(k: $0.0, v: $0.1, c: Theme.t2) }),
        ]
    }
}

/// Keychain entry for an optional CoinGecko key. The key never touches settings or logs.
struct APIKeySheet: View {
    @Environment(AppStore.self) private var store
    @State var initial: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TT("COINGECKO API KEY", 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT("↵ save · esc cancel", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TT(">", 13, Theme.acc)
                    SecureField("demo key (optional)", text: $initial)
                        .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
                        .focused($focused)
                        .onSubmit { store.setAPIKey(initial); store.apiKeyEntry = nil }
                }
                Text("stored in the macOS Keychain (this device only). sent only to api.coingecko.com as a request header. leave empty and save to remove.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.t4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            HStack {
                BracketButton("cancel", color: Theme.t2) { store.apiKeyEntry = nil }
                Spacer()
                BracketButton("save ↵", color: Theme.acc) { store.setAPIKey(initial); store.apiKeyEntry = nil }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .frame(width: 520)
        .onAppear { focused = true }
    }
}
