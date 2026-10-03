import Foundation

/// One per-asset assumption in a saved scenario.
public struct ScenarioTarget: Codable, Equatable, Sendable {
    public init(price: Decimal, weight: Double? = nil) { self.price = price; self.weight = weight }
    public var price: Decimal
    /// Optional target weight in % (the Base scenario's weights drive "over target" in the UI).
    public var weight: Double?
}

/// A saved set of target prices (design §09). Hypothetical only: nothing here touches the
/// ledger, P&L, TWR or history. Named PortfolioScenario because `Scenario` is the 0.6
/// single-asset calculator result.
public struct PortfolioScenario: Codable, Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), name: String, key: String? = nil, editedAt: Date, targets: [AssetID: ScenarioTarget] = [:]) {
        self.id = id; self.name = name; self.key = key; self.editedAt = editedAt; self.targets = targets
    }
    public var id: UUID
    public var name: String
    /// Switch key: c · b · u for the three presets; nil for others.
    public var key: String?
    public var editedAt: Date
    public var targets: [AssetID: ScenarioTarget]
}

public enum Scenarios {
    public static let presets: [(key: String, name: String)] = [("c", "CONSERVATIVE"), ("b", "BASE"), ("u", "BULL")]

    /// The three presets filled with current prices (×1.0 each), as the empty state offers.
    public static func createPresets(in doc: inout IntelDocument, prices: [AssetID: Decimal], now: Date) {
        for p in presets where !doc.scenarios.contains(where: { $0.key == p.key }) {
            doc.scenarios.append(PortfolioScenario(name: p.name, key: p.key, editedAt: now,
                                                   targets: prices.mapValues { ScenarioTarget(price: $0) }))
        }
    }

    /// The Base scenario's id, created empty if missing (watch conversion carries targets into it).
    @discardableResult
    public static func ensureBase(in doc: inout IntelDocument, now: Date) -> UUID {
        if let b = base(doc) { return b.id }
        let s = PortfolioScenario(name: "BASE", key: "b", editedAt: now)
        doc.scenarios.append(s)
        return s.id
    }

    public static func base(_ doc: IntelDocument) -> PortfolioScenario? { doc.scenarios.first { $0.key == "b" } ?? doc.scenarios.first }

    public static func duplicate(_ id: UUID, in doc: inout IntelDocument, now: Date) -> PortfolioScenario? {
        guard let s = doc.scenarios.first(where: { $0.id == id }) else { return nil }
        var name = s.name + " COPY", n = 2
        while doc.scenarios.contains(where: { $0.name == name }) { name = s.name + " COPY \(n)"; n += 1 }
        let d = PortfolioScenario(name: name, editedAt: now, targets: s.targets)
        doc.scenarios.append(d)
        return d
    }

    public static func rename(_ id: UUID, to raw: String, in doc: inout IntelDocument, now: Date) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !name.isEmpty, !doc.scenarios.contains(where: { $0.name == name && $0.id != id }),
              let i = doc.scenarios.firstIndex(where: { $0.id == id }) else { return false }
        doc.scenarios[i].name = name; doc.scenarios[i].editedAt = now
        return true
    }

    public static func delete(_ id: UUID, in doc: inout IntelDocument) { doc.scenarios.removeAll { $0.id == id } }

    public static func setTarget(_ asset: AssetID, price: Decimal, in id: UUID, doc: inout IntelDocument, now: Date) {
        guard let i = doc.scenarios.firstIndex(where: { $0.id == id }), price > 0 else { return }
        doc.scenarios[i].targets[asset, default: ScenarioTarget(price: price)].price = price
        doc.scenarios[i].editedAt = now
    }

    // MARK: projection

    public struct Holding: Equatable, Sendable {
        public init(asset: AssetID, quantity: Decimal, price: Decimal) { self.asset = asset; self.quantity = quantity; self.price = price }
        public let asset: AssetID
        public let quantity: Decimal
        public let price: Decimal
    }

    public struct Row: Equatable, Sendable {
        public let asset: AssetID
        public let quantity: Decimal
        public let price: Decimal
        public let target: Decimal
        public let isStable: Bool
        public let deltaPct: Double?
        public let valueNow: Decimal
        public let projected: Decimal
        public let upside: Decimal
        /// This asset's projected gain ÷ total projected gain (stablecoins excluded: nil).
        public let share: Double?
        public let hasTarget: Bool
    }

    public struct Projection: Equatable, Sendable {
        public let rows: [Row]
        public let valueNow: Decimal
        public let projected: Decimal
        public var upside: Decimal { projected - valueNow }
        public var multiple: Double? { valueNow > 0 ? (projected / valueNow).double : nil }
        public var upsidePct: Double? { valueNow > 0 ? ((projected / valueNow) - 1).double * 100 : nil }
        public var topShare: Double? { rows.compactMap(\.share).max() }
    }

    /// Projects current holdings to the scenario's targets. Assets without a target stay at
    /// today's price (zero upside); stablecoins are fixed at their peg.
    public static func project(_ s: PortfolioScenario, holdings: [Holding]) -> Projection {
        var rows: [Row] = []
        for h in holdings {
            let stable = Stablecoins.isStablecoin(h.asset)
            let t = stable ? (Stablecoins.peg(for: h.asset)?.target ?? 1) : (s.targets[h.asset]?.price ?? h.price)
            let now = h.quantity * h.price, proj = h.quantity * t
            rows.append(Row(asset: h.asset, quantity: h.quantity, price: h.price, target: t, isStable: stable,
                            deltaPct: h.price > 0 && !stable ? ((t / h.price) - 1).double * 100 : nil,
                            valueNow: now, projected: proj, upside: proj - now, share: nil, hasTarget: s.targets[h.asset] != nil))
        }
        let gain = rows.filter { !$0.isStable }.reduce(Decimal(0)) { $0 + $1.upside }
        rows = rows.map { r in
            Row(asset: r.asset, quantity: r.quantity, price: r.price, target: r.target, isStable: r.isStable, deltaPct: r.deltaPct,
                valueNow: r.valueNow, projected: r.projected, upside: r.upside,
                share: r.isStable || gain == 0 ? nil : (r.upside / gain).double, hasTarget: r.hasTarget)
        }
        return Projection(rows: rows, valueNow: rows.reduce(0) { $0 + $1.valueNow }, projected: rows.reduce(0) { $0 + $1.projected })
    }
}
