import Foundation

/// Public exchange price stream over WebSocket (no account, no key, no auth). One engine; each
/// venue is a configuration: URL, subscribe/ping messages and a message parser.
///
/// Reconnects with exponential backoff (5s … 5 min). Heartbeat: a ping every `pingInterval`;
/// any message (tick or pong) counts as alive. A connection silent for
/// `MarketStatusPolicy.streamSilence` is dropped and reopened (stale detection).
@MainActor
public final class LiveFeed {
    public enum State: Equatable { case off, connecting, connected, disconnected(String) }

    public struct Tick: Equatable, Sendable {
        public var symbol: String
        public var price: Decimal
        public var change24h: Double?
        public init(symbol: String, price: Decimal, change24h: Double?) { self.symbol = symbol; self.price = price; self.change24h = change24h }
    }

    public struct Venue: Sendable {
        public var source: MarketSource
        public var url: @Sendable ([String]) -> URL?
        /// Text frames sent after connecting (subscriptions). Empty when the URL subscribes.
        public var subscribe: @Sendable ([String]) -> [String]
        /// App-level ping text; nil = WebSocket protocol ping.
        public var ping: String?
        public var pingInterval: TimeInterval
        public var parse: @Sendable (Data) -> Tick?
    }

    public let venue: Venue
    public var onTick: ((Tick) -> Void)?
    public var onState: ((State) -> Void)?
    public private(set) var state: State = .off { didSet { if state != oldValue { onState?(state) } } }
    public private(set) var symbols: [String] = []
    public private(set) var lastMessageAt: Date?
    public private(set) var lastTickAt: [String: Date] = [:]

    private var task: URLSessionWebSocketTask?
    private var attempts = 0
    private var reconnect: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var generation = 0
    /// Backoff before the next reconnect (nil = none pending). Exposed for tests.
    public private(set) var reconnectDelay: TimeInterval?
    private let now: @Sendable () -> Date

    public init(venue: Venue, now: @escaping @Sendable () -> Date = Date.init) { self.venue = venue; self.now = now }

    public var source: MarketSource { venue.source }

    /// Connected and heard from recently.
    public func isHealthy(at t: Date? = nil) -> Bool {
        guard state == .connected, let last = lastMessageAt else { return false }
        return (t ?? now()).timeIntervalSince(last) <= MarketStatusPolicy.streamSilence
    }

    /// Whether this symbol's price is live right now.
    public func isLive(_ symbol: String, at t: Date? = nil) -> Bool {
        guard isHealthy(at: t), let at = lastTickAt[symbol] else { return false }
        return (t ?? now()).timeIntervalSince(at) <= MarketStatusPolicy.liveThreshold
    }

    public func connect(symbols: [String]) {
        let s = Array(Set(symbols)).sorted()
        if s == self.symbols, state == .connected || state == .connecting { return }
        stop()
        self.symbols = s
        guard !s.isEmpty else { return }
        open()
    }

    public func stop() {
        generation += 1
        reconnect?.cancel(); reconnect = nil; reconnectDelay = nil
        heartbeat?.cancel(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        lastTickAt = [:]
        state = .off
    }

    /// Feed one raw message (also the path tests use).
    public func handle(_ data: Data) {
        lastMessageAt = now()
        if state != .connected { state = .connected; attempts = 0 }
        if let t = venue.parse(data), symbols.contains(t.symbol) {
            lastTickAt[t.symbol] = now()
            onTick?(t)
        }
    }

    private func open() {
        guard let url = venue.url(symbols) else { return }
        state = .connecting
        let t = HTTP.session.webSocketTask(with: url)
        task = t
        t.resume()
        let gen = generation
        for m in venue.subscribe(symbols) { t.send(.string(m)) { _ in } }
        receive(t, gen: gen)
        startHeartbeat(t, gen: gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case let .success(msg):
                    switch msg {
                    case let .string(s): self.handle(Data(s.utf8))
                    case let .data(d): self.handle(d)
                    @unknown default: break
                    }
                    self.receive(t, gen: gen)
                case let .failure(err):
                    self.drop((err as? URLError).map { "\($0.code.rawValue)" } ?? "closed", gen: gen)
                }
            }
        }
    }

    private func startHeartbeat(_ t: URLSessionWebSocketTask, gen: Int) {
        heartbeat?.cancel()
        let interval = venue.pingInterval, ping = venue.ping
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                if let m = ping { t.send(.string(m)) { _ in } }
                else { t.sendPing { [weak self] err in Task { @MainActor in if err == nil, gen == self?.generation { self?.lastMessageAt = self?.now() } } } }
                // Silent too long: treat as dead and reconnect.
                if let last = self.lastMessageAt, self.now().timeIntervalSince(last) > MarketStatusPolicy.streamSilence {
                    self.drop("silent", gen: gen)
                    return
                }
            }
        }
    }

    /// Tear down after an error or silence and schedule a reconnect with exponential backoff.
    func drop(_ reason: String, gen: Int? = nil) {
        let gen = gen ?? generation
        guard gen == generation else { return }
        heartbeat?.cancel(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        state = .disconnected(reason)
        attempts += 1
        let delay = min(5 * pow(2, Double(attempts - 1)), 300)
        reconnectDelay = delay
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.reconnectDelay = nil
            self.open()
        }
    }

    /// Set the subscription list without opening a socket (tests, previews).
    func prepare(symbols: [String]) { self.symbols = Array(Set(symbols)).sorted() }
}

extension LiveFeed {
    public static func binance() -> LiveFeed { LiveFeed(venue: .binance) }
    public static func bybit() -> LiveFeed { LiveFeed(venue: .bybit) }
}

extension LiveFeed.Venue {
    /// Binance combined miniTicker streams (subscribed through the URL).
    public static let binance = LiveFeed.Venue(
        source: .binance,
        url: { syms in URL(string: "wss://stream.binance.com:9443/stream?streams=" + syms.map { $0.lowercased() + "@miniTicker" }.joined(separator: "/")) },
        subscribe: { _ in [] }, ping: nil, pingInterval: 30,
        parse: { data in
            struct Env: Decodable { struct D: Decodable { let s: String; let c: String; let o: String }; let data: D }
            guard let e = try? JSONDecoder().decode(Env.self, from: data),
                  let c = Decimal(string: e.data.c, locale: Locale(identifier: "en_US_POSIX")), c > 0 else { return nil }
            let o = Double(e.data.o) ?? 0
            return LiveFeed.Tick(symbol: e.data.s, price: c, change24h: o > 0 ? (c.double / o - 1) * 100 : nil)
        })

    /// Bybit v5 public spot tickers. `price24hPcnt` is a fraction (0.0123 = 1.23%).
    public static let bybit = LiveFeed.Venue(
        source: .bybit,
        url: { _ in URL(string: "wss://stream.bybit.com/v5/public/spot") },
        subscribe: { syms in
            // Bybit accepts at most 10 args per subscribe request.
            stride(from: 0, to: syms.count, by: 10).map { i in
                let args = syms[i..<min(i + 10, syms.count)].map { "\"tickers.\($0)\"" }.joined(separator: ",")
                return "{\"op\":\"subscribe\",\"args\":[\(args)]}"
            }
        },
        ping: "{\"op\":\"ping\"}", pingInterval: 20,
        parse: { data in
            struct Msg: Decodable {
                struct D: Decodable { let symbol: String; let lastPrice: String?; let price24hPcnt: String? }
                let topic: String?; let data: D?
            }
            guard let m = try? JSONDecoder().decode(Msg.self, from: data), m.topic?.hasPrefix("tickers.") == true, let d = m.data,
                  let lp = d.lastPrice, let p = Decimal(string: lp, locale: Locale(identifier: "en_US_POSIX")), p > 0 else { return nil }
            return LiveFeed.Tick(symbol: d.symbol, price: p, change24h: d.price24hPcnt.flatMap(Double.init).map { $0 * 100 })
        })
}

/// Kept for source compatibility with 0.4.x callers.
public typealias BinanceStream = LiveFeed
