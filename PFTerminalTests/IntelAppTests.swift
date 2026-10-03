import PFCore
import PFCoreUI
import AVFoundation
import ImageIO
import Foundation
import Testing
@testable import PFTerminal

/// 0.7 app behaviour: navigation, status bar, settings, watchlist + conversion, alerts, migration.
/// In-memory stores, mock-free (no providers): prices are set directly.
@MainActor
struct IntelAppTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
    private let sol = AssetCatalog.known.first { $0.symbol == "SOL" }!

    private func store(defaults: UserDefaults? = nil, seed: Bool = true) -> AppStore {
        var o = AppStore.Options()
        o.directory = nil; o.inMemory = true; o.mockMarket = false; o.publishWidgets = false
        o.defaults = defaults ?? UserDefaults(suiteName: "pf-intel-\(UUID().uuidString)")!
        let s = AppStore(o)
        if seed {
            s.createEmpty()
            s.openTx(TxDraft(asset: "BTC", amount: "0.5", price: "60000", date: "2026-01-02"))
            s.confirmTx()
            s.quotes[btc.id] = Quote(price: 90000, change: [.h24: 2], source: "test", timestamp: Date())
            s.recompute()
        }
        return s
    }

    // MARK: navigation

    @Test func fourTabsModesAndLeader() {
        let s = store()
        s.goTab(1); #expect(s.screen == .changes && s.activeTab == 1)
        s.toggleChangesMode(); #expect(s.screen == .movers && s.tabLabel(1).hasSuffix("·m"))
        s.goTab(0); s.goTab(1); #expect(s.screen == .movers, "tab 2 returns to the last Changes mode")
        s.goTab(2); s.toggleBenchmark(); #expect(s.screen == .benchmark && s.activeTab == 2)
        s.back(); #expect(s.screen == .analytics, "esc leaves benchmark for analytics")
        s.goTab(3); #expect(s.screen == .watch)
        s.startLeader(); #expect(s.leaderActive)
        #expect(s.leaderKey("a") && s.screen == .alerts && !s.leaderActive)
        #expect(s.activeTab == nil && s.offTabLabel == "g a:alerts")
        s.startLeader(); #expect(!s.leaderKey("x") && !s.leaderActive, "unknown key cancels, never sticks")
        s.startLeader(); s.back(); #expect(!s.leaderActive && s.screen == .alerts, "esc closes the leader first")
    }

    // MARK: status bar

    @Test func messageSlotPriorityAndLifetime() {
        let s = store()
        s.go(.overview)
        s.message = "✓ saved"
        #expect(s.messageSlot.text == "✓ saved" && s.messageSlot.tone == .success)
        s.now = s.messageAt.addingTimeInterval(5)
        #expect(s.messageSlot.tone == .hint, "events fade after 4s, hints return")
        s.message = "✗ refresh failed"
        s.now = s.messageAt.addingTimeInterval(8)
        #expect(s.messageSlot.tone == .failure, "failures stay 10s")
        s.locked = true
        #expect(s.messageSlot.text.contains("locked"))
        s.startLeader()
        #expect(s.messageSlot.text.hasPrefix("g-"), "leader beats everything")
        s.locked = false; s.leaderActive = false
        #expect(s.viewHints.components(separatedBy: " · ").count <= 3)
    }

    @Test func healthGlyph() {
        let s = store()
        s.now = Date()
        #expect(s.health.level == .ok && s.health.text.hasPrefix("live"))
        s.online = false
        #expect(s.health.level == .degraded && s.health.text.hasPrefix("offline"))
        s.online = true
        s.quotes[btc.id] = Quote(price: 90000, source: "test", timestamp: Date().addingTimeInterval(-3 * s.effectiveInterval - 300))
        #expect(s.health.level == .bad && s.health.text.hasPrefix("stale"))
        #expect(s.healthRows.map(\.k) == ["prices", "feeds", "icloud", "ledger", "recovery"])
    }

    // MARK: settings

    @Test func nineSectionsFilterAndNoLostSettings() {
        let s = store()
        #expect(s.settingsSections.map(\.id) == AppStore.settingsSectionIDs && AppStore.settingsSectionIDs.count == 9)
        let keys = Set(s.settingsSections.flatMap { $0.groups.flatMap { $0.rows.map(\.k) } })
        // Every 0.6 setting still has a row (notifications became alert delivery + rules).
        for k in ["keep in Dock when closed", "preferred source", "live feeds", "refresh interval", "currency", "coingecko api key",
                  "display", "portfolio", "popover rows", "theme", "density", "charts", "number format", "app lock", "share default",
                  "show portfolio value", "report", "icloud sync", "export", "import (replace)", "import into portfolio", "restore",
                  "dark variant", "day starts", "launch at login", "notification", "menu bar popover", "sound", "quiet hours"] {
            #expect(keys.contains(k), "missing setting: \(k)")
        }
        // Merged duplicates: storage / cloud sync live once.
        let all = s.settingsSections.flatMap { $0.groups.flatMap { $0.rows.map(\.k) } }
        #expect(all.filter { $0 == "icloud sync" }.count == 1 && !all.contains("storage") && !all.contains("cloud sync"))
        s.settingsFilter = "sync"
        #expect(s.settingsPane.title == "FILTER" && s.settingsPane.groups.contains { $0.h == "DATA + SYNC" })
        s.settingsFilter = "zzzz"
        #expect(s.settingsPane.groups.isEmpty)
        s.go(.settings); s.back()
        #expect(s.settingsFilter.isEmpty && s.screen == .settings, "esc clears the filter first")
        s.selectSettingsSection("alerts")
        #expect(s.settingsPane.title == "ALERTS")
        // A cycle row changes the setting.
        let day = s.settingsSections.first { $0.id == "general" }!.groups.flatMap(\.rows).first { $0.k == "day starts" }!
        day.run?(1)
        #expect(s.settings.dayStartHour == 4)
    }

    // MARK: watchlist + conversion

    @Test func watchAddDedupeRemove() {
        let s = store()
        s.watchDraft = WatchDraft(asset: "SOL", entry: "135", target: "210", note: "unlock")
        s.saveWatch()
        #expect(s.intel.watchlist.count == 1 && s.intel.watchlist[0].entry == 135)
        s.watchDraft = WatchDraft(asset: "sol", entry: "130")
        s.saveWatch()
        #expect(s.intel.watchlist.count == 1 && s.intel.watchlist[0].entry == 130, "same canonical asset: updated, not duplicated")
        #expect(s.pricedIDs.contains(sol.id), "watched assets are priced")
        let w = s.intel.watchlist[0]
        s.requestRemoveWatch(w); #expect(s.intel.watchlist.count == 1, "first ⌫ only asks")
        s.requestRemoveWatch(w); #expect(s.intel.watchlist.isEmpty)
        s.watchDraft = WatchDraft(asset: "SOL", entry: "-1")
        #expect(s.watchDraftProblem(s.watchDraft!) != nil)
    }

    @Test func convertRecordsARealTransactionAndUndoes() throws {
        let s = store()
        s.watchDraft = WatchDraft(asset: "SOL", entry: "135", target: "210", note: "unlock")
        s.saveWatch()
        s.quotes[sol.id] = Quote(price: 150, source: "test", timestamp: Date())
        let before = s.doc.transactions.count
        let w = try #require(s.intel.watchlist.first)
        s.convertWatch(w)
        #expect(s.converting?.item.id == w.id && s.tx?.asset == "SOL")
        s.tx?.amount = "2"
        s.confirmTx()
        #expect(s.doc.transactions.count == before + 1, "a real ledger transaction")
        #expect(s.summary.valuation(sol.id)?.position.quantity == 2)
        #expect(s.intel.watchlist.first?.isActive == false && s.intel.watchlist.first?.convertedTx != nil, "archived, not deleted")
        #expect(Scenarios.base(s.intel)?.targets[sol.id]?.price == 210, "target carried into Base")
        #expect(s.intel.alerts.contains { $0.subject == .asset(sol.id) && $0.kind == .priceAbove && $0.threshold == 210 })
        #expect(s.message.contains("⌘Z"))
        s.undoConversion()
        #expect(s.doc.transactions.count == before && s.summary.valuation(sol.id) == nil)
        #expect(s.intel.watchlist.first?.isActive == true && s.intel.alerts.isEmpty && s.intel.scenarios.isEmpty)
    }

    @Test func cancellingTheSheetDropsTheConversion() throws {
        let s = store()
        s.watchDraft = WatchDraft(asset: "SOL"); s.saveWatch()
        s.convertWatch(try #require(s.intel.watchlist.first))
        s.tx = nil
        #expect(s.converting == nil)
        s.openTx(TxDraft(asset: "SOL", amount: "1", price: "100")); s.confirmTx()
        #expect(s.intel.watchlist.first?.isActive == true, "a normal buy never archives a watch item")
    }

    // MARK: alerts

    @Test func setupArmsEvaluatesFiresAndBadges() throws {
        let s = store()
        s.openAlertSetup(subject: .asset(btc.id))
        s.alertSetup?.line = "alert btc above 85000"
        s.advanceAlertSetup()
        #expect(s.alertSetup?.review == true, "review before arming")
        s.advanceAlertSetup()
        let r = try #require(s.intel.alerts.first)
        #expect(r.kind == .priceAbove && r.threshold == 85000 && s.alertSetup == nil)
        // Price is 90 000: armed then fired by the evaluation that follows arming.
        #expect(s.intel.alerts[0].state == .fired && s.intel.alerts[0].unseen && s.intel.alertLog.count == 1)
        #expect(!s.trayText().contains("⚑") && s.unseenAlerts == 1, "the title never carries a count; the popover shows the alert")
        s.go(.alerts)
        #expect(s.unseenAlerts == 0)
        s.evaluateAlerts()
        #expect(s.intel.alertLog.count == 1, "once: no second fire while the condition holds")
        s.rearm(r.id); s.evaluateAlerts()
        #expect(s.intel.alertLog.count == 2)
        s.togglePause(r.id); s.rearm(r.id); s.evaluateAlerts()
        #expect(s.intel.alertLog.count == 2, "paused rules never fire")
        s.requestDeleteAlert(r.id); s.requestDeleteAlert(r.id)
        #expect(s.intel.alerts.isEmpty)
    }

    @Test func staleOrLockedNeverLeaksAndQuietHoursQueue() throws {
        let s = store()
        s.quotes[btc.id] = Quote(price: 90000, source: "test", timestamp: Date().addingTimeInterval(-86400))
        s.alertSetup = AlertSetup(line: "alert btc above 85000"); s.advanceAlertSetup(); s.advanceAlertSetup()
        #expect(s.intel.alerts.first?.state == .armed, "stale prices never fire")
        s.locked = true
        s.quotes[btc.id] = Quote(price: 90000, source: "test", timestamp: Date())
        s.evaluateAlerts()
        #expect(s.trayText() == "PF  🔒", "no badge or amounts while locked")
        s.locked = false
        // Quiet hours covering now: logged as queued.
        let s2 = store()
        let h = Calendar.current.component(.hour, from: Date())
        s2.settings.quietHours = String(format: "%02d–%02d", h, (h + 2) % 24)
        if s2.settings.isQuiet(Date()) {
            s2.alertSetup = AlertSetup(line: "alert btc above 85000"); s2.advanceAlertSetup(); s2.advanceAlertSetup()
            #expect(s2.intel.alertLog.first?.delivery.hasPrefix("queued") == true)
        }
    }

    @Test func commandGrammarInThePalette() {
        let s = store()
        #expect(s.paletteItems("alert btc below 50000").first?.label.contains("price ≤") == true)
        #expect(s.paletteItems("watch sol 135 210").first?.label == "Watch SOL")
        #expect(s.paletteItems("compare 1y").first?.label.contains("Benchmark") == true)
        let sym = s.paletteItems("btc")
        #expect(sym.first?.group == "ASSET" && sym.contains { $0.group == "ACTIONS" })
        #expect(s.paletteItems("buy eth 0.5 @ 3500").first?.label.hasPrefix("BUY") == true, "0.6 commands unchanged")
    }

    // MARK: scenarios

    @Test func scenariosEditInPlaceAndSaveFromTarget() {
        let s = store()
        s.go(.scenarios)
        s.createPresetScenarios()
        #expect(s.orderedScenarios.map(\.key) == ["c", "b", "u"] && s.currentScenario?.key == "b")
        s.scenarioRow = 0; s.beginScenarioEdit()
        s.scenarioEdit = "2x"; s.commitScenarioEdit()
        #expect(s.currentScenario?.targets[btc.id]?.price == 180000, "same parser as the target screen")
        #expect(s.projection(s.currentScenario!).projected == 90000)
        s.beginScenarioEdit(); s.scenarioEdit = "30%"; s.commitScenarioEdit()
        #expect(s.targetWeight(btc.id) == 30 && s.currentScenario?.targets[btc.id]?.price == 180000, "a weight never changes the price target")
        s.duplicateScenario(); #expect(s.intel.scenarios.count == 4)
        s.requestDeleteScenario(); s.requestDeleteScenario(); #expect(s.intel.scenarios.count == 3)
        s.openTarget(btc.id, "150000"); s.saveTargetToScenario()
        #expect(Scenarios.base(s.intel)?.targets[btc.id]?.price == 150000)
        #expect(s.doc.transactions.count == 1, "scenarios never touch the ledger")
    }

    // MARK: migration

    @Test func notificationsMigrateToRulesOnce() {
        let d = UserDefaults(suiteName: "pf-intel-mig-\(UUID().uuidString)")!
        var st = AppSettings(); st.alertThreshold = 7; st.depegAlerts = true
        st.save(d)
        d.set(["cg:tether"], forKey: "pf.depeg.alerted")
        let s = store(defaults: d, seed: false)
        #expect(s.intel.alerts.map(\.kind) == [.move24h, .depeg])
        #expect(s.intel.alerts[0].threshold == 7 && s.intel.alerts[0].repeatMode == .daily)
        #expect(s.intel.alerts[0].subject == .portfolio(AlertSubject.activePortfolio), "the active portfolio's 24h change, as in 0.6")
        #expect(s.intel.alerts[1].state == .fired, "a coin 0.6 already notified about doesn't notify again")
        #expect(s.settings.alertThreshold == 7, "0.6 values left as they were (downgrade keeps working)")
    }

    /// 0.6 semantics: the portfolio's 24h change, not any single asset; once a day.
    @Test func migrated24hRuleWatchesThePortfolioNotAssets() throws {
        let d = UserDefaults(suiteName: "pf-intel-move-\(UUID().uuidString)")!
        var st = AppSettings(); st.alertThreshold = 5; st.save(d)
        let s = store(defaults: d)
        let eth = AssetCatalog.known.first { $0.symbol == "ETH" }!
        // A small ETH position moves 30% while the portfolio moves ~1%: 0.6 stayed quiet, so does 0.7.
        s.openTx(TxDraft(asset: "ETH", amount: "0.1", price: "3000", date: "2026-01-02")); s.confirmTx()
        s.quotes[btc.id] = Quote(price: 90000, change: [.h24: 0.5], source: "test", timestamp: Date())
        s.quotes[eth.id] = Quote(price: 3000, change: [.h24: 30], source: "test", timestamp: Date())
        s.recompute(); s.evaluateAlerts()
        #expect(s.intel.alertLog.isEmpty, "a single asset's move never fires the migrated rule")
        // The portfolio itself moves 8%: fires once.
        s.quotes[btc.id] = Quote(price: 90000, change: [.h24: 8], source: "test", timestamp: Date())
        s.quotes[eth.id] = Quote(price: 3000, change: [.h24: 8], source: "test", timestamp: Date())
        s.recompute(); s.evaluateAlerts(); s.evaluateAlerts()
        #expect(s.intel.alertLog.count == 1 && s.intel.alerts[0].state == .fired, "once, then quiet for the day")
    }

    @Test func settingsDecodeFrom06() throws {
        let old = #"{"primaryProvider":"Auto","refreshSeconds":120,"currency":"EUR","alertThreshold":5,"depegAlerts":true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.refreshSeconds == 120 && s.currency == "EUR" && s.alertThreshold == 5)
        #expect(s.darkVariant == .dark && s.dayStartHour == 0 && s.alertBanner && s.alertBadge && !s.alertSound && s.quietHours == "off")
    }

    // MARK: share motion (design §16)

    @Test func animatedCardExportsMP4AndGIF() async throws {
        let s = store()
        var c = s.share; c.effect = .crt; c.motion = .animated
        let m = s.shareModel(c)
        let mp4 = try await ShareMotionExporter.export(m, format: .mp4)
        let asset = AVURLAsset(url: mp4)
        let d = try await asset.load(.duration).seconds
        #expect(abs(d - 3) < 0.15, "3 s")
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1080, height: 1080))
        let gif = try await ShareMotionExporter.export(m, format: .gif)
        let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 45, "15 fps × 3 s")
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyPixelWidth] as? Int == 540, "gif at half size")
    }

    @Test func countUpKeepsEachNumberFormat() {
        #expect(ShareCardView.countUp("▲ +3.51%", 0.5) == "▲ +1.76%")
        #expect(ShareCardView.countUp("$48,286.22", 0.5) == "$24,143.11")
        #expect(ShareCardView.countUp("$48,286", 0.5) == "$24,143")
        #expect(ShareCardView.countUp("−56.9pp", 0) == "−0.0pp")
        #expect(ShareCardView.countUp("$0.004", 0.5) == "$0.002")
        #expect(ShareCardView.countUp("1.234,56 €", 0.5) == "617,28 €")
        #expect(ShareCardView.countUp("$48,286.22", 1) == "$48,286.22" && ShareCardView.countUp("today", 0.3) == "today")
    }
}
