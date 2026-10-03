import PFCore
import PFCoreUI
import SwiftUI

// Settings 0.7 (design §13): nine sections, one at a time, a filter over every row and a health
// summary in the sidebar. The row grammar is 0.6's: ‹ value › cycles, [ action ] in accent,
// plain text is read-only, green only for live / connected. Every 0.6 setting is still here.

struct SettingRow: Identifiable {
    /// `link`: an action whose value already carries its own [ brackets ].
    enum Kind { case cycle, action, link, info, ok, muted, bad }
    var id: String { k }
    let k: String
    let v: String
    var kind: Kind = .info
    var hint: String = ""
    /// Cycles (±1) or runs the action. nil for read-only rows.
    var run: ((Int) -> Void)?

    var display: String {
        switch kind {
        case .cycle: "‹ \(v) ›"
        case .action: "[ \(v) ]"
        default: v
        }
    }
    var color: Color {
        switch kind {
        case .cycle: Theme.t1
        case .action, .link: Theme.acc
        case .info: Theme.t2
        case .ok: Theme.pos
        case .muted: Theme.t4
        case .bad: Theme.neg
        }
    }
}

struct SettingGroup: Identifiable { var id: String { h }; let h: String; let rows: [SettingRow] }

struct SettingSection: Identifiable {
    let id: String
    let title: String
    let status: String
    var statusColor: Color = Theme.t3
    let sub: String
    let groups: [SettingGroup]
}

extension AppStore {
    static let settingsSectionIDs = ["general", "appearance", "menubar", "market", "privacy", "sync", "recovery", "alerts", "shortcuts"]

    private func cyc<T: Equatable>(_ k: String, _ v: String, _ list: [T], _ cur: T, hint: String = "", _ set: @escaping (T) -> Void) -> SettingRow {
        SettingRow(k: k, v: v, kind: .cycle, hint: hint) { set(list.cycled(from: cur, by: $0)) }
    }
    private func act(_ k: String, _ v: String, hint: String = "", _ f: @escaping () -> Void) -> SettingRow {
        SettingRow(k: k, v: v, kind: .action, hint: hint) { _ in f() }
    }
    private func ro(_ k: String, _ v: String, _ kind: SettingRow.Kind = .info) -> SettingRow { SettingRow(k: k, v: v, kind: kind) }

    var settingsSections: [SettingSection] {
        let s = settings
        // general
        let update: SettingRow = {
            if case .updateAvailable = updateState { return SettingRow(k: "updates", v: updateStatusLabel, kind: .link) { _ in self.openAvailableUpdate() } }
            if case .failed = updateState { return SettingRow(k: "updates", v: updateStatusLabel, kind: .bad) { _ in self.checkForUpdates() } }
            return SettingRow(k: "updates", v: updateStatusLabel, kind: .link) { _ in self.checkForUpdates() }
        }()
        let general = SettingSection(id: "general", title: "general", status: String(installedVersion.display.prefix { $0 != " " }), sub: "PF Terminal \(installedVersion.display) · no account", groups: [
            SettingGroup(h: "APP", rows: [
                ro("version", "PF Terminal " + installedVersion.display),
                update,
                cyc("keep in Dock when closed", s.keepInDock ? "on" : "off", [false, true], s.keepInDock) { self.settings.keepInDock = $0 },
                cyc("launch at login", s.launchAtLogin ? "menu bar only" : "off", [false, true], s.launchAtLogin) { self.settings.launchAtLogin = $0 },
            ]),
            SettingGroup(h: "NUMBERS", rows: [
                SettingRow(k: "currency", v: s.currency, kind: .cycle) { _ in self.cycleCurrency() },
                cyc("number format", s.numbers.rawValue, NumberStyle.allCases, s.numbers) { self.settings.numbers = $0 },
                cyc("day starts", String(format: "%02d:00 local", s.dayStartHour), AppSettings.dayStartOptions, s.dayStartHour, hint: "used by Today") { self.settings.dayStartHour = $0 },
            ]),
        ])

        // appearance
        let themeLabel = s.theme.rawValue + (s.theme == .system ? " · " + (systemIsDark ? "dark" : "light") : "")
        let appearance = SettingSection(id: "appearance", title: "appearance", status: s.theme.rawValue, sub: "applies immediately", groups: [
            SettingGroup(h: "LOOK", rows: [
                cyc("theme", themeLabel, AppTheme.allCases, s.theme) { self.settings.theme = $0 },
                // Only does something with theme = system: disabled (shown, dimmed, inert) otherwise.
                s.theme == .system
                    ? cyc("dark variant", s.darkVariant.rawValue, [AppTheme.dark, .midnight, .graphite], s.darkVariant, hint: "used by system when dark") { self.settings.darkVariant = $0 }
                    : SettingRow(k: "dark variant", v: s.darkVariant.rawValue, kind: .muted, hint: "only with theme system"),
                cyc("density", s.density, ["compact", "comfortable"], s.density) { self.settings.density = $0 },
                cyc("charts", s.chartStyle.rawValue, AsciiChart.Style.allCases, s.chartStyle) { self.settings.chartStyle = $0 },
            ]),
        ])

        // menu bar + widgets
        let menubar = SettingSection(id: "menubar", title: "menu bar + widgets", status: s.menuBar.rawValue, sub: "what appears outside the window", groups: [
            SettingGroup(h: "MENU BAR", rows: [
                cyc("display", s.menuBar.rawValue, MenuBarFormat.allCases, s.menuBar) { self.settings.menuBar = $0 },
                cyc("portfolio", s.menuBarContext == "all" ? "ALL" : "follow active", ["active", "all"], s.menuBarContext == "all" ? "all" : "active") { self.settings.menuBarContext = $0 },
                cyc("popover rows", "\(s.popoverRows)", [3, 4, 6, 8], s.popoverRows) { self.settings.popoverRows = $0 },
                SettingRow(k: "preview", v: trayText(), kind: .info),
            ]),
            SettingGroup(h: "WIDGETS", rows: [
                cyc("show portfolio value", s.widgetPrivacy == .full ? "on" : "off", [WidgetPrivacyMode.percentageOnly, .full], s.widgetPrivacy) { self.settings.widgetPrivacy = $0 },
                ro("off removes", "value · $ amounts", .muted),
                ro("snapshot", widgetStatus, .muted),
            ]),
        ])

        // market data
        var providers = AppSettings.providerOptions
        #if DEBUG
        providers.append("Mock")
        #endif
        func feedText(_ st: LiveFeed.State) -> String {
            switch st {
            case .off: return s.realtimeProvider == "off" ? "off" : (s.currency != "USD" ? "USD only" : "idle")
            case .connecting: return "connecting…"
            case .connected: return "connected"
            case let .disconnected(r): return "retrying (\(r))"
            }
        }
        let anyUp = streamState == .connected || bybitState == .connected
        let bothOff = streamState == .off && bybitState == .off
        var status: [SettingRow] = [
            ro("realtime stream", "binance " + feedText(streamState) + " · bybit " + feedText(bybitState), anyUp ? .ok : bothOff ? .info : .bad),
            ro("asset registry", "\(AssetRegistry.shared.count) assets · \(AssetRegistry.shared.version)"),
            ro("last update", (lastSuccess.map(DateFmt.hms) ?? "—") + " · next \(nextRefreshIn)s"),
            ro("status", lastError.map { "\($0)" } ?? freshness.label.lowercased(), lastError == nil ? .info : .bad),
        ]
        // Only sources that are backing off right now: the router skips them until then.
        status += providerHealth.compactMap { h in
            h.blockedUntil.map { SettingRow(k: "cooldown · " + h.name.lowercased(), v: "retry in \(max(1, Int($0.timeIntervalSince(now))))s · \(h.failures) failure\(h.failures == 1 ? "" : "s")", kind: .action) }
        }
        let market = SettingSection(id: "market", title: "market data", status: freshness.isLive ? "live" : freshness.label.lowercased(),
                                    statusColor: freshness.isLive ? Theme.pos : Theme.warning, sub: "prices are fetched, never your holdings", groups: [
            SettingGroup(h: "SOURCES", rows: [
                cyc("preferred source", s.primaryProvider == "Auto" ? "auto · live feeds first" : s.primaryProvider, providers, s.primaryProvider) { self.settings.primaryProvider = $0 },
                cyc("live feeds", s.realtimeProvider == "off" ? "off" : "binance + bybit", ["Binance", "off"], s.realtimeProvider == "off" ? "off" : "Binance") { self.settings.realtimeProvider = $0 },
                act("coingecko api key", hasAPIKey ? "in keychain · change" : "optional · add") { self.apiKeyEntry = "" },
                cyc("refresh interval", s.intervalLabel, AppSettings.intervalOptions, s.refreshSeconds) { self.settings.refreshSeconds = $0 },
            ]),
            SettingGroup(h: "STATUS", rows: status),
        ])

        // privacy · storage and cloud sync live once, in data + sync
        let privacy = SettingSection(id: "privacy", title: "privacy", status: s.appLock ? "lock on" : "lock off",
                                     sub: syncEnabled ? "nothing leaves this Mac except iCloud sync" : "nothing leaves this Mac", groups: [
            SettingGroup(h: "LOCK", rows: [
                cyc("app lock", s.appLock ? "on · sleep, screen lock, 5 min away" : "off", [false, true], s.appLock, hint: "⌘L locks now") { self.settings.appLock = $0 },
                ro("while locked", "menu bar shows no amounts", .muted),
            ]),
            SettingGroup(h: "SHARING", rows: [
                cyc("share default", s.shareDefaultPrivacy.label, [SharePrivacy.public, .value], s.shareDefaultPrivacy, hint: "see share ⌘⇧S") {
                    self.settings.shareDefaultPrivacy = $0; self.share.privacy = $0
                },
                ro("telemetry", "none"),
                ro("account", "none required"),
            ]),
        ])

        // data + sync
        let st = syncState
        var icloud: [SettingRow] = [
            act("icloud sync", syncEnabled ? "on · turn off" : "off · turn on") { self.syncEnabled ? (self.syncSheet = .disable) : self.beginEnableSync() },
            ro("status", syncStatusLabel + (syncEnabled && st.pendingCount > 0 ? " · \(st.pendingCount) queued" : ""), syncEnabled && syncStatus == .synced ? .ok : .info),
        ]
        if syncEnabled {
            icloud.append(ro("last sync", st.lastSync.map { "\(DateFmt.ymd($0)) \(DateFmt.hms($0))" } ?? "not yet"))
            if !st.conflicts.isEmpty { icloud.append(act("conflicts", "review · \(st.conflicts.count)") { self.syncSheet = .conflicts }) }
            icloud.append(act("sync now", "⟳") { self.syncNow(reason: .manual) })
        }
        icloud += [
            ro("syncs", "portfolios · transactions", .muted),
            ro("on this Mac only", "watchlist · alerts · scenarios", .muted),
            ro("never syncs", "prices · keys · settings", .muted),
            ro("iPhone", "in development", .muted),
        ]
        let d = doc
        var files: [SettingRow] = [
            act("portfolios", "manage · \(d.livePortfolios.count) active") { self.go(.portfolios) },
            ro("location", dataDirectoryDisplay, .muted),
            ro("contents", "\(d.assets.count) assets · \(d.transactions.count) tx · \(Fmt.current.num(Double(self.files.byteSize) / 1024, 1)) KB"),
            act("export", "portfolio.json") { self.exportBackup() },
            act("import (replace)", ".json") { self.importBackup() },
            act("import into portfolio", ".json · preview") { self.importIntoCurrentPortfolio() },
        ]
        if d.portfolios.contains(where: \.isDemo) { files.append(act("demo data", "remove") { self.removeDemo() }) }
        let sync = SettingSection(id: "sync", title: "data + sync", status: syncEnabled ? syncStatusLabel : "this Mac",
                                  statusColor: syncEnabled && syncStatus == .synced ? Theme.pos : Theme.t3,
                                  sub: syncEnabled ? "this Mac + your iCloud private database" : "this Mac only", groups: [
            SettingGroup(h: "ICLOUD", rows: icloud),
            SettingGroup(h: "PORTFOLIOS + FILES", rows: files),
        ])

        // recovery + diagnostics
        var snaps: [SettingRow] = snapshotList.prefix(3).enumerated().map { i, sn in
            ro(i == 0 ? "latest" : "previous", DiagnosticReport.age(sn.createdAt, now: now) + " · \(sn.transactions) tx" + (sn.isSafety ? " · " + sn.reason : ""))
        }
        if snaps.isEmpty { snaps.append(ro("snapshots", "none yet · taken after ledger changes")) }
        snaps += [
            act("restore", "choose a snapshot…") { self.openRestore() },
            ro("kept", "\(snapshotList.count) local · bounded · never synced", .muted),
        ]
        let recovery = SettingSection(id: "recovery", title: "recovery + diagnostics", status: snapshotList.first.map { DiagnosticReport.age($0.createdAt, now: now) } ?? "none",
                                      sub: "local snapshots · never synced", groups: [
            SettingGroup(h: "SNAPSHOTS", rows: snaps),
            SettingGroup(h: "DIAGNOSTICS", rows: [
                act("report", "copy") { self.copyDiagnosticReport() },
                ro("contains", "versions · sync · sources · errors", .muted),
                ro("never contains", "names · values · amounts · notes · keys", .muted),
                ro("recent events", "\(diagnostics.events.count) · " + (diagnostics.events.last.map { "\($0.category.rawValue).\($0.code)" } ?? "none")),
            ]),
        ])

        // alerts · delivery only; rules live in Alerts
        let n = intel.alerts.count
        let alerts = SettingSection(id: "alerts", title: "alerts", status: "\(n) rule\(n == 1 ? "" : "s")", sub: "rules live in Alerts (g a) · delivery here", groups: [
            SettingGroup(h: "DELIVERY", rows: [
                cyc("notification", s.alertBanner ? "macOS banner" : "off", [false, true], s.alertBanner) { self.settings.alertBanner = $0 },
                cyc("menu bar popover", s.alertBadge ? "newest alert until seen" : "off", [false, true], s.alertBadge) { self.settings.alertBadge = $0 },
                cyc("sound", s.alertSound ? "on" : "off", [false, true], s.alertSound) { self.settings.alertSound = $0 },
                cyc("quiet hours", s.quietHours == "off" ? "off" : s.quietHours + " · queue", AppSettings.quietHourOptions, s.quietHours) { self.settings.quietHours = $0 },
            ]),
            SettingGroup(h: "RULES", rows: [
                act("manage rules", "open alerts · g a") { self.go(.alerts) },
                ro("moved from 0.6", "24h move · stablecoin depeg → alert rules", .muted),
                ro("stored", "on this Mac · not synced", .muted),
            ]),
        ])

        let shortcuts = SettingSection(id: "shortcuts", title: "shortcuts", status: "", sub: "read-only · full list", groups: [
            SettingGroup(h: "GLOBAL", rows: [
                ro("command palette", "⌘K"), ro("go to …", "g + key"), ro("tabs", "1 2 3 4 · ⌘1–⌘4"), ro("switch portfolio", "⌘P · [ ]"),
                ro("settings", "⌘,"), ro("share", "⌘⇧S"), ro("refresh", "⌘R"), ro("lock", "⌘L"), ro("keys for this view", "?"), ro("back / close", "esc"),
            ]),
            SettingGroup(h: "IN VIEWS", rows: [
                ro("add transaction", "⌘N"), ro("new alert / watch / scenario", "n"), ro("convert watch → position", "⌘↵"),
                ro("mode toggle", "m · b"), ro("what changed (portfolio)", "d"), ro("target calculator", "t"), ro("navigate · open", "↑↓ ↵"), ro("copy card", "⌘C"),
            ]),
        ])

        return [general, appearance, menubar, market, privacy, sync, recovery, alerts, shortcuts]
    }

    /// What the right pane shows: one section, or filter matches grouped by section.
    var settingsPane: (title: String, sub: String, groups: [SettingGroup]) {
        let all = settingsSections
        let q = settingsFilter.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            let s = all.first { $0.id == settingsSection } ?? all[0]
            return (s.title.uppercased(), s.sub, s.groups)
        }
        let groups = all.compactMap { s -> SettingGroup? in
            let rows = s.groups.flatMap(\.rows).filter { ($0.k + " " + $0.v + " " + s.title + " " + $0.hint).lowercased().contains(q) }
            return rows.isEmpty ? nil : SettingGroup(h: s.title.uppercased(), rows: rows)
        }
        let n = groups.reduce(0) { $0 + $1.rows.count }
        return ("FILTER", "\(n) match\(n == 1 ? "" : "es") in \(groups.count) section\(groups.count == 1 ? "" : "s")", groups)
    }

    func selectSettingsSection(_ id: String) {
        settingsSection = id; settingsFilter = ""; settingsRow = nil
    }

    /// ↑↓ section (or row once inside with ⇥) · ←→ cycle · ↵ run · ⌘1–9 section.
    func handleSettingsKey(_ e: NSEvent) -> Bool {
        let code = e.keyCode
        let ids = Self.settingsSectionIDs
        let rows = settingsPane.groups.flatMap(\.rows)
        switch code {
        case 48: // ⇥ into rows / back to the sidebar
            settingsRow = settingsRow == nil ? (rows.firstIndex { $0.run != nil } ?? 0) : nil
            return true
        case 125, 126:
            let step = code == 125 ? 1 : -1
            if let r = settingsRow, !rows.isEmpty { settingsRow = (r + step + rows.count) % rows.count; return true }
            let i = ids.firstIndex(of: settingsSection) ?? 0
            selectSettingsSection(ids[(i + step + ids.count) % ids.count])
            return true
        case 123, 124, 36, 76:
            guard let r = settingsRow, let row = rows[safe: r], let run = row.run else { return false }
            run(code == 123 ? -1 : 1)
            return true
        default:
            return false
        }
    }
}
