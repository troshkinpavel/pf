import Foundation

/// Public Binance spot market data for liquid USDT pairs. No credentials, read-only.
/// USDT pairs are treated as USD; other base currencies are left to other providers.
struct BinanceProvider: MarketDataProvider {
    let name = "Binance"
    private let base = "https://api.binance.com/api/v3"

    func supports(_ asset: Asset) -> Bool { asset.binanceSymbol != nil }

    private struct Ticker: Decodable {
        let symbol: String
        let lastPrice: String
        let priceChangePercent: String
        let quoteVolume: String?
    }

    func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
        guard currency.uppercased() == "USD" else { throw MarketError.unsupported }
        let bySym = Dictionary(assets.compactMap { a in a.binanceSymbol.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        guard !bySym.isEmpty else { return [:] }
        var c = URLComponents(string: base + "/ticker/24hr")!
        let list = "[" + bySym.keys.sorted().map { "\"\($0)\"" }.joined(separator: ",") + "]"
        c.queryItems = [.init(name: "symbols", value: list)]
        let rows = try await HTTP.json([Ticker].self, c.url!)
        let ts = Date()
        var out: [AssetID: Quote] = [:]
        for t in rows {
            guard let a = bySym[t.symbol], let p = Decimal(string: t.lastPrice, locale: Locale(identifier: "en_US_POSIX")), p > 0 else { continue }
            out[a.id] = Quote(price: p, change: [.h24: Double(t.priceChangePercent) ?? 0],
                              volume24h: t.quoteVolume.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) },
                              source: name, timestamp: ts)
        }
        return out
    }

    func history(for asset: Asset, range: ChartRange, currency: String) async throws -> [PricePoint] {
        guard currency.uppercased() == "USD", let s = asset.binanceSymbol else { throw MarketError.unsupported }
        let (interval, limit): (String, Int) = {
            switch range {
            case .h1: ("1m", 60)
            case .d1, .h24: ("15m", 96)
            case .w1, .d7: ("1h", 168)
            case .m1, .d30: ("4h", 180)
            case .m3: ("1d", 90)
            case .ytd, .y1: ("1d", 365)
            case .all: ("1w", 1000)
            }
        }()
        var c = URLComponents(string: base + "/klines")!
        c.queryItems = [.init(name: "symbol", value: s), .init(name: "interval", value: interval), .init(name: "limit", value: String(limit))]
        let rows = try await HTTP.json([[FlexDouble]].self, c.url!)
        return rows.compactMap { r in
            guard r.count > 4, let t = r[0].value, let close = r[4].value else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: t / 1000), price: close)
        }
    }
}

/// Realtime price stream (miniTicker) for supported symbols. Reconnects with backoff.
@MainActor
final class BinanceStream {
    enum State: Equatable { case off, connecting, connected, disconnected(String) }

    var onTick: ((_ symbol: String, _ price: Decimal, _ change24h: Double) -> Void)?
    var onState: ((State) -> Void)?
    private(set) var state: State = .off { didSet { onState?(state) } }

    private var task: URLSessionWebSocketTask?
    private var symbols: [String] = []
    private var attempts = 0
    private var reconnect: Task<Void, Never>?
    private var generation = 0

    func connect(symbols: [String]) {
        let s = Array(Set(symbols)).sorted()
        if s == self.symbols, state == .connected || state == .connecting { return }
        stop()
        self.symbols = s
        guard !s.isEmpty else { return }
        open()
    }

    func stop() {
        generation += 1
        reconnect?.cancel(); reconnect = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        state = .off
    }

    private func open() {
        let streams = symbols.map { $0.lowercased() + "@miniTicker" }.joined(separator: "/")
        guard let url = URL(string: "wss://stream.binance.com:9443/stream?streams=" + streams) else { return }
        state = .connecting
        let t = HTTP.session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t, gen: generation)
    }

    private struct Envelope: Decodable {
        struct Data: Decodable { let s: String; let c: String; let o: String }
        let data: Data
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case let .success(msg):
                    if self.state != .connected { self.state = .connected; self.attempts = 0 }
                    var data: Data?
                    if case let .string(s) = msg { data = s.data(using: .utf8) } else if case let .data(d) = msg { data = d }
                    if let d = data, let e = try? JSONDecoder().decode(Envelope.self, from: d),
                       let c = Decimal(string: e.data.c, locale: Locale(identifier: "en_US_POSIX")),
                       let o = Double(e.data.o), o > 0 {
                        self.onTick?(e.data.s, c, (c.double / o - 1) * 100)
                    }
                    self.receive(t, gen: gen)
                case let .failure(err):
                    self.state = .disconnected((err as? URLError).map { "\($0.code.rawValue)" } ?? "closed")
                    self.scheduleReconnect(gen: gen)
                }
            }
        }
    }

    private func scheduleReconnect(gen: Int) {
        attempts += 1
        let delay = min(5 * pow(2, Double(attempts - 1)), 300)
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.open()
        }
    }
}
