#if DEBUG
import PFCore
import PFCoreUI
import AppKit
import SwiftUI

/// DEBUG only: `--snapshots` walks every screen and writes PNGs of the app's own window
/// (plus rendered share cards) to the sandbox tmp directory, then quits. Used with the
/// mock market for deterministic screenshots.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(_ store: AppStore) {
        guard ProcessInfo.processInfo.arguments.contains("--snapshots") else { return }
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            store.mainWindow?.setContentSize(NSSize(width: 1280, height: 820))   // consistent README framing
            if ProcessInfo.processInfo.arguments.contains("--snapshots-chrome") {
                NSApp.activate(ignoringOtherApps: true)            // key window: coloured traffic lights
                store.mainWindow?.makeKeyAndOrderFront(nil)
            }
            let tel = "cg:solana"   // the demo's third asset (was TEL)
            let baseSteps: [(String, () -> Void)] = [
                ("03-overview", { store.go(.overview) }),
                ("03b-overview-pnl-1y", { store.overviewMode = .pnl; store.setOverviewRange(.y1) }),
                ("04-asset", { store.overviewMode = .value; store.setOverviewRange(.w1); store.openAsset(store.doc.assets.contains { $0.id == tel } ? tel : store.summary.positions.first?.asset.id ?? tel) }),
                ("05-target", { if let v = store.summary.positions.first { store.openTarget(v.asset.id) } }),
                ("05b-target-typed", { store.openTarget(tel, ""); type("25x", into: store.mainWindow) }),
                ("06-add-transaction", { store.go(.overview); store.openTx(TxDraft(asset: "SOL", amount: "3", price: "150")) }),
                ("07-palette", { store.tx = nil; store.openPalette() }),
                ("07b-palette-buy", { store.openPalette("buy sol 3 @ 150") }),
                ("07c-palette-typed", { store.openPalette(); type("buy sol 5", into: store.mainWindow) }),
                ("08-movers", { store.go(.movers) }),
                ("09-analytics", { store.go(.analytics) }),
                ("10-settings", { store.go(.settings) }),
                ("11-share", { store.go(.share) }),
                ("12-quick-share", { store.go(.overview); store.quickShare = true }),
            ]
            var steps = baseSteps
            if ProcessInfo.processInfo.arguments.contains("--stablecoin-shots") {
                // A USDC position in the throwaway demo ledger: on peg, then depegged.
                let usdc = AssetCatalog.known.first { $0.symbol == "USDC" }!
                @MainActor func pegQuote(_ p: String) { store.quotes[usdc.id] = Quote(price: Decimal(string: p)!, change: [.h24: -0.02], source: "CoinGecko", timestamp: Date().addingTimeInterval(-180)) }
                steps = [
                    ("30-stable-overview", {
                        if let pf = store.doc.portfolios.first?.id, !store.doc.assets.contains(where: { $0.id == usdc.id }) {
                            store.doc.assets.append(usdc)
                            store.doc.transactions.append(Transaction(portfolioID: pf, assetID: usdc.id, type: .buy, quantity: 18450, price: 1, timestamp: Date().addingTimeInterval(-86400 * 20)))
                        }
                        pegQuote("0.9998"); store.recompute(); store.go(.overview)
                    }),
                    ("31-stable-asset", { store.openAsset(usdc.id); pegQuote("0.9998"); store.recompute() }),
                    ("32-stable-depeg", { pegQuote("0.9712"); store.recompute(); store.openAsset(usdc.id) }),
                    ("33-stable-analytics", { pegQuote("0.9998"); store.recompute(); store.go(.analytics) }),
                ]
            }
            if ProcessInfo.processInfo.arguments.contains("--intel-shots") {
                seedIntelDemo(store)
                steps = [
                    ("40-changes-today", { store.go(.overview); store.wcPeriod = .today; store.go(.changes); store.loadAttributionHistory() }),
                    ("40b-changes-7d", { store.wcPeriod = .d7; store.loadAttributionHistory() }),
                    ("40c-changes-30d", { store.wcPeriod = .d30; store.loadAttributionHistory() }),
                    ("41-movers-mode", { store.toggleChangesMode() }),
                    ("42-benchmark", { store.analyticsUsesBenchmark = true; store.go(.benchmark); store.loadBenchmarkHistory() }),
                    ("43-watch", { store.go(.watch) }),
                    ("43b-watch-add", { store.openWatchAdd("LINK") }),
                    ("43c-convert", { store.watchDraft = nil; if let w = store.watchRows.first?.item { store.convertWatch(w) } }),
                    ("44-alerts", { store.tx = nil; store.go(.alerts) }),
                    ("44b-alert-setup", { store.openAlertSetup(subject: .asset(tel)); store.alertSetup?.line = "alert sol above 160" }),
                    ("44c-alert-review", { store.advanceAlertSetup() }),
                    ("44d-alert-empty-cmd", { store.alertSetup = AlertSetup() }),
                    ("45-scenarios", { store.alertSetup = nil; store.go(.scenarios) }),
                    ("46-settings", { store.settingsSection = "general"; store.go(.settings) }),
                    ("46b-settings-filter", { store.settingsFilter = "sync" }),
                    ("47-health", { store.settingsFilter = ""; store.go(.overview); store.healthPopover = true }),
                    ("48-leader", { store.healthPopover = false; store.leaderActive = true }),
                    ("49-keys", { store.leaderActive = false; store.keysOverlay = true }),
                    ("50-overview", { store.keysOverlay = false; store.go(.overview) }),
                    ("51-asset", { store.openAsset(tel) }),
                    ("52-palette-symbol", { store.openPalette("sol") }),
                    ("53-palette-alert", { store.openPalette("alert sol above 160") }),
                    ("54-palette-watch", { store.openPalette("watch sol 135 210") }),
                    ("55-empty-watch", { store.palette = nil; store.updateIntel { $0 = IntelDocument() }; store.go(.watch) }),
                    ("55b-empty-alerts", { store.go(.alerts) }),
                    ("56-share-changes", { store.share.card = .changes; store.share.period = .d7; store.go(.share); store.prepareShare() }),
                    ("56b-share-bench", { store.share.card = .benchmark; store.share.benchRange = "1Y"; store.prepareShare() }),
                    ("56c-share-perf", { store.share.card = .performance; store.share.period = .h24 }),
                    ("55c-empty-scenarios", { store.go(.scenarios) }),
                ]
            }
            if ProcessInfo.processInfo.arguments.contains("--agent-shots") {
                // 0.8 Agent Access UI with a throwaway credential (never the Keychain).
                store.agent.credentialOverride = "pfm_snapshot"
                let conn = 9
                steps = [
                    ("60-agent-settings-off", { store.go(.settings); store.selectSettingsSection("agents") }),
                    ("61-agent-settings-on", {
                        store.agentUpdate { $0.enabled = true; $0.mode = .readWrite }
                        store.agent.sessions[conn] = AgentRuntime.Session(id: conn, client: "Claude Desktop")
                        store.agent.lastConnected = ("Claude Desktop", Date())
                        _ = store.agentCallTool("pf_get_portfolio_context", .obj([]), connection: conn)
                        _ = store.agentCallTool("pf_get_what_changed", ["period": "7d"], connection: conn)
                    }),
                    ("61b-agent-connect", { store.settingsFilter = "claude" }),
                    ("62-agent-confirm", {
                        store.settingsFilter = ""
                        _ = store.agentCallTool("pf_add_transaction", ["type": "buy", "asset": "cg:solana", "amount": 5, "price": 148.2], connection: conn)
                    }),
                    ("63-agent-confirm-delete", {
                        if let c = store.agent.pending.first { store.agentResolve(c.id, confirm: false) }
                        if let t = store.doc.transactions.last { _ = store.agentCallTool("pf_delete_transaction", ["transaction_id": .str(t.id.uuidString)], connection: conn) }
                    }),
                    ("64-agent-activity", { if let c = store.agent.pending.first { store.agentResolve(c.id, confirm: false) }; store.agentActivityOpen = true }),
                    ("65-agent-status", { store.agentActivityOpen = false; _ = store.agentCallTool("pf_add_transaction", ["type": "buy", "asset": "cg:bitcoin", "amount": 0.01, "price": 90000], connection: conn); store.go(.overview) }),
                ]
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") && !ProcessInfo.processInfo.arguments.contains("--agent-shots") {
                seedDesignPortfolios(store)
                steps += [
                    ("13-switcher", { store.go(.overview); store.setContext(.portfolio(store.doc.portfolios[0].id)); store.openSwitcher() }),
                    ("14-all-portfolios", { store.switcher = nil; store.setContext(.all); store.go(.overview) }),
                    ("15-new-portfolio", { store.openNewPortfolio("SWING") }),
                    ("16-manage", { store.newPortfolio = nil; store.go(.portfolios) }),
                    ("16b-manage-confirm", { store.manage.sel = 2; store.requestDeletePortfolio(store.manageList[2].id) }),
                    ("17-empty", { store.manage.confirmDelete = nil; store.newPortfolio = NewPortfolioDraft(name: "SWING"); store.createPortfolio() }),
                    ("18-tx-in-all", { store.setContext(.all); store.go(.overview); store.openTx(TxDraft(asset: "BTC", amount: "0.05", price: "91000")) }),
                    ("19-palette-trade", { store.tx = nil; store.setContext(.portfolio(store.doc.portfolios[0].id)); store.openPalette("buy eth 0.5 @ 3500 in trading") }),
                    ("20-palette-portfolio", { store.openPalette("portfolio ") }),
                    ("21-analytics-all", { store.palette = nil; store.setContext(.all); store.analyticsMode = .pnl; store.go(.analytics) }),
                ]
            }
            for (name, step) in steps {
                step()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                capture(store.mainWindow, to: dir.appendingPathComponent(name + ".png"))
            }
            store.quickShare = false
            // 0.7 effects, full size, and a mid-animation frame.
            for e in ShareEffect.allCases {
                var c = store.share; c.card = .performance; c.effect = e; c.format = .square; c.theme = .terminal
                if let d = ShareRenderer.png(store.shareModel(c)) { emit("card07-effect-\(e.rawValue)", d) }
            }
            for t in [0.22, 0.6, 1.12, 1.5, 2.62, 2.9] {
                var c = store.share; c.card = .performance; c.period = .h24; c.effect = .glitch
                let r = ImageRenderer(content: ShareCardView(m: store.shareModel(c), progress: ShareCardView.motionProgress(at: t), time: t)); r.scale = 0.5
                if let cg = r.cgImage, let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { emit("glitch-\(Int(t * 100))", d) }
            }
            for st in ShareMotionStyle.allCases {
                for (card, fx) in [(ShareCardKind.performance, ShareEffect.glow), (.changes, .none)] {
                    for pr in [0.25, 0.55, 0.78] {
                        var c = store.share; c.card = card; c.period = card == .changes ? .d7 : .h24; c.effect = fx; c.motionStyle = st
                        let r = ImageRenderer(content: ShareCardView(m: store.shareModel(c), progress: pr)); r.scale = 0.5
                        if let cg = r.cgImage, let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                            emit("motion-\(st.rawValue)-\(card.rawValue)-\(Int(pr * 100))", d)
                        }
                    }
                }
            }
            // 0.7 cards, full size.
            for k in [ShareCardKind.changes, .benchmark] {
                var c = store.share; c.card = k; c.period = .d7; c.format = .square; c.theme = .terminal
                if let d = ShareRenderer.png(store.shareModel(c)) { emit("card07-\(k.rawValue)", d) }
                c.format = .landscape
                if let d = ShareRenderer.png(store.shareModel(c)) { emit("card07-\(k.rawValue)-landscape", d) }
            }
            for f in ShareFormat.mac {
                for t in ShareTheme.allCases {
                    var c = store.share
                    c.format = f; c.theme = t
                    if let d = ShareRenderer.png(store.shareModel(c)) {
                        try? d.write(to: dir.appendingPathComponent("card-\(f.rawValue)-\(t.rawValue).png"))
                        emit("card-\(f.rawValue)-\(t.rawValue)", d)
                    }
                }
            }
            var c = store.share
            c.privacy = .custom; c.custom = Set(ShareField.allCases); c.moverType = .impact
            if let d = ShareRenderer.png(store.shareModel(c)) { try? d.write(to: dir.appendingPathComponent("card-custom-all.png")) }
            renderWidgets(store, dir: dir)
            // Menu bar popover (README), on the demo portfolio with three books (throwaway data).
            for p in store.doc.portfolios.dropFirst(3) { try? store.doc.setArchived(p.id, true) }
            store.setContext(.portfolio(store.doc.portfolios[0].id))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let pop = ImageRenderer(content: MenuBarPopover().environment(store).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            pop.scale = 2
            if let cg = pop.cgImage, let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { emit("menubar", d) }
            print("snapshots:", dir.path)
            NSApp.terminate(nil)
        }
    }

    /// Widget layouts at macOS widget sizes, from the live snapshot and from the samples.
    static func renderWidgets(_ store: AppStore, dir: URL) {
        let now = Date()
        let live = store.makeWidgetSnapshot(for: nil)
        var hidden = WidgetOptions(); hidden.hideValue = true; hidden.movers = .impact
        let cases: [(String, WidgetPortfolioSnapshot, WidgetOptions)] = [
            ("live", live, WidgetOptions()), ("live-hidevalue", live, hidden),
            ("sample-positive", .previewPositive(now: now), WidgetOptions()), ("sample-negative", .previewNegative(now: now), WidgetOptions()),
            ("sample-privacy", .previewPrivacy(now: now), WidgetOptions()), ("sample-stale", .previewStale(now: now), WidgetOptions()),
            ("sample-empty", .previewEmpty(now: now), WidgetOptions()),
        ]
        for (name, snap, o) in cases {
            let m = WidgetModel(snap, o, now: now)
            let empty = !snap.hasPortfolio
            render(empty ? AnyView(EmptyWidget(hasSnapshot: true)) : AnyView(SmallWidget(m: m)), 170, 170, dir, "widget-small-\(name)")
            render(empty ? AnyView(EmptyWidget(hasSnapshot: true)) : AnyView(MediumWidget(m: m)), 364, 170, dir, "widget-medium-\(name)")
            render(empty ? AnyView(EmptyWidget(hasSnapshot: true)) : AnyView(LargeWidget(m: m)), 364, 382, dir, "widget-large-\(name)")
        }
    }

    private static func render(_ v: AnyView, _ w: CGFloat, _ h: CGFloat, _ dir: URL, _ name: String) {
        let content = v.font(Theme.mono(11)).foregroundStyle(Theme.text)
            .padding(16).frame(width: w, height: h).background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(12).background(Color(hex: 0x2b3440))
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        emit(name, png)
    }

    /// The team-signed app's container is protected from other processes; stream PNGs to stdout too.
    static func emit(_ name: String, _ data: Data) {
        guard ProcessInfo.processInfo.arguments.contains("--snapshots-stdout") else { return }
        print("PFPNG \(name) \(data.base64EncodedString())")
    }

    /// Sample 0.7 data for screenshots: watchlist, alert rules (one fired), c · b · u scenarios.
    @MainActor
    static func seedIntelDemo(_ store: AppStore) {
        let now = Date()
        func reg(_ sym: String) -> Asset? { AssetRegistry.shared.entries(symbol: sym).first.map { AssetRegistry.shared.asset(for: $0) } ?? AssetCatalog.known.first { $0.symbol == sym } }
        store.updateIntel { d in
            d = IntelDocument()
            d.migrations = ["0.6-notifications"]
            for (sym, add, entry, target, note) in [("AVAX", Decimal(26.9), Decimal(25), Decimal(40), "wait for unlock cliff"), ("LINK", 15.4, 13.5, 22, "scale in over 3 tranches"),
                                                     ("RENDER", 3.8, 3.6, nil, ""), ("HNT", 3.1, nil, nil, "just tracking")] as [(String, Decimal, Decimal?, Decimal?, String)] {
                if let a = reg(sym) { Watchlist.add(a, price: add, entry: entry, target: target, note: note, to: &d, now: now.addingTimeInterval(-86400 * 20)) }
            }
            let held = store.summary.positions.map(\.asset)
            var n = 0
            func rule(_ k: AlertKind, _ s: AlertSubject, _ t: Double, _ r: AlertRepeat = .once, fired: Bool = false, paused: Bool = false) {
                n += 1
                var a = AlertRule(number: n, kind: k, subject: s, threshold: t, repeatMode: r, paused: paused, createdAt: now.addingTimeInterval(-86400 * 10))
                if fired { a.state = .fired; a.firedAt = now.addingTimeInterval(-3600 * 3); a.unseen = true }
                d.alerts.append(a)
            }
            if let tel = held.first(where: { $0.symbol == "SOL" }) {
                rule(.priceAbove, .asset(tel.id), 140, fired: true)
                rule(.weightAbove, .asset(tel.id), 35, .cross)
            }
            rule(.drawdown, .portfolio(store.context.storageKey), 20, .cross)
            rule(.move24h, .anyHeld, 15, .daily)
            rule(.depeg, .anyStablecoin, 0.5, .cross)
            if let btc = held.first(where: { $0.symbol == "BTC" }) { rule(.priceBelow, .asset(btc.id), 80_000) }
            rule(.valueAbove, .portfolio(store.context.storageKey), 60_000)
            if let avax = reg("AVAX") { rule(.priceAbove, .asset(avax.id), 34, paused: true) }
            d.alertLog = [AlertEvent(at: now.addingTimeInterval(-3600 * 3), rule: d.alerts[0].id, number: 1, message: "SOL price ≥ $140.00", delivery: "banner · unseen")]
            let prices = Dictionary(uniqueKeysWithValues: store.summary.positions.compactMap { v in v.price.map { (v.asset.id, $0) } })
            Scenarios.createPresets(in: &d, prices: prices, now: now)
            for (key, mult) in [("c", 1.3), ("b", 2.5), ("u", 6.0)] {
                if let i = d.scenarios.firstIndex(where: { $0.key == key }) {
                    for (id, p) in prices where !Stablecoins.isStablecoin(id) { d.scenarios[i].targets[id] = ScenarioTarget(price: p * Decimal.of(mult), weight: key == "b" ? 30 : nil) }
                }
            }
        }
        Task { await store.refresh(auto: false) }   // price the watched assets
    }

    /// The design's portfolio set, for ui-testing snapshots only (in-memory store).
    static func seedDesignPortfolios(_ store: AppStore) {
        guard store.doc.portfolios.count == 1 else { return }
        func add(_ name: String, _ glyph: String, _ created: String, _ rows: [(String, Double, Double, String)]) {
            guard let p = try? store.doc.createPortfolio(name: name, glyph: glyph, now: DateFmt.parseYMD(created)!) else { return }
            store.doc.transactions += rows.map { cg, q, px, d in
                Transaction(portfolioID: p.id, assetID: "cg:" + cg, type: .buy, quantity: .of(q), price: .of(px), timestamp: DateFmt.parseYMD(d)!)
            }
        }
        add("LONG TERM", "∞", "2024-01-10", [("bitcoin", 0.14, 42000, "2024-01-10"), ("ethereum", 2.1, 2400, "2024-03-18")])
        add("TRADING", "⇄", "2025-06-02", [("zcash", 20, 190, "2026-08-30"), ("ethereum", 0.9, 3900, "2026-09-02"), ("bitcoin", 0.03, 95000, "2026-09-11")])
        add("DEGEN", "△", "2025-10-21", [("telcoin", 600000, 0.0039, "2025-10-21"), ("zcash", 3, 170, "2026-01-05")])
        add("SERGEY", "S", "2026-05-14", [("bitcoin", 0.01, 88000, "2026-05-14")])
        store.recompute()
    }

    static func type(_ text: String, into w: NSWindow?) {
        guard let w else { return }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            for ch in text {
                let s = String(ch)
                for t in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    static func capture(_ w: NSWindow?, to url: URL) {
        // --snapshots-chrome: the window frame view, so the real title bar and traffic lights are included.
        let chrome = ProcessInfo.processInfo.arguments.contains("--snapshots-chrome")
        guard let content = w?.contentView else { return }
        let v: NSView = chrome ? (content.superview ?? content) : content
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        emit(url.deletingPathExtension().lastPathComponent, png)
    }
}
#endif
