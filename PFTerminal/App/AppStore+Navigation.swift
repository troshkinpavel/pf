import PFCore
import PFCoreUI
import AppKit
import SwiftUI

// 0.7 navigation (design §01, §14): four numbered tabs, mode keys, a `g` go-to leader for the
// reference screens, and a quiet status bar. Everything here is UI state: nothing persists.

extension AppStore {
    // MARK: tabs

    struct Tab { let key: String; let label: String; let screen: Screen }
    static let tabs: [Tab] = [
        Tab(key: "1", label: "portfolio", screen: .overview), Tab(key: "2", label: "changes", screen: .changes),
        Tab(key: "3", label: "analytics", screen: .analytics), Tab(key: "4", label: "watch", screen: .watch),
    ]

    /// Which numbered tab the current screen belongs to (nil for reference screens).
    var activeTab: Int? {
        switch screen {
        case .overview, .asset, .target: 0
        case .changes, .movers: 1
        case .analytics, .benchmark: 2
        case .watch: 3
        default: nil
        }
    }

    /// The off-tab screen shown after the tabs ("g a:alerts*", "⌘,:settings*").
    var offTabLabel: String? {
        switch screen {
        case .alerts: "g a:alerts"
        case .scenarios: "g s:scenarios"
        case .portfolios: "g p:portfolios"
        case .settings: "⌘,:settings"
        case .share: "⌘⇧S:share"
        default: nil
        }
    }

    func tabLabel(_ i: Int) -> String {
        let t = Self.tabs[i]
        var s = t.key + ":" + t.label
        if i == 2 && screen == .benchmark { s += "·b" }
        if i == 1 && screen == .movers { s += "·m" }
        return s
    }

    /// Tab 2 returns to the last Changes mode (What Changed or Movers).
    func goTab(_ i: Int) {
        switch i {
        case 1: go(changesUsesMovers ? .movers : .changes)
        case 2: go(analyticsUsesBenchmark ? .benchmark : .analytics)
        default: go(Self.tabs[i].screen)
        }
    }

    /// m on Changes · b on Analytics: the mode inside a tab.
    func toggleChangesMode() {
        changesUsesMovers = screen != .movers
        go(changesUsesMovers ? .movers : .changes)
        if changesUsesMovers { loadMoversHistory() }
    }
    func toggleBenchmark() {
        analyticsUsesBenchmark = screen != .benchmark
        go(analyticsUsesBenchmark ? .benchmark : .analytics)
    }

    // MARK: g leader

    static let leaderTimeout: TimeInterval = 1.2
    static let leaderKeys: [(key: String, label: String)] = [
        ("c", "what changed"), ("m", "movers"), ("b", "benchmark"), ("w", "watchlist"), ("a", "alerts"), ("s", "scenarios"), ("p", "portfolios"), (",", "settings"),
    ]

    func startLeader() {
        leaderActive = true
        leaderTask?.cancel()
        leaderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.leaderTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.leaderActive = false
        }
    }

    /// The key after `g`. Any key ends the leader; unknown keys just cancel it.
    @discardableResult
    func leaderKey(_ k: String) -> Bool {
        leaderActive = false
        leaderTask?.cancel()
        switch k {
        case "c": changesUsesMovers = false; go(.changes)
        case "m": changesUsesMovers = true; go(.movers); loadMoversHistory()
        case "b": analyticsUsesBenchmark = true; go(.benchmark)
        case "w": go(.watch)
        case "a": go(.alerts)
        case "s": go(.scenarios)
        case "p": go(.portfolios)
        case ",": go(.settings)
        default: return false
        }
        return true
    }

    // MARK: message slot

    /// How long an event stays in the message slot before the view hints come back.
    static func messageLifetime(_ m: String) -> TimeInterval { m.hasPrefix("✗") ? 10 : 4 }

    enum SlotTone { case hint, event, success, failure, accent }

    /// ③: leader > locked > a recent event > view hints.
    var messageSlot: (text: String, tone: SlotTone) {
        if leaderActive {
            return ("g-  " + Self.leaderKeys.map { "\($0.key) \($0.label)" }.joined(separator: " · ") + " · esc", .accent)
        }
        if locked { return ("⌁ locked · amounts hidden · ⌘L unlock", .hint) }
        if protectedDataWaiting { return ("protected data unavailable — waiting for unlock", .accent) }
        if now.timeIntervalSince(messageAt) < Self.messageLifetime(message), !message.isEmpty, message != "ready" {
            let tone: SlotTone = message.hasPrefix("✓") ? .success : message.hasPrefix("✗") ? .failure : message.hasPrefix("⚑") ? .accent : .event
            return (message, tone)
        }
        return (viewHints, .hint)
    }

    /// Up to three hints for the current view (design §14: "hints are capped at three").
    var viewHints: String {
        if !hasPortfolio { return "1 empty · 2 demo · 3 import" }
        switch screen {
        case .overview: return isAll ? "↑↓ portfolio · ↵ drill in · d what changed" : "↑↓ select · ↵ open · d what changed"
        case .changes: return "←→ range · ↵ open asset · m movers"
        case .movers: return "↑↓ · ↵ open · m what changed"
        case .analytics: return "b benchmark · hover charts for values"
        case .benchmark: return "b overview · ←→ range"
        case .watch: return "n watch · ⌘↵ convert · a alert"
        case .alerts: return "↵ edit · space pause · n new"
        case .scenarios: return "c b u switch · ↵ edit target · n new"
        case .asset: return "esc back · a alert · t target"
        case .target: return "↑↓ presets · ⌘S save to scenario · esc back"
        case .portfolios: return "↵ open · r rename · n new"
        case .settings: return "↑↓ section · ←→ cycle value · / filter"
        case .share: return "⌘C copy · ←→ period · f format"
        }
    }

    // MARK: ⑤ health

    struct Health {
        enum Level: Int { case ok, degraded, bad }
        let level: Level
        let glyph: String
        let text: String
    }

    /// One glyph for prices + feeds + sync; words only when something is wrong.
    var health: Health {
        if protectedDataWaiting { return Health(level: .degraded, glyph: "▲", text: "waiting for unlock") }
        let pending = syncEnabled ? syncState.pendingCount : 0
        let pricesAge = Freshness.oldestQuoteAge(held: marketDrivenHeld, quotes: quotes, now: now).map { Int($0 / 60) }
        if !online {
            var t = "offline"
            if pending > 0 { t += " · \(pending) queued" }
            if let a = pricesAge, a > 0 { t += " · prices \(a)m" }
            return Health(level: .degraded, glyph: "▲", text: t)
        }
        // Two missed refreshes at the interval actually in use (it backs off in the background).
        let staleAfter = 2 * effectiveInterval
        if let age = Freshness.oldestQuoteAge(held: marketDrivenHeld, quotes: quotes, now: now), age > max(staleAfter, 120), !inFlight {
            return Health(level: .bad, glyph: "●", text: "stale " + DateFmt.age(age))
        }
        if let feeds = degradedFeeds { return Health(level: .degraded, glyph: "▲", text: feeds) }
        if syncEnabled {
            switch syncStatus {
            case .error, .accountUnavailable, .iCloudUnavailable: return Health(level: .degraded, glyph: "▲", text: "sync issue" + (pending > 0 ? " · \(pending) queued" : ""))
            case .conflict(let n): return Health(level: .degraded, glyph: "▲", text: "\(n) sync conflict\(n == 1 ? "" : "s")")
            default: break
            }
        }
        if let cool = providerHealth.first(where: { $0.blockedUntil != nil }), lastError != nil {
            return Health(level: .degraded, glyph: "▲", text: cool.name.lowercased() + " cooling down")
        }
        return Health(level: .ok, glyph: "●", text: "live \(nextRefreshIn)s")
    }

    /// "bybit down · binance live" when one live feed in use dropped and another still streams.
    var degradedFeeds: String? {
        guard settings.realtimeProvider != "off", !mockMarket else { return nil }
        let used = Set(doc.assets.filter { heldAnywhere.contains($0.id) }.flatMap { streamSources($0) })
        let states: [(MarketSource, LiveFeed.State)] = [(.binance, streamState), (.bybit, bybitState)].filter { used.contains($0.0) }
        let down = states.filter { if case .disconnected = $0.1 { return true }; return false }.map { $0.0.label.lowercased() }
        let up = states.filter { $0.1 == .connected }.map { $0.0.label.lowercased() }
        guard !down.isEmpty else { return nil }
        return down.joined(separator: "+") + " down" + (up.isEmpty ? " · rest polling" : " · " + up.joined(separator: "+") + " live")
    }

    func healthColor(_ h: Health) -> Color {
        switch h.level { case .ok: Theme.pos; case .degraded: Theme.warning; case .bad: Theme.neg }
    }

    /// Health popover rows (design §14): prices · feeds · icloud · ledger · recovery.
    var healthRows: [(ok: Bool, k: String, v: String)] {
        let f = freshness
        let feeds = settings.realtimeProvider == "off" ? "live feeds off · polling" : degradedFeeds ?? "binance + bybit · coingecko fallback"
        let icloud: String = {
            guard syncEnabled else { return "off · this Mac only" }
            let last = syncState.lastSync.map { DateFmt.hms($0) } ?? "never"
            return "\(syncStatusLabel) · last \(last) · \(syncState.pendingCount) queued"
        }()
        let ledgerErrors = doc.validationErrors()
        let snap = snapshotList.first.map { DiagnosticReport.age($0.createdAt, now: now) } ?? "none yet"
        return [
            (f.isLive, "prices", "\(marketDrivenHeld.count) assets · upd " + (lastSuccess.map(DateFmt.hms) ?? "—") + " · next \(nextRefreshIn)s"),
            (degradedFeeds == nil, "feeds", feeds),
            (!syncEnabled || syncStatus == .synced || syncStatus == .syncing, "icloud", icloud),
            (ledgerErrors.isEmpty && !protectedDataWaiting, "ledger", protectedDataWaiting ? "protected data unavailable — waiting for unlock" : ledgerErrors.isEmpty ? "\(doc.transactions.count) tx valid · \(doc.livePortfolios.count) portfolio\(doc.livePortfolios.count == 1 ? "" : "s")" : "\(ledgerErrors.count) problem\(ledgerErrors.count == 1 ? "" : "s")"),
            (snapshotList.first.map { now.timeIntervalSince($0.createdAt) < 7 * 86400 } ?? false, "recovery", "snapshot " + snap),
        ]
    }

    // MARK: ④ alerts

    var unseenAlerts: Int { intel.alerts.filter { $0.unseen && $0.state == .fired }.count }

    // MARK: lock

    /// ⌘L: lock now (with app lock on), or unlock when locked.
    func toggleLock() {
        if locked { unlock(); return }
        guard settings.appLock else { message = "app lock is off · turn it on in Settings › privacy"; return }
        lockIfEnabled("manual")
    }
}

extension AppStore {
    /// Keys of the 0.7 screens (Changes, Analytics/Benchmark modes, Watch, Alerts, Scenarios,
    /// Settings). Returns true when consumed.
    func handleIntelKey(_ k: String, e: NSEvent, shift: Bool) -> Bool {
        let code = e.keyCode
        let isReturn = code == 36 || code == 76, isUp = code == 126, isDown = code == 125, isLeft = code == 123, isRight = code == 124
        switch screen {
        case .changes:
            if k == "m" { toggleChangesMode(); return true }
            if isLeft || isRight {
                wcPeriod = Attribution.Period.allCases.cycled(from: wcPeriod, by: isRight ? 1 : -1); wcSel = 0
                loadAttributionHistory(); return true
            }
            let rows = attribution(wcPeriod)?.byImpact ?? []
            if isDown, !rows.isEmpty { wcSel = (wcSel + 1) % rows.count; return true }
            if isUp, !rows.isEmpty { wcSel = (wcSel - 1 + rows.count) % rows.count; return true }
            if isReturn, let a = rows[safe: wcSel] { openAsset(a.id); return true }
        case .analytics:
            if k == "b" { toggleBenchmark(); return true }
        case .benchmark:
            if k == "b" { toggleBenchmark(); return true }
            if isLeft || isRight { setBenchmarkRange(Benchmark.Range.allCases.cycled(from: benchmarkRange, by: isRight ? 1 : -1)); return true }
        case .watch:
            let rows = watchRows, w = rows[safe: watchSel]?.item
            if k == "n" { openWatchAdd(); return true }
            if isDown, !rows.isEmpty { watchSel = (watchSel + 1) % rows.count; watchConfirmRemove = nil; return true }
            if isUp, !rows.isEmpty { watchSel = (watchSel - 1 + rows.count) % rows.count; watchConfirmRemove = nil; return true }
            guard let w else { break }
            if k == "e" || isReturn { openWatchEdit(w); return true }
            if k == "a" { openAlertSetup(subject: .asset(w.assetID)); return true }
            if code == 51 || code == 117 { requestRemoveWatch(w); return true }
        case .alerts:
            let rows = alertRows, r = rows[safe: alertSel]?.rule
            if k == "n" { openAlertSetup(); return true }
            if isDown, !rows.isEmpty { alertSel = (alertSel + 1) % rows.count; alertConfirmDelete = nil; return true }
            if isUp, !rows.isEmpty { alertSel = (alertSel - 1 + rows.count) % rows.count; alertConfirmDelete = nil; return true }
            guard let r else { break }
            if isReturn { openAlertEdit(r); return true }
            if k == " " { togglePause(r.id); return true }
            if k == "r" { rearm(r.id); return true }
            if code == 51 || code == 117 { requestDeleteAlert(r.id); return true }
        case .scenarios:
            if ["c", "b", "u"].contains(k), selectScenario(key: k) { return true }
            if k == "n" { newScenario(); return true }
            let list = orderedScenarios
            if (isLeft || isRight), let cur = currentScenario, let i = list.firstIndex(where: { $0.id == cur.id }) {
                selectScenario(list[(i + (isRight ? 1 : -1) + list.count) % list.count].id); return true
            }
            guard let cur = currentScenario else { break }
            let n = projection(cur).rows.count
            if isDown, n > 0 { scenarioRow = (scenarioRow + 1) % n; return true }
            if isUp, n > 0 { scenarioRow = (scenarioRow - 1 + n) % n; return true }
            if isReturn { beginScenarioEdit(); return true }
            if k == "r" { scenarioRename = cur.name; return true }
            if code == 51 || code == 117 { requestDeleteScenario(); return true }
        case .settings:
            if k == "/" { settingsFocusFilter = true; return true }
            return handleSettingsKey(e)
        default: break
        }
        return false
    }
}
