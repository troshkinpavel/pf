import PFCore
import PFCoreUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var filterFocused: Bool

    /// Design §13: full-height sidebar | vertical divider | one section at a time.
    /// Header = the screen padding (22) + ScreenHeader (28 + 14): the sidebar's filter row matches it.
    static let sidebarWidth: CGFloat = 320, headerHeight: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: Self.sidebarWidth)
            Rectangle().fill(Theme.border).frame(width: 1)
            pane
        }
        .onAppear { store.refreshProviderHealth(); store.reloadSnapshots() }
        .onChange(of: store.settingsFocusFilter) { if store.settingsFocusFilter { filterFocused = true; store.settingsFocusFilter = false } }
    }

    // MARK: sidebar: filter · sections with status · health

    private var sidebar: some View {
        @Bindable var store = store
        let filtering = !store.settingsFilter.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TT(">", 13, Theme.acc)
                TextField("filter settings", text: $store.settingsFilter)
                    .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
                    .focused($filterFocused)
                    .onChange(of: store.settingsFilter) { store.settingsRow = nil }
                    .accessibilityIdentifier("settings-filter")
                Kbd("/")
            }
            .padding(.horizontal, 22).frame(height: Self.headerHeight)
            .overlay(alignment: .bottom) { Hairline() }

            VStack(spacing: 0) {
                ForEach(Array(store.settingsSections.enumerated()), id: \.element.id) { i, sec in
                    let on = !filtering && sec.id == store.settingsSection
                    TermButton(action: { store.selectSettingsSection(sec.id) }, hoverBg: Theme.hover) {
                        HStack(spacing: 8) {
                            TT(on ? "›" : " ", 12, Theme.acc).frame(width: 10)
                            TT(i < 9 ? "⌘\(i + 1)" : "⌘0", 11, Theme.t4).frame(width: 24, alignment: .leading)
                            TT(sec.title, 12, Theme.t1, weight: on ? .medium : .regular).fixedSize()
                            Spacer(minLength: 8)
                            TT(sec.status, 11, sec.statusColor).lineLimit(1)
                        }
                        // Follows Settings › appearance › density, like every table.
                        .padding(.leading, 10).padding(.trailing, 22).frame(height: store.settings.rowHeight + 4)
                        .background(on ? Theme.selected : .clear)
                    }
                    .accessibilityIdentifier("settings-section-" + sec.id)
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 16)

            Panel(title: "HEALTH", padding: .init(top: 14, leading: 14, bottom: 10, trailing: 14)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.dataHealth) { h in
                        let c = h.level == .ok ? Theme.pos : h.level == .warning ? Theme.warning : Theme.neg
                        let actionable = h.level != .ok && (h.asset != nil || h.area == .sync || h.area == .recovery)
                        TermButton(action: { if actionable { store.reviewFinding(h) } }, hoverBg: actionable ? Theme.hover : .clear) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                TT(h.level == .ok ? "✓" : h.level == .warning ? "!" : "✗", 11, c).frame(width: 10)
                                TT(h.area.rawValue, 11, Theme.t2).frame(width: 72, alignment: .leading)
                                TT(Self.trimArea(h.text, h.area.rawValue), 11, h.level == .ok ? Theme.t3 : c).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 20)
        }
    }

    // MARK: pane: one section, or filter matches grouped by section

    private var pane: some View {
        let pane = store.settingsPane
        let filtering = !store.settingsFilter.trimmingCharacters(in: .whitespaces).isEmpty
        let offsets = rowOffsets(pane.groups)
        return VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: pane.title, sub: pane.sub, rule: false)
                .padding(.horizontal, 22).padding(.top, 22)
                .frame(height: Self.headerHeight)
                .overlay(alignment: .bottom) { Hairline() }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(pane.groups.enumerated()), id: \.element.id) { gi, g in
                        Panel(title: g.h, padding: .init(top: 12, leading: 0, bottom: 2, trailing: 0)) {
                            VStack(spacing: 0) {
                                ForEach(Array(g.rows.enumerated()), id: \.element.id) { ri, r in
                                    let idx = offsets[gi] + ri
                                    // The row in focus (⇥), else the first row as the entry point, as designed.
                                    let mark = store.settingsRow.map { $0 == idx } ?? (!filtering && idx == 0)
                                    row(r, focused: store.settingsRow == idx, mark: mark, divider: ri < g.rows.count - 1)
                                }
                            }
                        }
                    }
                    if pane.groups.isEmpty {
                        TT("no settings match \"\(store.settingsFilter)\" · esc clears", 12, Theme.t3).padding(.top, 8)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
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

    private func row(_ r: SettingRow, focused: Bool, mark: Bool, divider: Bool) -> some View {
        TermButton(action: { r.run?(1) }, hoverBg: r.run == nil ? .clear : Theme.hover) {
            HStack(spacing: 12) {
                TT(mark ? "›" : " ", 12, Theme.acc).frame(width: 10)
                TT(r.k, 12, Theme.t2)
                Spacer(minLength: 8)
                if !r.hint.isEmpty { TT(r.hint, 11, Theme.t4) }
                TT(r.display, 12, r.color).lineLimit(1)
            }
            .padding(.leading, 8).padding(.trailing, 16).frame(height: store.settings.rowHeight + 2)
            .background(focused ? Theme.selected : .clear)
            .overlay(alignment: .bottom) { if divider { Rectangle().fill(Theme.innerBorder).frame(height: 1) } }
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
