import Foundation

enum MenuBarFormat: String, Codable, CaseIterable, Sendable {
    case valuePct = "value + 24h %", valueDelta = "Σ value  Δ today", compact = "◈ compact", hidden = "icon only"
}

/// User preferences. Persisted as JSON in UserDefaults. Never holds secrets (see Keychain).
struct AppSettings: Codable, Equatable, Sendable {
    var primaryProvider: String = "CoinGecko"
    var realtimeProvider: String = "Binance"
    var fallbackProvider: String = "DexScreener"
    var refreshSeconds: Int = 60
    var currency: String = "USD"
    var density: String = "compact"
    var chartStyle: AsciiChart.Style = .line
    var numbers: NumberStyle = .comma
    var menuBar: MenuBarFormat = .valuePct
    var popoverRows: Int = 4
    var appLock: Bool = false
    var alertThreshold: Double = 0          // 0 = off; otherwise |24h %| that triggers a notification
    var shareDefaultPrivacy: SharePrivacy = .public
    var widgetPrivacy: WidgetPrivacyMode = .full
    /// "active" follows the active context, "all" pins the menu bar to ALL PORTFOLIOS.
    var menuBarContext: String = "active"
    var onboarded: Bool = false
    /// Mac-local: keep the Dock icon while only the menu bar item is open. Never synced.
    var keepInDock: Bool = false

    static let providerOptions = ["CoinGecko", "Binance"]
    static let realtimeOptions = ["Binance", "off"]
    static let fallbackOptions = ["DexScreener", "CoinGecko", "none"]
    static let intervalOptions = [15, 30, 60, 300]
    static let currencyOptions = ["USD", "EUR", "CHF"]
    static let alertOptions: [Double] = [0, 5, 10]

    var compact: Bool { density == "compact" }
    var rowHeight: CGFloat { compact ? 26 : 32 }
    var intervalLabel: String { refreshSeconds >= 60 && refreshSeconds % 60 == 0 && refreshSeconds > 60 ? "\(refreshSeconds / 60) min" : "\(refreshSeconds) sec" }

    private static let key = "pf.settings.v1"

    static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let d = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }

    // Tolerate older/partial JSON: every field falls back to its default.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        primaryProvider = (try? c.decode(String.self, forKey: .primaryProvider)) ?? d.primaryProvider
        realtimeProvider = (try? c.decode(String.self, forKey: .realtimeProvider)) ?? d.realtimeProvider
        fallbackProvider = (try? c.decode(String.self, forKey: .fallbackProvider)) ?? d.fallbackProvider
        refreshSeconds = (try? c.decode(Int.self, forKey: .refreshSeconds)) ?? d.refreshSeconds
        currency = (try? c.decode(String.self, forKey: .currency)) ?? d.currency
        density = (try? c.decode(String.self, forKey: .density)) ?? d.density
        chartStyle = (try? c.decode(AsciiChart.Style.self, forKey: .chartStyle)) ?? d.chartStyle
        numbers = (try? c.decode(NumberStyle.self, forKey: .numbers)) ?? d.numbers
        menuBar = (try? c.decode(MenuBarFormat.self, forKey: .menuBar)) ?? d.menuBar
        popoverRows = (try? c.decode(Int.self, forKey: .popoverRows)) ?? d.popoverRows
        appLock = (try? c.decode(Bool.self, forKey: .appLock)) ?? d.appLock
        alertThreshold = (try? c.decode(Double.self, forKey: .alertThreshold)) ?? d.alertThreshold
        shareDefaultPrivacy = (try? c.decode(SharePrivacy.self, forKey: .shareDefaultPrivacy)) ?? d.shareDefaultPrivacy
        widgetPrivacy = (try? c.decode(WidgetPrivacyMode.self, forKey: .widgetPrivacy)) ?? d.widgetPrivacy
        menuBarContext = (try? c.decode(String.self, forKey: .menuBarContext)) ?? d.menuBarContext
        onboarded = (try? c.decode(Bool.self, forKey: .onboarded)) ?? d.onboarded
        keepInDock = (try? c.decode(Bool.self, forKey: .keepInDock)) ?? d.keepInDock
    }
}

extension Array where Element: Equatable {
    /// Next element after `cur`, wrapping.
    func cycled(from cur: Element, by d: Int = 1) -> Element {
        guard !isEmpty else { return cur }
        let i = firstIndex(of: cur) ?? 0
        return self[((i + d) % count + count) % count]
    }
}
