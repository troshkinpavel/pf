import PFCore
import PFCoreUI
import Foundation

// Scenarios / Targets 2.0 (design §09): named sets of per-asset target prices, projected on
// the current portfolio's holdings. Your targets, not forecasts. Stored in intel.json.

extension AppStore {
    var scenarioHoldings: [Scenarios.Holding] {
        summary.positions.compactMap { v in v.price.map { Scenarios.Holding(asset: v.asset.id, quantity: v.position.quantity, price: $0) } }
    }

    func projection(_ s: PortfolioScenario) -> Scenarios.Projection { Scenarios.project(s, holdings: scenarioHoldings) }

    /// Presets first (c · b · u), then the user's own, in creation order.
    var orderedScenarios: [PortfolioScenario] {
        let keyed = Scenarios.presets.compactMap { p in intel.scenarios.first { $0.key == p.key } }
        return keyed + intel.scenarios.filter { s in !keyed.contains { $0.id == s.id } }
    }

    func selectScenario(_ id: UUID) {
        scenarioID = id; scenarioEdit = nil; scenarioRename = nil; scenarioConfirmDelete = nil
    }

    func selectScenario(key: String) -> Bool {
        guard let s = intel.scenarios.first(where: { $0.key == key }) else { return false }
        selectScenario(s.id)
        return true
    }

    /// The empty state's action: c · b · u at today's prices (×1.0), ready to edit.
    func createPresetScenarios() {
        let prices = Dictionary(uniqueKeysWithValues: scenarioHoldings.map { ($0.asset, $0.price) })
        updateIntel { Scenarios.createPresets(in: &$0, prices: prices, now: Date()) }
        if let b = Scenarios.base(intel) { selectScenario(b.id) }
        message = "✓ conservative · base · bull created at today's prices · ↵ to edit a target"
    }

    func newScenario() {
        var n = intel.scenarios.count + 1
        while intel.scenarios.contains(where: { $0.name == "SCENARIO \(n)" }) { n += 1 }
        let s = PortfolioScenario(name: "SCENARIO \(n)", editedAt: Date())
        guard updateIntel({ $0.scenarios.append(s) }) else { return }
        selectScenario(s.id)
        scenarioRename = s.name
    }

    func duplicateScenario() {
        guard let cur = currentScenario else { return }
        var copy: PortfolioScenario?
        updateIntel { copy = Scenarios.duplicate(cur.id, in: &$0, now: Date()) }
        if let copy { selectScenario(copy.id); message = "✓ \(cur.name) duplicated as \(copy.name) · r renames" }
    }

    func commitScenarioRename() {
        guard let cur = currentScenario, let name = scenarioRename else { return }
        var ok = false
        updateIntel { ok = Scenarios.rename(cur.id, to: name, in: &$0, now: Date()) }
        if ok { scenarioRename = nil } else { message = "✗ name is empty or already used" }
    }

    func requestDeleteScenario() {
        guard let cur = currentScenario else { return }
        if scenarioConfirmDelete == cur.id {
            updateIntel { Scenarios.delete(cur.id, in: &$0) }
            scenarioConfirmDelete = nil
            scenarioID = nil
            message = "✓ \(cur.name) deleted"
        } else {
            scenarioConfirmDelete = cur.id
            message = "⌫ again to delete \(cur.name) · esc keeps it"
        }
    }

    /// ↵ on a row: TARGET becomes the 0.6 target input (same parser: 25x, 150k, .1).
    func beginScenarioEdit() {
        guard let cur = currentScenario, let r = projection(cur).rows[safe: scenarioRow], !r.isStable else { return }
        scenarioEdit = r.hasTarget ? "\(r.target)" : ""
    }

    func commitScenarioEdit() {
        guard let cur = currentScenario, let text = scenarioEdit, let r = projection(cur).rows[safe: scenarioRow] else { return }
        // "30%" sets the target weight (Overview ▲, Asset Detail allocation); "" clears it.
        let raw = text.trimmingCharacters(in: .whitespaces)
        if raw.hasSuffix("%") {
            let w = NumberInput.parse(String(raw.dropLast()), style: Fmt.current.style)?.double
            guard raw == "%" || (w.map { $0 > 0 && $0 <= 100 } ?? false) else { message = "✗ weight: 1–100%"; return }
            updateIntel { d in
                guard let i = d.scenarios.firstIndex(where: { $0.id == cur.id }) else { return }
                d.scenarios[i].targets[r.asset, default: ScenarioTarget(price: r.price)].weight = w
                d.scenarios[i].editedAt = Date()
            }
            scenarioEdit = nil
            return
        }
        guard let t = NumberInput.target(text, current: r.price), t > 0 else { message = "✗ target: a price, a multiple like 3x, or a weight like 30%"; return }
        updateIntel { Scenarios.setTarget(r.asset, price: t, in: cur.id, doc: &$0, now: Date()) }
        scenarioEdit = nil
        if scenarioRow < projection(cur).rows.count - 1 { scenarioRow += 1 }
    }

    /// Target screen (s): the calculator's value into the Base scenario (created if missing).
    func saveTargetToScenario() {
        guard let v = targetValuation, let px = v.price, let t = NumberInput.target(targetInput, current: px), t > 0 else {
            message = "✗ type a target first"; return
        }
        var name = ""
        updateIntel { d in
            let id = Scenarios.ensureBase(in: &d, now: Date())
            Scenarios.setTarget(v.asset.id, price: t, in: id, doc: &d, now: Date())
            name = d.scenarios.first { $0.id == id }?.name ?? "BASE"
        }
        message = "✓ \(v.asset.symbol) target \(Fmt.current.price(t)) saved to \(name) · g s opens scenarios"
    }
}
