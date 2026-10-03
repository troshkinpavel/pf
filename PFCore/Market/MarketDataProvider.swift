import Foundation

public enum MarketError: Error, Equatable, CustomStringConvertible {
    case offline
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(Int)        // HTTP status (e.g. 451 geo-block, 5xx)
    case decoding
    case unsupported

    public var description: String {
        switch self {
        case .offline: "no internet connection"
        case let .rateLimited(r): "rate limited" + (r.map { " · retry in \(Int($0))s" } ?? "")
        case let .unavailable(c): "provider unavailable (\(c))"
        case .decoding: "unexpected response"
        case .unsupported: "not supported"
        }
    }
}

/// A source of market data. Views never see which provider answered.
public protocol MarketDataProvider: Sendable {
    var name: String { get }
    func supports(_ asset: Asset) -> Bool
    func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote]
    func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint]
    func search(_ query: String) async throws -> [Asset]
}

extension MarketDataProvider {
    public func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] { throw MarketError.unsupported }
    public func search(_ query: String) async throws -> [Asset] { [] }
}

/// Minimal HTTP client. Ephemeral session: no cookies, no persistent cache, no identifiers.
public enum HTTP {
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: c)
    }()

    public static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut].contains(e.code) {
            throw MarketError.offline
        }
        guard let http = resp as? HTTPURLResponse else { throw MarketError.decoding }
        switch http.statusCode {
        case 200..<300: return data
        case 429, 418:
            let ra = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw MarketError.rateLimited(retryAfter: ra)
        default: throw MarketError.unavailable(http.statusCode)
        }
    }

    public static func json<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:]) async throws -> T {
        let d = try await get(url, headers: headers)
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw MarketError.decoding }
    }
}

/// Lenient number decoding: providers mix strings and numbers.
public struct FlexDouble: Decodable, Sendable {
    public let value: Double?
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = Double(s) }
        else { value = nil }
    }
}

/// Queries providers in priority order, falls through per asset, backs off failing providers,
/// and fills missing metadata (supply, ATH, multi-period change) from later providers.
public actor ProviderRouter {
    public struct Result: Sendable {
        public init(quotes: [AssetID: Quote] = [:], errors: [String: MarketError] = [:], unresolved: [AssetID] = []) { self.quotes = quotes; self.errors = errors; self.unresolved = unresolved }
        public var quotes: [AssetID: Quote] = [:]
        public var errors: [String: MarketError] = [:]
        public var unresolved: [AssetID] = []
    }

    public private(set) var providers: [MarketDataProvider]
    private var failures: [String: Int] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var metadata: [AssetID: Quote] = [:]
    private var metadataAt: Date = .distantPast
    private let metadataTTL: TimeInterval = 15 * 60
    private let now: @Sendable () -> Date

    public init(providers: [MarketDataProvider], now: @escaping @Sendable () -> Date = Date.init) {
        self.providers = providers
        self.now = now
    }

    public func setProviders(_ p: [MarketDataProvider]) { providers = p; metadataAt = .distantPast }

    public func isBlocked(_ name: String) -> Bool { (blockedUntil[name] ?? .distantPast) > now() }

    /// Per-provider backoff, for Settings and the diagnostic report. Only providers that failed.
    public struct Health: Equatable, Sendable { public let name: String; public let failures: Int; public let blockedUntil: Date? }
    public func health() -> [Health] {
        let t = now()
        return failures.filter { $0.value > 0 }.keys.sorted().map {
            Health(name: $0, failures: failures[$0] ?? 0, blockedUntil: blockedUntil[$0].flatMap { $0 > t ? $0 : nil })
        }
    }

    private func recordFailure(_ name: String, _ e: MarketError) {
        let n = (failures[name] ?? 0) + 1
        failures[name] = n
        var delay = min(15 * pow(2, Double(n - 1)), 900)            // 15s, 30s, … capped at 15 min
        if case let .rateLimited(ra) = e { delay = max(delay, ra ?? 60) }
        if e == .unsupported { delay = 0 }
        blockedUntil[name] = now().addingTimeInterval(delay)
    }

    private func recordSuccess(_ name: String) { failures[name] = 0; blockedUntil[name] = nil }

    /// Per-asset route (MarketMappings.route: preferred source, then Binance, Bybit, CoinGecko,
    /// canonical DexScreener) restricted to configured providers; providers outside the known
    /// sources (e.g. Mock) come after. Only verified mappings are ever asked.
    func order(_ a: Asset) -> [MarketDataProvider] {
        let byName = Dictionary(providers.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let routed = MarketMappings.route(a).compactMap { byName[$0.rawValue] }
        let others = providers.filter { p in !routed.contains { $0.name == p.name } && p.supports(a) }
        return routed + others
    }

    public func quotes(for assets: [Asset], currency: String) async -> Result {
        var r = Result()
        var answeredBy: [AssetID: String] = [:]
        var tried: [AssetID: Set<String>] = [:]
        var remaining = assets
        // Rounds: each remaining asset goes to its next untried, unblocked provider; one batched
        // request per provider per round. Failures fall through to the next source.
        while !remaining.isEmpty {
            var batch: [String: [Asset]] = [:]
            for a in remaining {
                if let p = order(a).first(where: { !(tried[a.id]?.contains($0.name) ?? false) && !isBlocked($0.name) }) {
                    batch[p.name, default: []].append(a)
                }
            }
            if batch.isEmpty { break }
            for name in batch.keys.sorted() {
                guard let p = providers.first(where: { $0.name == name }), let list = batch[name] else { continue }
                for a in list { tried[a.id, default: []].insert(name) }
                guard !isBlocked(name) else { continue }
                do {
                    let q = try await p.quotes(for: list, currency: currency)
                    recordSuccess(name)
                    for (k, v) in q { r.quotes[k] = v; answeredBy[k] = name }
                } catch {
                    let e = error as? MarketError ?? .decoding
                    recordFailure(name, e); r.errors[name] = e
                }
            }
            remaining.removeAll { r.quotes[$0.id] != nil }
        }
        r.unresolved = remaining.map(\.id)

        // Metadata enrichment, throttled.
        let lacking = assets.filter { a in
            guard let q = r.quotes[a.id] else { return false }
            return q.circulatingSupply == nil || q.change[.d7] == nil
        }
        // Metadata (supply, market cap, ATH, multi-period change) comes from CoinGecko only, one
        // batched request per `metadataTTL`: exchanges don't have it, so asking them is waste.
        if !lacking.isEmpty, now().timeIntervalSince(metadataAt) > metadataTTL {
            metadataAt = now()
            for p in providers where p.name == MarketSource.coingecko.rawValue && !isBlocked(p.name) {
                let subset = lacking.filter { p.supports($0) && answeredBy[$0.id] != p.name }
                guard !subset.isEmpty else { continue }
                if let q = try? await p.quotes(for: subset, currency: currency) {
                    for (k, v) in q { metadata[k] = v }
                }
            }
        }
        for (k, q) in r.quotes { if let m = metadata[k] { r.quotes[k] = q.enriched(with: m) } }
        return r
    }

    public func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] {
        var last: MarketError = .unsupported
        // Exchange history first (Binance, Bybit), CoinGecko market_chart only when needed.
        for p in order(asset) where !isBlocked(p.name) {
            do {
                let h = try await p.history(for: asset, range: range, currency: currency)
                if !h.isEmpty { return h }
            } catch {
                let e = error as? MarketError ?? .decoding
                if e != .unsupported { recordFailure(p.name, e) }
                last = e
            }
        }
        throw last
    }

    /// Online long-tail discovery (assets outside the bundled registry). Local registry search
    /// comes first in the app; this respects provider backoff and HTTP 429.
    /// Listed coins (CoinGecko) before DEX tokens; exact symbol matches first within each.
    public func search(_ query: String) async -> [Asset] {
        var out: [Asset] = []
        var seen = Set<AssetID>()
        for p in providers where !isBlocked(p.name) {
            guard let r = try? await p.search(query) else { continue }
            for a in r where !seen.contains(a.id) { seen.insert(a.id); out.append(a) }
        }
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        let rank: (Asset) -> Int = { ($0.symbol == q ? 0 : 2) + ($0.coingeckoID != nil ? 0 : 1) }
        return Array(out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element).prefix(8))
    }

    /// Quote one identity from one named provider (for comparing sources). Respects backoff.
    public func probe(_ asset: Asset, provider name: String, currency: String) async -> Quote? {
        guard !isBlocked(name), let p = providers.first(where: { $0.name == name }) ?? Self.extra(name), p.supports(asset) else { return nil }
        return try? await p.quotes(for: [asset], currency: currency)[asset.id]
    }

    /// Providers not in the active chain can still be probed when the user compares sources.
    private static func extra(_ name: String) -> MarketDataProvider? {
        switch name {
        case "Binance": BinanceProvider()
        case "Bybit": BybitProvider()
        case "DexScreener": DexScreenerProvider()
        case "CoinGecko": CoinGeckoProvider()
        default: nil
        }
    }
}
