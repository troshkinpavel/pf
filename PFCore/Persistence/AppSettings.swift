import Foundation

/// App appearance (Settings → APPEARANCE → theme). `system` follows macOS light/dark.
/// Colours live in PFCoreUI (`ThemePalette`); this is only the stored choice.
public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case dark, light, midnight, graphite, system
}

public enum MenuBarFormat: String, Codable, CaseIterable, Sendable {
    case valuePct = "value + 24h %", valueDelta = "Σ value  Δ today", compact = "◈ compact", hidden = "icon only"
}

/// User preferences. Persisted as JSON in UserDefaults. Never holds secrets (see Keychain).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Preferred market-data source for all assets: "Auto" (route per asset: live exchange feeds,
    /// then CoinGecko, then canonical DEX) or a named source. A per-asset choice overrides it.
    public var primaryProvider: String = "Auto"
    public var realtimeProvider: String = "Binance"
    public var refreshSeconds: Int = 60
    public var currency: String = "USD"
    public var density: String = "compact"
    public var chartStyle: AsciiChart.Style = .line
    public var numbers: NumberStyle = .comma
    public var menuBar: MenuBarFormat = .valuePct
    public var popoverRows: Int = 4
    public var appLock: Bool = false
    public var alertThreshold: Double = 0          // 0 = off; otherwise |24h %| that triggers a notification
    /// Notify once when a held stablecoin leaves its peg band (re-arms after it recovers).
    public var depegAlerts: Bool = false
    public var shareDefaultPrivacy: SharePrivacy = .public
    public var widgetPrivacy: WidgetPrivacyMode = .full
    /// "active" follows the active context, "all" pins the menu bar to ALL PORTFOLIOS.
    public var menuBarContext: String = "active"
    public var onboarded: Bool = false
    /// Mac-local: keep the Dock icon while only the menu bar item is open. Never synced.
    public var keepInDock: Bool = false
    /// Appearance. Older settings have no value and stay on the original dark look.
    public var theme: AppTheme = .dark
    /// 0.7: which dark palette `system` uses when macOS is dark (dark · midnight · graphite).
    public var darkVariant: AppTheme = .dark
    /// 0.7: hour the day starts for "Today" in What Changed (0 = local midnight).
    public var dayStartHour: Int = 0
    /// 0.7: open at login (in the menu bar, without the window).
    public var launchAtLogin: Bool = false
    /// 0.7 alert delivery (rules live in Alerts).
    public var alertBanner: Bool = true
    public var alertBadge: Bool = true
    public var alertSound: Bool = false
    /// "off" or "HH–HH" (local hours): fired alerts are queued and delivered after.
    public var quietHours: String = "off"
    public static let quietHourOptions = ["off", "22–07", "00–07", "23–08"]
    public static let dayStartOptions = [0, 4, 6, 8]

    public static let providerOptions = ["Auto", "Binance", "Bybit", "CoinGecko"]
    /// Settings format of market routing. 0 = before 0.5 (CoinGecko was the default primary).
    public var routingVersion: Int = 1
    public static let realtimeOptions = ["Binance", "off"]
    public static let intervalOptions = [15, 30, 60, 300]
    public static let currencyOptions = ["USD", "EUR", "CHF"]
    public static let alertOptions: [Double] = [0, 5, 10]

    public var compact: Bool { density == "compact" }
    public var rowHeight: CGFloat { compact ? 26 : 32 }
    public var intervalLabel: String { refreshSeconds >= 60 && refreshSeconds % 60 == 0 && refreshSeconds > 60 ? "\(refreshSeconds / 60) min" : "\(refreshSeconds) sec" }

    private static let key = "pf.settings.v1"

    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let d = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }
    public func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }

    // Tolerate older/partial JSON: every field falls back to its default.
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        primaryProvider = (try? c.decode(String.self, forKey: .primaryProvider)) ?? d.primaryProvider
        routingVersion = (try? c.decode(Int.self, forKey: .routingVersion)) ?? 0
        // 0.5 migration: CoinGecko was the old default, so it becomes Auto (exchange feeds first).
        if routingVersion < 1 { if primaryProvider == "CoinGecko" { primaryProvider = "Auto" }; routingVersion = 1 }
        realtimeProvider = (try? c.decode(String.self, forKey: .realtimeProvider)) ?? d.realtimeProvider
        refreshSeconds = (try? c.decode(Int.self, forKey: .refreshSeconds)) ?? d.refreshSeconds
        currency = (try? c.decode(String.self, forKey: .currency)) ?? d.currency
        density = (try? c.decode(String.self, forKey: .density)) ?? d.density
        chartStyle = (try? c.decode(AsciiChart.Style.self, forKey: .chartStyle)) ?? d.chartStyle
        numbers = (try? c.decode(NumberStyle.self, forKey: .numbers)) ?? d.numbers
        menuBar = (try? c.decode(MenuBarFormat.self, forKey: .menuBar)) ?? d.menuBar
        popoverRows = (try? c.decode(Int.self, forKey: .popoverRows)) ?? d.popoverRows
        appLock = (try? c.decode(Bool.self, forKey: .appLock)) ?? d.appLock
        alertThreshold = (try? c.decode(Double.self, forKey: .alertThreshold)) ?? d.alertThreshold
        depegAlerts = (try? c.decode(Bool.self, forKey: .depegAlerts)) ?? d.depegAlerts
        shareDefaultPrivacy = (try? c.decode(SharePrivacy.self, forKey: .shareDefaultPrivacy)) ?? d.shareDefaultPrivacy
        widgetPrivacy = (try? c.decode(WidgetPrivacyMode.self, forKey: .widgetPrivacy)) ?? d.widgetPrivacy
        menuBarContext = (try? c.decode(String.self, forKey: .menuBarContext)) ?? d.menuBarContext
        onboarded = (try? c.decode(Bool.self, forKey: .onboarded)) ?? d.onboarded
        keepInDock = (try? c.decode(Bool.self, forKey: .keepInDock)) ?? d.keepInDock
        theme = (try? c.decode(AppTheme.self, forKey: .theme)) ?? d.theme   // unknown values (a newer build) → dark
        darkVariant = (try? c.decode(AppTheme.self, forKey: .darkVariant)) ?? d.darkVariant
        dayStartHour = (try? c.decode(Int.self, forKey: .dayStartHour)) ?? d.dayStartHour
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        alertBanner = (try? c.decode(Bool.self, forKey: .alertBanner)) ?? d.alertBanner
        alertBadge = (try? c.decode(Bool.self, forKey: .alertBadge)) ?? d.alertBadge
        alertSound = (try? c.decode(Bool.self, forKey: .alertSound)) ?? d.alertSound
        quietHours = (try? c.decode(String.self, forKey: .quietHours)) ?? d.quietHours
    }
}

extension AppSettings {
    /// True when `date` falls inside quiet hours ("22–07" wraps midnight).
    public func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = quietHours.split(separator: "–").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        let h = calendar.component(.hour, from: date)
        return parts[0] <= parts[1] ? (h >= parts[0] && h < parts[1]) : (h >= parts[0] || h < parts[1])
    }
}

extension Array where Element: Equatable {
    /// Next element after `cur`, wrapping.
    public func cycled(from cur: Element, by d: Int = 1) -> Element {
        guard !isEmpty else { return cur }
        let i = firstIndex(of: cur) ?? 0
        return self[((i + d) % count + count) % count]
    }
}
