import PFCore
import PFCoreUI
import SwiftUI

/// Alerts (design §07): one table for every rule type, the 30-day log and delivery.
struct AlertsView: View {
    @Environment(AppStore.self) private var store

    static let cols: [Columns.Col] = [.fixed(22), .fixed(44), .fixed(24), .fixed(140), .fixed(110), .fr(1.4), .fixed(120), .fixed(96), .fixed(96), .fixed(90)]

    var body: some View {
        let rows = store.alertRows
        let fired = rows.filter { !$0.rule.paused && $0.rule.state == .fired }.count
        let paused = rows.filter(\.rule.paused).count
        let armed = rows.count - fired - paused
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "ALERTS", sub: "evaluated on this Mac every \(store.settings.intervalLabel) · last " + (store.lastSuccess.map(DateFmt.hms) ?? "—") + (store.syncEnabled ? " · rules sync via iCloud" : " · nothing leaves the device")) {
                    IntelSyncBadge()
                    BracketButton("+ new alert n", color: Theme.acc) { store.openAlertSetup() }
                        .accessibilityIdentifier("alert-new")
                }
                if rows.isEmpty {
                    empty
                } else {
                    table(rows, title: "RULES · \(fired) fired · \(armed) armed · \(paused) paused")
                    Columns([.fr(1.6), .fr(1)], spacing: 18) {
                        log
                        delivery
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private func table(_ rows: [(rule: AlertRule, now: String, distance: Double?)], title: String) -> some View {
        let f = Fmt.current
        return Panel(title: title, padding: .init(top: 12, leading: 0, bottom: 4, trailing: 0)) {
            VStack(spacing: 0) {
                Columns(Self.cols) {
                    Color.clear; HeadCell("#", align: .leading); Color.clear; HeadCell("TYPE", align: .leading); HeadCell("SUBJECT", align: .leading)
                    HeadCell("CONDITION", align: .leading); HeadCell("NOW"); HeadCell("DISTANCE"); HeadCell("REPEAT"); HeadCell("LAST")
                }
                .frame(height: 26).padding(.leading, 4).padding(.trailing, 14).overlay(alignment: .bottom) { Hairline() }
                ForEach(Array(rows.enumerated()), id: \.element.rule.id) { i, x in
                    let r = x.rule, sel = i == store.alertSel
                    let fired = r.state == .fired && !r.paused
                    let near = x.distance.map { abs($0) <= 2 } ?? false
                    TableRow(selected: sel, height: store.settings.rowHeight, onSelect: { store.alertSel = i },
                             onOpen: { store.openAlertEdit(r) }, divider: i < rows.count - 1) {
                        Columns(Self.cols) {
                            RowMark(on: sel)
                            TT("#\(r.number)", 12, Theme.t3)
                            TT(r.paused ? "‖" : fired ? "⚑" : "●", 12, r.paused ? Theme.t4 : fired ? Theme.acc : Theme.t2)
                            TT(r.kind.label, 12, Theme.t2).lineLimit(1)
                            TT(store.alertSubjectLabel(r.subject), 12, Theme.t1, weight: .medium).lineLimit(1)
                            TT(AlertEngine.condition(r, fmt: f), 12, Theme.t2).lineLimit(1)
                            Cell(x.now, Theme.text)
                            Cell(fired ? "hit" : x.distance.map { f.num($0, 1) + AppStore.distanceUnit(r.kind) } ?? "—",
                                 fired || near ? Theme.acc : Theme.t3)
                            Cell(r.repeatMode == .cross ? "cross" : r.repeatMode.rawValue, Theme.t3)
                            Cell(r.firedAt.map { Calendar.current.isDateInToday($0) ? DateFmt.hm($0) : String(DateFmt.ymd($0).dropFirst(5)) } ?? "—", Theme.t3)
                        }
                        .padding(.leading, 4).padding(.trailing, 14)
                        .opacity(r.paused ? 0.55 : 1)
                    }
                    .accessibilityIdentifier("alert-row-\(r.number)")
                }
            }
        }
        .accessibilityIdentifier("alerts-table")
    }

    private var log: some View {
        let events = store.intel.alertLog.suffix(8).reversed()
        return Panel(title: "LOG · 30D", fill: true) {
            VStack(alignment: .leading, spacing: 6) {
                if events.isEmpty { TT("nothing fired in the last 30 days", 12, Theme.t4) }
                ForEach(Array(events)) { e in
                    HStack(spacing: 12) {
                        TT(DateFmt.ymd(e.at) + " " + DateFmt.hm(e.at), 11, Theme.t4)
                        TT("#\(e.number)", 11, Theme.t3).frame(width: 34, alignment: .leading)
                        TT(e.message, 11, Theme.t2).lineLimit(1)
                        Spacer(minLength: 8)
                        TT(e.delivery, 11, e.delivery.hasPrefix("queued") ? Theme.warning : Theme.t4)
                    }
                }
            }
        }
    }

    private var delivery: some View {
        let s = store.settings
        return Panel(title: "DELIVERY", fill: true) {
            VStack(alignment: .leading, spacing: 6) {
                kv("notification", s.alertBanner ? "macOS banner" + (s.alertSound ? " · sound" : "") : "off")
                kv("menu bar", s.alertBadge ? "popover · newest until seen" : "off")
                kv("runs when", "app or menu bar item open")
                kv("quiet hours", s.quietHours == "off" ? "off" : s.quietHours + " · queue")
                kv("rules", "on this Mac · not synced")
                HStack { Spacer(); BracketButton("delivery settings →") { store.selectSettingsSection("alerts"); store.go(.settings) } }
            }
        }
    }

    private var empty: some View {
        Panel(title: "NO ALERT RULES") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rules watch prices, position P&L, portfolio value, weight, 24h moves, stablecoin pegs, scenario targets and drawdown. They run on this Mac after every price refresh; stale prices never fire anything.")
                    .font(Theme.mono(12)).foregroundStyle(Theme.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                TT("try   alert btc below 80000 · alert any move 15 · alert main drawdown 30", 12, Theme.t3)
                BracketButton("+ new alert n", color: Theme.acc) { store.openAlertSetup() }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .accessibilityIdentifier("alerts-empty")
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { TT(k, 12, Theme.t3); Spacer(); TT(v, 12, Theme.t2) }
    }
}

/// n / a / ↵: command → parsed fields → review (backtest, overlaps) → arm (design §08).
struct AlertSetupSheet: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        let s = store.alertSetup ?? AlertSetup()
        let rule = store.setupRule(s)
        VStack(spacing: 0) {
            HStack {
                TT(s.review ? "\(s.editing == nil ? "ARM" : "SAVE") ALERT #\(rule?.number ?? 0)" : s.editing == nil ? "NEW ALERT" : "EDIT ALERT", 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT(s.review ? "↵ \(s.editing == nil ? "arm" : "save") · esc back" : "←→ repeat · ↵ review · esc cancel", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            if s.review, let rule { review(rule, s) } else { compose(s, rule) }
        }
        .frame(width: 620)
    }

    private func compose(_ s: AlertSetup, _ rule: AlertRule?) -> some View {
        let f = Fmt.current
        let parsed = store.parseAlert(s.line)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TT(">", 13, Theme.acc)
                TextField("alert ada below .24", text: Binding(get: { store.alertSetup?.line ?? "" }, set: { store.alertSetup?.line = $0 }))
                    .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
                    .focused($focused)
                    .accessibilityIdentifier("alert-command")
            }
            if let rule {
                VStack(alignment: .leading, spacing: 7) {
                    kv("type", rule.kind.label)
                    kv("subject", store.alertSubjectLabel(rule.subject) + subjectNote(rule.subject))
                    kv("condition", AlertEngine.condition(rule, fmt: f))
                    let inputs = store.alertInputs()
                    let rd = AlertEngine.read(rule, inputs)
                    if let d = AlertEngine.distance(rule, rd, inputs) {
                        kv("now", store.alertNowText(rule, rd) + " · " + f.num(d, 1) + AppStore.distanceUnit(rule.kind) + " away")
                    }
                    HStack(spacing: 0) {
                        TT("repeat", 12, Theme.t3).frame(width: 110, alignment: .leading)
                        Tabs(items: AlertRepeat.allCases.map { TabItem(id: $0.rawValue, label: $0 == .cross ? "every cross" : $0.rawValue) }, selected: s.repeatMode.rawValue, hPad: 10, vPad: 2) {
                            store.alertSetup?.repeatMode = AlertRepeat(rawValue: $0) ?? .once
                        }
                    }
                    kv("reset", rule.kind == .depeg ? "back within half the band" : "after \(f.num(s.hysteresis, 0))\(AppStore.distanceUnit(rule.kind)) hysteresis")
                    kv("notify", store.settings.alertBanner ? "banner + menu bar" : "menu bar only")
                }
            } else if case let .failure(e) = parsed {
                VStack(alignment: .leading, spacing: 4) {
                    TT(e.description, 12, s.line.split(separator: " ").count > 2 ? Theme.neg : Theme.t3)
                    ForEach(Array(AlertCommand.types.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 0) { TT(t.key, 12, Theme.t1).frame(width: 90, alignment: .leading); TT(t.grammar, 12, Theme.t4) }
                    }
                }
            }
            HStack {
                TT("same grammar as ⌘K · alert <asset|portfolio|any> <condition> <number>", 11, Theme.t4)
                Spacer()
                BracketButton("cancel", color: Theme.t2) { store.alertSetup = nil }
                BracketButton("review ↵", color: rule != nil ? Theme.acc : Theme.faint) { store.advanceAlertSetup() }.disabled(rule == nil)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }

    private func review(_ r: AlertRule, _ s: AlertSetup) -> some View {
        let f = Fmt.current
        let rv = store.setupReview(r)
        return VStack(alignment: .leading, spacing: 10) {
            TT(store.alertSubjectLabel(r.subject) + " " + AlertEngine.condition(r, fmt: f) + " · " + (r.repeatMode == .cross ? "every cross" : r.repeatMode.rawValue), 13, Theme.t1)
            VStack(alignment: .leading, spacing: 6) {
                if let fired = rv.fired {
                    kv("would have fired · 30d", fired.isEmpty ? "never" : "\(fired.count)× · " + fired.suffix(3).map { String(DateFmt.ymd($0).dropFirst(5)) }.joined(separator: " · "),
                       fired.count > 4 ? Theme.warning : Theme.t2)
                } else if r.subject.assetID != nil, [.priceAbove, .priceBelow, .target].contains(r.kind) {
                    kv("would have fired · 30d", store.historyPending ? "loading history…" : "no price history")
                }
                if let a = rv.atThreshold { kv("position at threshold", a) }
                kv("overlaps", rv.overlaps.isEmpty ? "none" : rv.overlaps.map { "#\($0.number) " + AlertEngine.condition($0, fmt: f) }.joined(separator: " · "),
                   rv.overlaps.isEmpty ? Theme.t2 : Theme.warning)
                kv("stored", "on this Mac · evaluated after each refresh")
            }
            .padding(12)
            .overlay(Rectangle().stroke(Theme.overlayBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            HStack {
                Spacer()
                BracketButton("back", color: Theme.t2) { store.alertSetup?.review = false }
                BracketButton((s.editing == nil ? "arm alert" : "save alert") + " ↵", color: Theme.acc) { store.advanceAlertSetup() }
                    .accessibilityIdentifier("alert-arm")
            }
        }
        .padding(16)
    }

    private func subjectNote(_ s: AlertSubject) -> String {
        guard case let .asset(a) = s else { return "" }
        if store.heldAnywhere.contains(a) { return " · held" }
        if store.watchContext(a)?.isActive == true { return " · watched" }
        return " · not held"
    }

    private func kv(_ k: String, _ v: String, _ c: Color = Theme.t2) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            TT(k, 12, Theme.t3).frame(width: 170, alignment: .leading)
            TT(v, 12, c).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
