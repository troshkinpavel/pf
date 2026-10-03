import LocalAuthentication
import Network
import Security
import UserNotifications

/// Secrets (optional provider API keys) live only in the Keychain.
public enum Keychain {
    /// The optional CoinGecko key is not migrated from `LegacyIdentifiers.keychainService`:
    /// that item's ACL belongs to the old app, so reading it would raise a system prompt.
    /// Re-entering it in Settings takes seconds.
    private static let service = "io.github.troskinpavel.pf"

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Local notifications for large portfolio moves (opt-in; off by default).
public enum Notifier {
    public static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Content is deliberately percentage-only: notifications can appear on a locked screen.
    public static func postMove(pct: Double, fmt: Fmt) {
        let c = UNMutableNotificationContent()
        c.title = "pf · portfolio " + (pct >= 0 ? "▲" : "▼") + fmt.pct(abs(pct)).replacingOccurrences(of: "+", with: "")
        c.body = "24h move crossed your alert threshold."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pf.move", content: c, trigger: nil))
    }
}

/// Touch ID / password gate for the main window (opt-in). Fails closed: if the system can't
/// authenticate (no password, policy unavailable), the app stays locked.
public enum AppLock {
    public enum Outcome: Equatable, Sendable { case unlocked, failed, unavailable(String) }

    /// nil when Touch ID or the login password can be used; otherwise why not.
    public static func unavailableReason() -> String? {
        var err: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return "Touch ID and the login password are unavailable (\(err.map { LAError.Code(rawValue: $0.code).map { "\($0)" } ?? "\($0.code)" } ?? "unknown"))"
        }
        return nil
    }

    public static func evaluate(reason: String = "unlock your portfolio") async -> Outcome {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return .unavailable(unavailableReason() ?? "authentication unavailable")
        }
        return ((try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false) ? .unlocked : .failed
    }

    public static func authenticate() async -> Bool { await evaluate() == .unlocked }
}

extension Notifier {
    /// Names the coin and its deviation, never an amount held.
    public static func postDepeg(symbol: String, deviationPercent: Double, target: String, fmt: Fmt) {
        let c = UNMutableNotificationContent()
        c.title = "pf · \(symbol) off its peg"
        c.body = "\(symbol) is \(fmt.pct(deviationPercent, 2)) from \(target)."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pf.depeg." + symbol, content: c, trigger: nil))
    }
}

/// Reachability without polling.
@MainActor
public final class NetworkMonitor {
    public init() {}
    private let monitor = NWPathMonitor()
    public var onChange: ((Bool) -> Void)?
    public private(set) var isOnline = true

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "pf.network"))
    }
}
