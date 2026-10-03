import PFCore
import PFCoreUI
import Foundation

// Alerts (design §07, §08): rules in intel.json, evaluated on this Mac after every refresh.
// Replaces 0.6's two notification switches (migrated into rules #n "24h move" and "depeg").
// Notifications carry percentages and prices, never amounts held (they show on a locked screen).

struct AlertSetup: Equatable {
    var editing: UUID?
    var line = "alert "
    var repeatMode: AlertRepeat = .once
    var hysteresis: Double = 2
    var note = ""
    /// false: composing (command + parsed fields) · true: review before arming.
    var review = false
    var typeSel = 0
}

extension AppStore {
    // MARK: inputs + evaluation

    func alertInputs(now: Date = Date()) -> AlertInputs {
        let all = summary(for: .all)
        var pnl: [AssetID: Double] = [:], weights: [AssetID: Double] = [:]
        for v in all.positions {
            if let r = v.returnPct { pnl[v.asset.id] = r }
            if let a = v.allocation { weights[v.asset.id] = a }
        }
        var values: [String: Decimal] = [PortfolioContext.all.storageKey: all.totalValue]
        for p in doc.livePortfolios { values[PortfolioContext.portfolio(p.id).storageKey] = summary(for: .portfolio(p.id)).totalValue }
        // Drawdown needs reconstructed history: only for portfolios a rule asks about.
        var dd: [String: Double] = [:]
        for r in intel.alerts where r.kind == .drawdown && !r.paused {
            guard case let .portfolio(k) = r.subject, dd[k] == nil, let c = PortfolioContext(storageKey: k) else { continue }
            let chart = portfolioChart(start: ChartRange.all.start(now: now, firstTransaction: summary(for: c).firstDate), history: .all, in: c)
            if chart.twr.count > 1 { dd[k] = PortfolioHistoryEngine.drawdown(chart.twr).current * 100 }
        }
        var pegs: [AssetID: PegCheck] = [:]
        for id in heldAnywhere.union(intel.watchlist.filter(\.isActive).map(\.assetID)) { if let c = pegCheck(id) { pegs[id] = c } }
        let targets = Scenarios.base(intel)?.targets.mapValues(\.price) ?? [:]
        // 0.6's 24h alert input: the flow-adjusted 24h change, only when nothing is unpriced.
        var moves: [String: Double] = [:]
        func move(_ s: PortfolioSummary, _ k: String) { if !s.isPartial, let p = s.change24hPct { moves[k] = p } }
        move(all, PortfolioContext.all.storageKey)
        move(context == .all ? all : summary(for: context), AlertSubject.activePortfolio)
        for p in doc.livePortfolios { move(summary(for: .portfolio(p.id)), PortfolioContext.portfolio(p.id).storageKey) }
        return AlertInputs(now: now, quotes: quotes, staleAfter: max(2 * TimeInterval(settings.refreshSeconds), 300), held: heldAnywhere,
                           positionPnL: pnl, weights: weights, portfolioValues: values, drawdowns: dd, pegs: pegs, baseTargets: targets,
                           portfolioChange24h: moves)
    }

    /// After every refresh (and after rule edits): fire, log, deliver.
    func evaluateAlerts() {
        retryIntelIfNeeded()
        guard intelReadOnly == nil, !intel.alerts.isEmpty else { return }
        let now = Date()
        let inputs = alertInputs(now: now)
        var rules = intel.alerts
        let fired = AlertEngine.evaluate(&rules, inputs)
        let quiet = settings.isQuiet(now)
        var events: [AlertEvent] = []
        for f in fired {
            guard let r = rules.first(where: { $0.id == f.rule }) else { continue }
            let text = alertMessage(r, f.reading)
            let delivery = !settings.alertBanner ? "menu bar only" : quiet ? "queued · quiet hours" : "banner"
            events.append(AlertEvent(at: now, rule: r.id, number: r.number, message: text, delivery: delivery))
            if settings.alertBanner && !quiet {
                if r.kind == .move24h, case .portfolio = r.subject {
                    Notifier.postMove(pct: f.reading.value, fmt: .current)      // the 0.6 notification, unchanged
                } else {
                    Notifier.postAlert(id: "pf.alert.\(r.number)", title: "pf · ⚑ #\(r.number) " + alertSubjectLabel(r.subject), body: text, sound: settings.alertSound)
                }
            }
            diagnostics.record(.alert, .info, "alert-fired")
        }
        // Quiet hours over: deliver what waited, once.
        var log = intel.alertLog
        if !quiet && settings.alertBanner {
            for i in log.indices where log[i].delivery == "queued · quiet hours" {
                Notifier.postAlert(id: "pf.alert.\(log[i].number)", title: "pf · ⚑ #\(log[i].number) (during quiet hours)", body: log[i].message, sound: false)
                log[i].delivery = "banner · after quiet hours"
            }
        }
        guard rules != intel.alerts || !events.isEmpty || log != intel.alertLog else { return }
        updateIntel { d in
            d.alerts = rules
            d.alertLog = log + events
            d.trimLog(now: now)
        }
        if let first = events.first { message = "⚑ #\(first.number) " + first.message }
    }

    /// "TAO price ≤ $320.00 · $318.40" — prices and percentages only.
    func alertMessage(_ r: AlertRule, _ rd: AlertEngine.Reading) -> String {
        let f = Fmt.current
        let subj = rd.asset.map { asset($0)?.symbol ?? watchContext($0)?.asset.symbol ?? $0 } ?? alertSubjectLabel(r.subject)
        let now: String = {
            switch r.kind {
            case .priceAbove, .priceBelow, .target: return f.price(Decimal.of(rd.value))
            case .valueAbove, .valueBelow: return "crossed"
            case .pnlAbove, .pnlBelow, .move24h: return f.pct(rd.value, 1)
            case .weightAbove: return f.num(rd.value, 1) + "%"
            case .depeg: return f.pct(rd.value, 2) + " off peg"
            case .drawdown: return f.num(rd.value, 1) + "%"
            }
        }()
        return "\(subj) " + AlertEngine.condition(r, fmt: f) + " · " + now
    }

    func alertSubjectLabel(_ s: AlertSubject) -> String {
        switch s {
        case let .asset(a): return asset(a)?.symbol ?? watchContext(a)?.asset.symbol ?? a
        case let .portfolio(k):
            if k == AlertSubject.activePortfolio { return "active portfolio" }
            return PortfolioContext(storageKey: k).map { doc.displayName($0) } ?? k
        case .anyHeld: return "any held"
        case .anyStablecoin: return "any stablecoin"
        }
    }

    // MARK: table

    /// Fired first, then armed by distance, paused last.
    var alertRows: [(rule: AlertRule, now: String, distance: Double?)] {
        let inputs = alertInputs()
        return intel.alerts.map { r -> (AlertRule, String, Double?) in
            let rd = AlertEngine.read(r, inputs)
            let now = alertNowText(r, rd)
            return (r, now, AlertEngine.distance(r, rd, inputs))
        }
        .sorted { a, b in
            func rank(_ r: AlertRule) -> Int { r.paused ? 2 : r.state == .fired ? 0 : 1 }
            if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            return abs(a.2 ?? .infinity) < abs(b.2 ?? .infinity)
        }
        .map { (rule: $0.0, now: $0.1, distance: $0.2) }
    }

    /// The NOW column: the measured value in the rule's own unit.
    func alertNowText(_ r: AlertRule, _ rd: AlertEngine.Reading?) -> String {
        guard let rd else { return "—" }
        let f = Fmt.current
        let who = rd.asset.map { (asset($0)?.symbol ?? watchContext($0)?.asset.symbol ?? $0) + " " } ?? ""
        switch r.kind {
        case .priceAbove, .priceBelow, .target: return f.price(Decimal.of(rd.value))
        case .valueAbove, .valueBelow: return f.money(Decimal.of(rd.value), 0)
        case .pnlAbove, .pnlBelow: return f.pct(rd.value, 1)
        case .weightAbove, .drawdown: return f.num(rd.value, 1) + "%"
        case .move24h: return who + f.num(abs(rd.value), 1) + "%"
        case .depeg: return who + f.pct(rd.value, 2)
        }
    }

    /// Unit of a rule's distance: % for price / value, pp otherwise.
    static func distanceUnit(_ k: AlertKind) -> String {
        [.priceAbove, .priceBelow, .target, .valueAbove, .valueBelow].contains(k) ? "%" : "pp"
    }

    func markAlertsSeen() {
        guard intel.alerts.contains(where: \.unseen) else { return }
        updateIntel { d in for i in d.alerts.indices { d.alerts[i].unseen = false } }
    }

    // MARK: rule actions

    func togglePause(_ id: UUID) {
        updateIntel { d in if let i = d.alerts.firstIndex(where: { $0.id == id }) { d.alerts[i].paused.toggle() } }
        if let r = intel.alerts.first(where: { $0.id == id }) { message = "#\(r.number) " + (r.paused ? "paused" : "resumed") }
    }

    func rearm(_ id: UUID) {
        updateIntel { d in
            if let i = d.alerts.firstIndex(where: { $0.id == id }) { d.alerts[i].state = .armed; d.alerts[i].unseen = false }
        }
        if let r = intel.alerts.first(where: { $0.id == id }) { message = "✓ #\(r.number) re-armed" }
    }

    func requestDeleteAlert(_ id: UUID) {
        guard let r = intel.alerts.first(where: { $0.id == id }) else { return }
        if alertConfirmDelete == id {
            updateIntel { d in d.alerts.removeAll { $0.id == id } }
            alertConfirmDelete = nil
            alertSel = max(0, min(alertSel, intel.alerts.count - 1))
            message = "✓ #\(r.number) deleted"
        } else {
            alertConfirmDelete = id
            message = "⌫ again to delete #\(r.number) · esc keeps it"
        }
    }

    // MARK: setup (command → fields → review → arm)

    /// `a` on an asset / watch row prefills the subject (and the planned entry for a watch row).
    func openAlertSetup(subject: AlertSubject? = nil) {
        var s = AlertSetup()
        if let subject {
            let sym = alertSubjectLabel(subject).lowercased()
            if case let .asset(a) = subject, let e = watchContext(a)?.entry, watchContext(a)?.isActive == true {
                s.line = "alert \(sym) below \(e)"
            } else {
                s.line = "alert \(sym) "
            }
        }
        alertSetup = s
    }

    func openAlertEdit(_ r: AlertRule) {
        alertSetup = AlertSetup(editing: r.id, line: Self.commandLine(r, subject: alertSubjectLabel(r.subject).lowercased()),
                                repeatMode: r.repeatMode, hysteresis: r.hysteresis, note: r.note ?? "")
    }

    /// A rule written back as the command that makes it (edit starts from the grammar).
    static func commandLine(_ r: AlertRule, subject: String) -> String {
        let t = Fmt.current.num(r.threshold, r.threshold < 1 ? 4 : 2).replacingOccurrences(of: ",", with: "")
        switch r.kind {
        case .priceAbove: return "alert \(subject) above \(t)"
        case .priceBelow: return "alert \(subject) below \(t)"
        case .pnlAbove: return "alert \(subject) pnl above \(t)"
        case .pnlBelow: return "alert \(subject) pnl below \(t)"
        case .valueAbove: return "alert \(subject) value above \(t)"
        case .valueBelow: return "alert \(subject) value below \(t)"
        case .weightAbove: return "alert \(subject) weight \(t)"
        case .move24h: return "alert \(r.subject == .anyHeld ? "any" : subject) move \(t)"
        case .depeg: return "alert \(r.subject == .anyStablecoin ? "any" : subject) depeg \(t)"
        case .target: return "alert \(subject) target"
        case .drawdown: return "alert \(subject) drawdown \(t)"
        }
    }

    func parseAlert(_ line: String) -> Result<AlertCommand.Draft, AlertCommand.Failure> {
        AlertCommand.parse(line, asset: { s in
            self.resolveAsset(s)?.id ?? self.registryUnique(s)?.id
        }, portfolio: { s in
            if s == "all" { return PortfolioContext.all.storageKey }
            return self.doc.livePortfolios.first { $0.name.lowercased() == s }.map { PortfolioContext.portfolio($0.id).storageKey }
        })
    }

    /// The rule the setup would arm (nil while the command doesn't parse).
    func setupRule(_ s: AlertSetup) -> AlertRule? {
        guard case let .success(d) = parseAlert(s.line) else { return nil }
        let number = s.editing.flatMap { id in intel.alerts.first { $0.id == id }?.number } ?? intel.nextAlertNumber
        return AlertRule(id: s.editing ?? UUID(), number: number, kind: d.kind, subject: d.subject, threshold: d.threshold,
                         repeatMode: d.kind == .depeg && s.repeatMode == .once ? .cross : s.repeatMode,
                         hysteresis: s.hysteresis, createdAt: Date(), note: s.note.isEmpty ? nil : s.note)
    }

    /// Review numbers: 30d backtest (price rules), overlapping rules, position value at the threshold.
    func setupReview(_ r: AlertRule) -> (fired: [Date]?, overlaps: [AlertRule], atThreshold: String?) {
        let id = r.subject.assetID
        let series = id.flatMap { assetSeries($0, .m1) }
        let fired = AlertEngine.backtest(r, series: series, baseTarget: id.flatMap { Scenarios.base(intel)?.targets[$0]?.price })
        let atThreshold: String? = {
            guard let id, [.priceAbove, .priceBelow].contains(r.kind), let v = summary(for: .all).valuation(id), let val = v.value else { return nil }
            let at = v.position.quantity * Decimal.of(r.threshold)
            return Fmt.current.money(at, 0) + " · " + Fmt.current.signed(at - val, 0)
        }()
        return (fired, AlertEngine.overlaps(r, in: intel.alerts), atThreshold)
    }

    func advanceAlertSetup() {
        guard var s = alertSetup else { return }
        guard let r = setupRule(s) else {
            if case let .failure(e) = parseAlert(s.line) { message = "✗ " + e.description }
            return
        }
        if !s.review {
            s.review = true
            alertSetup = s
            if let id = r.subject.assetID { loadReferenceHistory(asset(id) ?? watchContext(id)?.asset ?? Asset(id: id, symbol: alertSubjectLabel(r.subject), name: ""), .m1) }
            return
        }
        let ok = updateIntel { d in
            if let i = d.alerts.firstIndex(where: { $0.id == r.id }) {
                var x = r
                x.createdAt = d.alerts[i].createdAt
                // An edit that changes what the rule watches starts armed again.
                if d.alerts[i].kind == x.kind && d.alerts[i].subject == x.subject && d.alerts[i].threshold == x.threshold {
                    x.state = d.alerts[i].state; x.firedAt = d.alerts[i].firedAt
                }
                d.alerts[i] = x
            } else {
                d.alerts.append(r)
            }
        }
        guard ok else { return }
        alertSetup = nil
        if settings.alertBanner { Notifier.requestAuthorization() }
        message = "✓ #\(r.number) \(s.editing == nil ? "armed" : "saved") · " + alertSubjectLabel(r.subject) + " " + AlertEngine.condition(r, fmt: .current)
        if screen != .alerts { go(.alerts) }
        if let i = alertRows.firstIndex(where: { $0.rule.id == r.id }) { alertSel = i }
        evaluateAlerts()
    }
}
