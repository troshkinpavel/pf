import PFCore
import PFCoreUI
import Foundation

// ⌘K 0.7 verbs (design §01): alert, watch, convert, scenario, compare — and a symbol lists every
// place it appears (ASSET · IN CONTEXT · ACTIONS). Parsed here, in the app: PFCore's Command enum
// is shared with the iPhone app and stays as it is.
extension AppStore {
    /// Items for a 0.7 verb, or nil when the line isn't one (the 0.6 parser takes over).
    func intelPaletteItems(_ line: String) -> [PaletteItem]? {
        let f = Fmt.current
        let toks = CommandParser.tokens(line)
        guard let verb = toks.first else { return nil }
        let args = Array(toks.dropFirst())
        switch verb {
        case "alert":
            switch parseAlert(line) {
            case let .success(d):
                let r = AlertRule(number: intel.nextAlertNumber, kind: d.kind, subject: d.subject, threshold: d.threshold, createdAt: Date())
                return [PaletteItem(label: "Alert · " + alertSubjectLabel(d.subject) + " " + AlertEngine.condition(r, fmt: f), detail: d.kind.label + " · review before arming",
                                    hint: "↵ review", isCommand: true, group: "ALERT", run: { [weak self] in
                    self?.palette = nil; self?.alertSetup = AlertSetup(line: line); self?.advanceAlertSetup()
                })]
            case let .failure(e):
                var out = [PaletteItem(label: "New alert", detail: e.description, hint: "↵ setup", isCommand: true, group: "ALERT", run: { [weak self] in
                    self?.palette = nil; self?.alertSetup = AlertSetup(line: line.hasSuffix(" ") ? line : line + " ")
                })]
                if args.count <= 1 {
                    out += AlertCommand.types.map { t in PaletteItem(label: "alert … " + t.key, detail: t.grammar, group: "ALERT", run: { [weak self] in
                        self?.palette = PaletteState(query: "alert " + (args.first.map { $0 + " " } ?? ""), sel: 0)
                    }) }
                }
                return out
            }
        case "watch" where !args.isEmpty:
            guard let a = resolveAsset(args[0]) ?? registrySearch(args[0]).first else {
                return [PaletteItem(label: "Watch \(args[0].uppercased())", detail: "no asset matches", isCommand: true, group: "WATCH", run: {})]
            }
            let nums = args.dropFirst().prefix(2).map { NumberInput.parse($0, style: f.style) }
            let note = args.dropFirst(3).joined(separator: " ")
            var detail = (quotes[a.id]?.price).map { "now " + f.price($0) } ?? a.name.lowercased()
            if let e = nums.first ?? nil { detail += " · entry " + f.price(e) }
            if nums.count > 1, let t = nums[1] { detail += " · target " + f.price(t) }
            if heldAnywhere.contains(a.id) { detail += " · already held" }
            return [PaletteItem(label: "Watch \(a.symbol)", detail: detail, hint: "↵ add", isCommand: true, group: "WATCH", run: { [weak self] in
                guard let self else { return }
                self.palette = nil
                self.watchDraft = WatchDraft(asset: a.symbol, entry: nums.first.flatMap { $0 }.map { "\($0)" } ?? "",
                                             target: (nums.count > 1 ? nums[1] : nil).map { "\($0)" } ?? "", note: note)
                self.saveWatch()
                self.go(.watch)
            })]
        case "convert":
            let active = intel.watchlist.filter(\.isActive)
            let hits = args.isEmpty ? active : active.filter { $0.asset.symbol.lowercased().hasPrefix(args[0]) }
            if hits.isEmpty { return [PaletteItem(label: "Convert", detail: args.isEmpty ? "nothing on the watchlist" : "\(args[0].uppercased()) isn't watched", isCommand: true, group: "CONVERT", run: {})] }
            return hits.prefix(5).map { w in
                PaletteItem(label: "Convert \(w.asset.symbol) → position", detail: "watched since " + DateFmt.ymd(w.addedAt) + (w.entry.map { " · entry " + f.price($0) } ?? ""),
                            hint: "↵ ⌘↵", isCommand: true, group: "CONVERT", run: { [weak self] in self?.palette = nil; self?.go(.watch); self?.convertWatch(w) })
            }
        case "scenario", "scenarios" where !args.isEmpty:
            let q = args.joined(separator: " ")
            let hits = orderedScenarios.filter { $0.key == q || $0.name.lowercased().hasPrefix(q) }
            return hits.map { s in
                let p = projection(s)
                return PaletteItem(label: "Scenario · " + s.name, detail: f.money(p.projected, 0) + " · " + (p.multiple.map { f.num($0, 1) + "×" } ?? "—"),
                                   hint: s.key ?? "↵", isCommand: true, group: "SCENARIO", run: { [weak self] in self?.palette = nil; self?.go(.scenarios); self?.selectScenario(s.id) })
            } + [PaletteItem(label: "New scenario", detail: "empty targets", hint: "n", isCommand: true, group: "SCENARIO", run: { [weak self] in self?.palette = nil; self?.go(.scenarios); self?.newScenario() })]
        case "compare", "benchmark", "vs":
            let r = args.first.flatMap { a in Benchmark.Range.allCases.first { $0.rawValue.lowercased() == a } }
            return [PaletteItem(label: "Benchmark · vs BTC · ETH" + (r.map { " · " + $0.rawValue } ?? ""), detail: "twr vs buy-and-hold", hint: "g b", isCommand: true, group: "COMPARE", run: { [weak self] in
                self?.palette = nil; self?.analyticsUsesBenchmark = true; self?.go(.benchmark)
                if let r { self?.setBenchmarkRange(r) } else { self?.loadBenchmarkHistory() }
            })]
        default:
            return nil
        }
    }

    /// A bare symbol: the asset, where it appears, what can be done with it.
    func symbolPaletteItems(_ a: Asset) -> [PaletteItem] {
        let f = Fmt.current, id = a.id, sym = a.symbol.lowercased()
        var out: [PaletteItem] = []
        let v = summary.valuation(id)
        let held = heldAnywhere.contains(id), w = watchContext(id)
        let assetDetail = v.map { f.money($0.value, 0) + ($0.allocation.map { " · " + f.num($0, 1) + "%" } ?? "") }
        out.append(PaletteItem(label: a.symbol + "  " + a.name, detail: held ? "held" + (assetDetail.map { " · " + $0 } ?? "") : w?.isActive == true ? "watched" : (quotes[id]?.price).map { f.price($0) } ?? "not held",
                               hint: "↵", isCommand: true, group: "ASSET", run: { [weak self] in self?.openAssetOrAdd(a) }))
        if held, let r = attribution(.d7), let x = r.assets.first(where: { $0.id == id }) {
            let rank = (r.byImpact.firstIndex { $0.id == id } ?? 0) + 1
            out.append(PaletteItem(label: "what changed · " + a.symbol, detail: "7d impact " + f.signed(x.contribution, 0) + " · #\(rank)", hint: "g c", group: "IN CONTEXT",
                                   run: { [weak self] in self?.palette = nil; self?.wcPeriod = .d7; self?.changesUsesMovers = false; self?.go(.changes) }))
        }
        let rules = intel.alerts.filter { $0.subject == .asset(id) }
        if let r = rules.first {
            out.append(PaletteItem(label: "alerts · " + a.symbol, detail: "#\(r.number) " + AlertEngine.condition(r, fmt: f) + (rules.count > 1 ? " · +\(rules.count - 1)" : ""), hint: "g a", group: "IN CONTEXT",
                                   run: { [weak self] in self?.palette = nil; self?.go(.alerts) }))
        }
        let scen = orderedScenarios.filter { $0.targets[id] != nil }
        if !scen.isEmpty {
            out.append(PaletteItem(label: "scenarios · " + a.symbol, detail: scen.prefix(3).map { ($0.key ?? "·") + " " + f.level($0.targets[id]!.price) }.joined(separator: " · "), hint: "g s", group: "IN CONTEXT",
                                   run: { [weak self] in self?.palette = nil; self?.go(.scenarios) }))
        }
        if let w {
            out.append(PaletteItem(label: "watch history · " + a.symbol, detail: "added " + DateFmt.ymd(w.addedAt) + (w.isActive ? "" : " · converted"), hint: "g w", group: "IN CONTEXT",
                                   run: { [weak self] in self?.palette = nil; self?.go(.watch) }))
        }
        out.append(PaletteItem(label: "alert \(sym) …", detail: "price · pnl · weight · move", hint: "⇥", group: "ACTIONS",
                               run: { [weak self] in self?.palette = PaletteState(query: "alert \(sym) ", sel: 0) }))
        if !held && w?.isActive != true {
            out.append(PaletteItem(label: "watch \(sym)", detail: "follow without buying", hint: "↵", group: "ACTIONS",
                                   run: { [weak self] in self?.palette = PaletteState(query: "watch \(sym) ", sel: 0) }))
        }
        out.append(PaletteItem(label: "add transaction \(sym)", detail: "buy / sell", hint: "⌘N", group: "ACTIONS", run: { [weak self] in self?.openTx(TxDraft(asset: a.symbol)) }))
        if v != nil {
            out.append(PaletteItem(label: "target \(sym) …", detail: "quick calculator", hint: "t", group: "ACTIONS", run: { [weak self] in self?.openTarget(id) }))
        }
        return out
    }
}
