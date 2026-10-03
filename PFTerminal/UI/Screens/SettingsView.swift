import PFCore
import PFCoreUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var store = store
        let sections = store.settingsSections
        let pane = store.settingsPane
        let filtering = !store.settingsFilter.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(alignment: .top, spacing: 18) {
            // sidebar: filter · sections with status · health
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TT(">", 13, Theme.acc)
                    TextField("filter settings", text: $store.settingsFilter)
                        .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
                        .focused($filterFocused)
                        .onChange(of: store.settingsFilter) { store.settingsRow = nil }
                        .accessibilityIdentifier("settings-filter")
                    TT("/", 12, Theme.t4)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .overlay { Rectangle().stroke(filterFocused ? Theme.acc : Theme.border, lineWidth: 1) }
                VStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { i, sec in
                        let on = !filtering && sec.id == store.settingsSection
                        TermButton(action: { store.selectSettingsSection(sec.id) }, hoverBg: Theme.selected) {
                            HStack(spacing: 8) {
                                TT(on ? "›" : " ", 12, Theme.acc).frame(width: 10)
                                TT("⌘\(i + 1)", 11, Theme.t4).frame(width: 26, alignment: .leading)
                                TT(sec.title, 12, on ? Theme.t1 : Theme.t2).fixedSize()
                                Spacer(minLength: 6)
                                TT(sec.status, 11, sec.statusColor).lineLimit(1)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(on ? Theme.selected : .clear)
                        }
                        .accessibilityIdentifier("settings-section-" + sec.id)
                    }
                }
                Panel(title: "HEALTH", padding: .init(top: 12, leading: 10, bottom: 8, trailing: 10)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.dataHealth) { h in
                            let c = h.level == .ok ? Theme.pos : h.level == .warning ? Theme.warning : Theme.neg
                            let actionable = h.level != .ok && (h.asset != nil || h.area == .sync || h.area == .recovery)
                            TermButton(action: { if actionable { store.reviewFinding(h) } }, hoverBg: actionable ? Theme.selected : .clear) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    TT(h.level == .ok ? "✓" : h.level == .warning ? "!" : "✗", 11, c).frame(width: 10)
                                    TT(h.area.rawValue, 11, Theme.t3).frame(width: 64, alignment: .leading)
                                    TT(Self.trimArea(h.text, h.area.rawValue), 11, h.level == .ok ? Theme.t2 : c).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 300)

            // one section, or filter matches grouped by section
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    TT(pane.title, 15, Theme.t1, weight: .semibold, tracking: 0.6)
                    TT(pane.sub, 12, Theme.t3)
                    Spacer()
                }
                .padding(.bottom, 12).overlay(alignment: .bottom) { Hairline() }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        let offsets = rowOffsets(pane.groups)
                        ForEach(Array(pane.groups.enumerated()), id: \.element.id) { gi, g in
                            Panel(title: g.h, padding: .init(top: 14, leading: 6, bottom: 6, trailing: 6)) {
                                VStack(spacing: 0) {
                                    ForEach(Array(g.rows.enumerated()), id: \.element.id) { ri, r in
                                        row(r, focused: store.settingsRow == offsets[gi] + ri)
                                    }
                                }
                            }
                        }
                        if pane.groups.isEmpty {
                            TT("no settings match \"\(store.settingsFilter)\" · esc clears", 12, Theme.t3).padding(.top, 8)
                        }
                    }
                    .padding(.top, 8)   // room for the first panel's title
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, 14)
        .onAppear { store.refreshProviderHealth(); store.reloadSnapshots() }
        .onChange(of: store.settingsFocusFilter) { if store.settingsFocusFilter { filterFocused = true; store.settingsFocusFilter = false } }
    }

    /// "ledger valid · 17 tx" next to the "ledger" label reads "valid · 17 tx".
    static func trimArea(_ text: String, _ area: String) -> String {
        text.lowercased().hasPrefix(area + " ") ? String(text.dropFirst(area.count + 1)) : text
    }

    private func rowOffsets(_ groups: [SettingGroup]) -> [Int] {
        var o: [Int] = [], n = 0
        for g in groups { o.append(n); n += g.rows.count }
        return o
    }

    private func row(_ r: SettingRow, focused: Bool) -> some View {
        TermButton(action: { r.run?(1) }, hoverBg: r.run == nil ? .clear : Theme.selected) {
            HStack(spacing: 12) {
                TT(focused ? "›" : " ", 12, Theme.acc).frame(width: 8)
                TT(r.k, 12, Theme.t3)
                Spacer(minLength: 8)
                if !r.hint.isEmpty { TT(r.hint, 11, Theme.t4) }
                TT(r.display, 12, r.color).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(focused ? Theme.selected : .clear)
        }
        .accessibilityIdentifier("setting-" + r.k)
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
