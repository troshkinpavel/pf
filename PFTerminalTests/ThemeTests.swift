import PFCore
import PFCoreUI
import Foundation
import Testing
@testable import PFTerminal

/// Appearance: settings migration, persistence, live switching, system mapping, token sets and contrast.
@MainActor @Suite(.serialized)
struct ThemeTests {
    private func store() -> AppStore {
        var o = AppStore.Options()
        o.directory = nil; o.inMemory = true; o.mockMarket = true; o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf-theme-\(UUID().uuidString)")!
        return AppStore(o)
    }

    @Test func defaultIsDarkAndOlderSettingsStayDark() throws {
        #expect(AppSettings().theme == .dark)
        let old = #"{"primaryProvider":"Auto","currency":"USD","density":"compact"}"#      // 0.5 settings: no theme key
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8)).theme == .dark)
        let future = #"{"theme":"solarized"}"#                                           // a value from a newer build
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(future.utf8)).theme == .dark)
        #expect(ThemePalette.dark.bg == 0x0e0f11 && ThemePalette.dark.acc == 0xe0b35a, "dark keeps the original look")
    }

    @Test func choicePersists() {
        let d = UserDefaults(suiteName: "pf-theme-\(UUID().uuidString)")!
        for t in AppTheme.allCases {
            var s = AppSettings(); s.theme = t; s.save(d)
            #expect(AppSettings.load(d).theme == t)
        }
    }

    @Test func switchingAppliesImmediately() {
        let s = store()
        defer { Theme.palette = .dark }
        #expect(Theme.palette == .dark && s.themeID == "dark")
        for (t, p) in [(AppTheme.light, ThemePalette.light), (.midnight, .midnight), (.graphite, .graphite), (.dark, .dark)] {
            s.settings.theme = t
            #expect(Theme.palette == p && s.themeID == p.name, "\(t) applied without restart")
            #expect(s.colorScheme == (p.isLight ? .light : .dark))
        }
    }

    @Test func systemFollowsMacOSLightAndDark() {
        #expect(AppTheme.system.palette(systemIsDark: true) == .dark)
        #expect(AppTheme.system.palette(systemIsDark: false) == .light)
        let s = store()
        defer { Theme.palette = .dark }
        s.settings.theme = .system
        s.systemIsDark = false
        #expect(Theme.palette == .light && s.themeID == "light")
        s.systemIsDark = true
        #expect(Theme.palette == .dark && s.themeID == "dark")
    }

    @Test func everyThemeDefinesDistinctReadableTokens() {
        #expect(Set(ThemePalette.all.map(\.name)) == ["dark", "light", "midnight", "graphite"])
        for p in ThemePalette.all {
            // Every surface token differs from the text it carries; finance colours never coincide.
            #expect(p.pos != p.neg && p.acc != p.pos && p.acc != p.neg, "\(p.name)")
            for (name, fg) in p.textTokens {
                let ratio = contrast(fg, p.bg)
                let need: Double = ["t1", "text"].contains(name) ? 7 : name == "t4" ? 3.5 : 4.5
                #expect(ratio >= need, "\(p.name).\(name) contrast \(ratio) < \(need)")
                #expect(contrast(fg, p.raised) >= need - 0.3, "\(p.name).\(name) on raised surfaces")
            }
            #expect(contrast(p.onAccent, p.acc) >= 4.5, "\(p.name) glyph on accent")
            #expect(p.isLight == (luminance(p.bg) > 0.5))
        }
    }

    @Test func gainAndLossAreNotColourOnly() {
        let f = Fmt(style: .comma, currency: "USD")
        // Every gain/loss figure carries its sign (and ▲/▼ where shown), so colour is never the only cue.
        let minus: (String) -> Bool = { $0.hasPrefix("-") || $0.hasPrefix("−") }
        #expect(f.signed(Decimal(5)).hasPrefix("+") && minus(f.signed(Decimal(-5))))
        #expect(f.pct(1.5).hasPrefix("+") && minus(f.pct(-1.5)))
    }

    private func luminance(_ h: UInt32) -> Double {
        let c = [Double((h >> 16) & 255), Double((h >> 8) & 255), Double(h & 255)].map { $0 / 255 }
            .map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
