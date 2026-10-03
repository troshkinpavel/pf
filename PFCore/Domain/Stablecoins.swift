import Foundation

// Stablecoin classification and peg-aware valuation. Shared by every PF client: all peg
// logic lives here; UIs only render `PegCheck`.
//
// Valuation (in the peg currency, e.g. a USD ledger for USD stablecoins):
//   market within ±tolerance of target → valued at exactly the target (1.00), 0% change
//   market outside the band (depeg)    → valued at the real market price
//   no market price yet                → valued at the target, status .unchecked
// The last known market price keeps deciding the state while providers fail (quotes are
// cached), so a depeg stays a depeg until a newer quote says otherwise.
//
// In another ledger currency (EUR, CHF) a USD stablecoin is priced like any other asset:
// PF has no FX rates, and its market price in that currency *is* its value.

/// What a stablecoin is pegged to.
public struct StablecoinPeg: Hashable, Sendable {
    public var currency: String      // ISO code, e.g. "USD"
    public var target: Decimal       // e.g. 1.00
    public init(currency: String, target: Decimal) { self.currency = currency; self.target = target }

    public static let usd = StablecoinPeg(currency: "USD", target: 1)
}

public enum PegStatus: String, Equatable, Sendable {
    case normal, depeg, unchecked
}

/// The peg state of one stablecoin at one moment, as shown in the UI.
public struct PegCheck: Equatable, Sendable {
    public var peg: StablecoinPeg
    public var status: PegStatus
    public var market: Decimal?          // last known market price (nil = never checked)
    public var deviationPercent: Double? // (market / target − 1) × 100
    public var checkedAt: Date?
    /// The price the portfolio uses: target when normal or unchecked, market when depegged.
    public var valuationPrice: Decimal
}

public enum Stablecoins {
    /// ±0.5% around the target counts as on peg.
    public static let tolerance: Decimal = 0.005
    /// While on peg, the market price is re-checked at most this often (not every refresh).
    public static let checkInterval: TimeInterval = 5 * 60

    /// Curated fallback, keyed by ledger asset id (never by ticker). The registry's stablecoin
    /// metadata comes first (39 USD stablecoins in the 2026-09-30 snapshot); this list keeps the
    /// initial set covered even where the snapshot lacks one (USDS isn't in it).
    public static let whitelist: [AssetID: StablecoinPeg] = [
        "cg:tether": .usd,               // USDT
        "cg:usd-coin": .usd,             // USDC
        "cg:dai": .usd,                  // DAI
        "cg:usds": .usd,                 // USDS
        "cg:first-digital-usd": .usd,    // FDUSD
        "cg:paypal-usd": .usd,           // PYUSD
    ]

    public static func peg(for id: AssetID, registry: AssetRegistry = .shared) -> StablecoinPeg? {
        if let s = registry.entry(forID: id)?.stablecoin { return StablecoinPeg(currency: s.pegCurrency.uppercased(), target: s.targetPeg) }
        return whitelist[id]
    }

    /// Classify a market price against a peg.
    public static func status(market: Decimal?, peg: StablecoinPeg) -> PegStatus {
        guard let m = market, peg.target > 0 else { return .unchecked }
        let deviation = abs(m / peg.target - 1)
        return deviation <= tolerance ? .normal : .depeg
    }

    /// Peg state for an asset in a ledger currency; nil when it isn't a stablecoin there.
    public static func check(_ id: AssetID, quote: Quote?, currency: String) -> PegCheck? {
        guard let peg = peg(for: id), peg.currency == currency else { return nil }
        let st = status(market: quote?.price, peg: peg)
        let dev = quote.map { (($0.price / peg.target) - 1).double * 100 }
        return PegCheck(peg: peg, status: st, market: quote?.price, deviationPercent: dev, checkedAt: quote?.timestamp,
                        valuationPrice: st == .depeg ? quote!.price : peg.target)
    }

    /// Quotes for valuation: market quotes, except on-peg stablecoins read exactly the target
    /// with 0% change, and never-checked ones get a target quote. Everything that values or
    /// charts the portfolio (summary, P&L, movers, widgets, menu bar) reads these.
    public static func valuationQuotes(_ quotes: [AssetID: Quote], assets: [AssetID], currency: String, now: Date = Date()) -> [AssetID: Quote] {
        var out = quotes
        for id in assets {
            guard let c = check(id, quote: quotes[id], currency: currency), c.status != .depeg else { continue }
            if var q = quotes[id] {
                q.price = c.peg.target
                for k in q.change.keys { q.change[k] = 0 }
                out[id] = q
            } else {
                out[id] = Quote(price: c.peg.target, change: [.h24: 0], source: "peg", timestamp: now)
            }
        }
        return out
    }

    /// History for charts and performance: points within the band read the target, so normal
    /// peg noise doesn't show up as performance; real historical depegs stay visible.
    public static func valuationSeries(_ s: PriceSeries, for id: AssetID, currency: String) -> PriceSeries {
        guard let peg = peg(for: id), peg.currency == currency else { return s }
        let t = peg.target.double, band = t * tolerance.double
        return PriceSeries(s.points.map { abs($0.price - t) <= band ? PricePoint(time: $0.time, price: t) : $0 })
    }

    /// History for an on-peg stablecoin that has none (offline, rate-limited): flat at the target,
    /// so one missing series doesn't blank the whole portfolio chart.
    public static func flatSeries(_ peg: StablecoinPeg, until now: Date = Date()) -> PriceSeries {
        PriceSeries([PricePoint(time: .distantPast, price: peg.target.double), PricePoint(time: now, price: peg.target.double)])
    }

    /// Market-driven assets: those whose freshness and polling matter. On-peg stablecoins are
    /// valued at the target, so an older peg check doesn't make the portfolio "stale".
    public static func isPegValued(_ id: AssetID, quote: Quote?, currency: String) -> Bool {
        guard let c = check(id, quote: quote, currency: currency) else { return false }
        return c.status != .depeg
    }

    /// Whether this refresh should ask for the asset's market price: on-peg stablecoins only
    /// every `checkInterval` (piggybacking on the normal batched refresh, no extra requests).
    public static func needsMarketCheck(_ id: AssetID, quote: Quote?, currency: String, now: Date = Date()) -> Bool {
        guard let c = check(id, quote: quote, currency: currency), c.status == .normal, let at = c.checkedAt else { return true }
        return now.timeIntervalSince(at) >= checkInterval
    }
}

extension Asset {
    /// Peg, when the asset is a whitelisted stablecoin (in any ledger currency).
    public var stablecoinPeg: StablecoinPeg? { Stablecoins.peg(for: id) }
    public var isStablecoin: Bool { stablecoinPeg != nil }
    public var pegCurrency: String? { stablecoinPeg?.currency }
    public var targetPeg: Decimal? { stablecoinPeg?.target }
}

extension Stablecoins {
    /// Depeg notification state machine. A coin alerts once when it leaves the ±tolerance band
    /// and re-arms only after it is back well inside it (half the band), so a price hovering at
    /// the edge doesn't notify on every refresh. `alerted` is persisted by the host.
    public static func depegTransitions(_ checks: [AssetID: PegCheck], alerted: inout Set<AssetID>) -> [AssetID] {
        var fire: [AssetID] = []
        let rearm = (tolerance * 100 / 2).double
        for (id, c) in checks.sorted(by: { $0.key < $1.key }) {
            switch c.status {
            case .depeg where !alerted.contains(id):
                alerted.insert(id); fire.append(id)
            case .normal:
                if let d = c.deviationPercent, abs(d) <= rearm { alerted.remove(id) }
            default: break
            }
        }
        // Coins no longer held drop out of the state.
        alerted.formIntersection(checks.keys)
        return fire
    }
}
