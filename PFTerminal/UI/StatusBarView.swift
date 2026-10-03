import PFCore
import PFCoreUI
import SwiftUI

/// 0.7 status bar (design §14): five fixed zones, one flexible slot.
///   ① PF · ② views (+ the off-tab screen) · ③ message slot · ④ ⚑ unseen alerts · ⑤ health
/// Quiet when healthy ("● live 29s"), specific when not. The portfolio lives in the title bar.
struct StatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            PFGlyph(size: 12, color: Theme.onAccent)                                   // ①
                .padding(.horizontal, 8).frame(maxHeight: .infinity).background(Theme.acc)
                .accessibilityLabel("PF Terminal")
            HStack(spacing: 4) {                                                       // ②
                ForEach(0..<AppStore.tabs.count, id: \.self) { i in
                    let on = store.activeTab == i
                    TermButton(action: { store.goTab(i) }) {
                        TT(store.tabLabel(i) + (on ? "*" : " "), 11, on ? Theme.t1 : Theme.t3).fixedSize().padding(.horizontal, 6)
                    }
                    .accessibilityIdentifier("tab-\(i + 1)")
                }
                if let off = store.offTabLabel { TT(off + "*", 11, Theme.t1).fixedSize().padding(.horizontal, 6) }
            }
            .disabled(!store.hasPortfolio)
            let slot = store.messageSlot                                               // ③
            TT(slot.text, 11, color(slot.tone))
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("status-message")
            if store.unseenAlerts > 0 {                                                // ④
                TermButton(action: { store.go(.alerts) }) { TT("⚑ \(store.unseenAlerts)", 11, Theme.acc).fixedSize() }
                    .help("alerts fired · open Alerts")
                    .accessibilityLabel("\(store.unseenAlerts) alert\(store.unseenAlerts == 1 ? "" : "s") fired")
                    .accessibilityIdentifier("status-alerts")
            }
            let h = store.health                                                       // ⑤
            TermButton(action: { store.healthPopover.toggle() }) {
                HStack(spacing: 6) {
                    TT(h.glyph, 11, store.healthColor(h))
                    TT(h.text, 11, h.level == .ok ? Theme.t3 : store.healthColor(h))
                }
                .fixedSize().padding(.trailing, 12)
            }
            .help("health · click for detail")
            .accessibilityLabel("health: " + h.text)
            .accessibilityIdentifier("status-health")
        }
        .frame(height: 24)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.chromeBorder).frame(height: 1) }
    }

    private func color(_ t: AppStore.SlotTone) -> Color {
        switch t { case .hint: Theme.t4; case .event: Theme.t1; case .success: Theme.pos; case .failure: Theme.neg; case .accent: Theme.acc }
    }
}

/// Click ⑤: prices · feeds · icloud · ledger · recovery, from the existing health signals.
struct HealthPopover: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { TT("HEALTH", 11, Theme.t1, tracking: 0.66); Spacer(); TT("click ⑤ · esc", 11, Theme.t4) }
                .padding(.horizontal, 14).frame(height: 30)
                .overlay(alignment: .bottom) { Hairline() }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.healthRows, id: \.k) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TT(r.ok ? "●" : "▲", 11, r.ok ? Theme.pos : Theme.warning).frame(width: 12)
                        TT(r.k, 12, Theme.t3).frame(width: 70, alignment: .leading)
                        TT(r.v, 12, Theme.text)
                    }
                }
            }
            .padding(14)
            HStack(spacing: 6) {
                BracketButton("refresh now ⌘R", color: Theme.acc) { store.healthPopover = false; Task { await store.refresh(auto: false) } }
                BracketButton("data + sync →") { store.healthPopover = false; store.settingsSection = "sync"; store.go(.settings) }
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
        }
        .frame(width: 470)
        .background(Theme.raised)
        .overlay(Rectangle().strokeBorder(Theme.overlayBorder, lineWidth: 1))
        .shadow(color: .black.opacity(Theme.isLight ? 0.16 : 0.5), radius: 18, y: 8)
        .accessibilityIdentifier("health-popover")
    }
}

/// `?`: every key for the current view (design §14: "? anywhere shows the full key list").
struct KeysOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { TT("KEYS", 12, Theme.t1, tracking: 0.72); Spacer(); TT("esc close", 11, Theme.t4) }
                .padding(.horizontal, 16).frame(height: 34).overlay(alignment: .bottom) { Hairline() }
            HStack(alignment: .top, spacing: 28) {
                column("GLOBAL", [("command palette", "⌘K"), ("go to …", "g + key"), ("tabs", "1 2 3 4"), ("switch portfolio", "⌘P · [ ]"),
                                  ("settings", "⌘,"), ("share", "⌘⇧S"), ("add transaction", "⌘N"), ("refresh", "⌘R"), ("lock", "⌘L"), ("this list", "?")])
                column("THIS VIEW", store.viewKeys)
            }
            .padding(16)
        }
        .frame(width: 640)
    }

    private func column(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(title)
            ForEach(rows, id: \.0) { r in HStack { TT(r.0, 12, Theme.t2); Spacer(); TT(r.1, 12, Theme.t1) } }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension AppStore {
    var viewKeys: [(String, String)] {
        switch screen {
        case .overview: [("select", "↑↓"), ("open asset", "↵"), ("chart range", "←→"), ("value / p&l", "v"), ("what changed", "d")]
        case .changes: [("range", "←→"), ("open asset", "↑↓ ↵"), ("movers", "m"), ("back", "esc")]
        case .movers: [("select", "↑↓"), ("open", "↵"), ("% / $", "p"), ("range", "←→"), ("what changed", "m")]
        case .analytics, .benchmark: [("benchmark / overview", "b"), ("range", "←→")]
        case .watch: [("select", "↑↓"), ("watch asset", "n"), ("edit", "e"), ("alert", "a"), ("convert", "⌘↵"), ("remove", "⌫")]
        case .alerts: [("select", "↑↓"), ("edit", "↵"), ("pause", "space"), ("re-arm", "r"), ("delete", "⌫"), ("new", "n")]
        case .scenarios: [("switch", "c b u"), ("asset", "↑↓"), ("edit target", "↵"), ("new", "n"), ("duplicate", "⌘D"), ("rename", "r"), ("delete", "⌫")]
        case .asset: [("alert", "a"), ("target", "t"), ("period", "←→"), ("transactions", "↑↓"), ("edit / delete tx", "e · ⌫")]
        case .settings: [("section", "↑↓"), ("into rows", "⇥"), ("cycle value", "←→"), ("filter", "/"), ("back", "esc")]
        default: [("back", "esc")]
        }
    }
}
