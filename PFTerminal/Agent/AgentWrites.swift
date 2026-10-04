import PFCore
import Foundation

// Write tools (read + write only). Each one validates with the app's own logic
// (TransactionPlanner, PortfolioEngine, AlertCommand, Watchlist, Scenarios), freezes the result
// in an AgentOperation, and runs only that: immediately for unconfirmed intel writes, or after
// the user confirms in PF. Running re-checks the current data and fails with `conflict` if the
// thing changed meanwhile.

extension AppStore {
    func agentWrite(_ tool: AgentTool, _ a: AgentArgs) throws -> AgentOutcome {
        switch tool.name {
        case "pf_add_transaction": return .confirm(try agentAddTransaction(a))
        case "pf_update_transaction": return .confirm(try agentUpdateTransaction(a))
        case "pf_delete_transaction": return .confirm(try agentDeleteTransaction(a))
        case "pf_convert_watch_to_position": return .confirm(try agentConvertWatch(a))
        case "pf_add_watch": return .confirm(try agentAddWatch(a))
        case "pf_update_watch": return .confirm(try agentUpdateWatch(a))
        case "pf_remove_watch": return .confirm(try agentRemoveWatch(a))
        case "pf_create_alert": return .confirm(try agentAlertOp(a, editing: nil))
        case "pf_update_alert": return .confirm(try agentAlertOp(a, editing: try agentRule(a)))
        case "pf_pause_alert": return .confirm(try agentPauseAlert(a))
        case "pf_rearm_alert": return .confirm(try agentRearmAlert(a))
        case "pf_delete_alert": return .confirm(try agentDeleteAlert(a))
        case "pf_create_scenario": return .confirm(try agentCreateScenario(a))
        case "pf_update_scenario": return .confirm(try agentUpdateScenario(a))
        case "pf_duplicate_scenario": return .confirm(try agentDuplicateScenario(a))
        case "pf_delete_scenario": return .confirm(try agentDeleteScenario(a))
        default: throw AgentFailure(.unknownTool)
        }
    }

    // MARK: transactions

    /// Parses agent amounts as plain decimals regardless of the user's number format.
    private static let agentFmt = Fmt(style: .comma, currency: "USD")

    private static func typeArg(_ s: String) -> TransactionType {
        switch s { case "sell": .sell; case "transfer_in": .transferIn; case "transfer_out": .transferOut; default: .buy }
    }

    /// Draft → TransactionPlanner (the sheet's own validation) → frozen transaction.
    private func agentPlan(_ d: TxDraft, asset: Asset) throws -> TxPreview {
        var draft = d
        draft.candidateQuotes = agentQuote(asset.id).map { [asset.id: $0] } ?? [:]
        let f = Fmt(style: .comma, currency: settings.currency)
        let p = TransactionPlanner.preview(draft, doc: doc, quotes: valuationQuotes, currency: settings.currency, resolve: { _, _ in asset }, fmt: f)
        guard p.ok, p.tx != nil else {
            let why = p.error ?? (draft.price.isEmpty ? "no market price for that date · pass price" : "invalid transaction")
            throw AgentFailure(.validationFailed, why)
        }
        return p
    }

    /// Weight of the asset and portfolio value before / after, from the real engine.
    private func agentImpact(_ t: Transaction, asset a: Asset, removing old: Transaction?) -> [(String, JSON?)] {
        let pid = t.portfolioID, ex = agentExposure
        let assets = Dictionary((doc.assets + [a]).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let before = summary(for: .portfolio(pid))
        var ledger = doc.transactions.filter { $0.portfolioID == pid && $0.id != (old?.id ?? t.id) }
        ledger.append(t)
        var q = valuationQuotes
        if q[t.assetID] == nil, let x = agentQuote(t.assetID) { q[t.assetID] = x }
        let after = PortfolioEngine.summarize(ledgers: [ledger], assets: assets, quotes: q)
        let wb = before.valuation(t.assetID)?.allocation, wa = after.valuation(t.assetID)?.allocation
        var out: [(String, JSON?)] = [("weight_before_pct", .pct(wb)), ("weight_after_pct", .pct(wa)),
                                      ("portfolio_value_before", ex.money(before.totalValue)), ("portfolio_value_after", ex.money(after.totalValue)),
                                      ("position_after", ex.qty(after.valuation(t.assetID)?.position.quantity ?? 0)),
                                      ("average_entry_after", ex.money(after.valuation(t.assetID)?.position.averageEntry))]
        if agentQuote(t.assetID) == nil { out.append(("weight_note", .str("no market price for \(a.symbol) yet: weights after are unknown"))) }
        if agent.settings.exposeScenarios, let tw = targetWeight(t.assetID), let wa, wa > tw {
            out.append(("target_weight_warning", .str("weight after (\(Fmt.current.num(wa, 1))%) is above the Base target weight (\(Fmt.current.num(tw, 1))%)")))
        }
        return out
    }

    private func txLine(_ t: Transaction, _ sym: String, exact: Bool) -> String {
        let f = Fmt.current
        return exact ? "\(t.type.short) \(f.amount(t.quantity)) \(sym) @ \(f.price(t.price))" : "\(t.type.short) \(sym)"
    }

    private func txLines(_ t: Transaction, _ sym: String, exact: Bool) -> [String] {
        let f = Fmt.current
        var l = [txLine(t, sym, exact: exact), "portfolio " + (doc.portfolio(t.portfolioID)?.name ?? "?"), "date " + DateFmt.ymd(t.timestamp)]
        if exact {
            l.append((t.type == .sell ? "proceeds " : "cost ") + f.money(t.type == .sell ? t.quantity * t.price - t.fee : t.quantity * t.price + t.fee))
            if t.fee > 0 { l.append("fee " + f.money(t.fee)) }
        }
        if let n = t.note, !n.isEmpty, exact || agent.settings.exposeNotes { l.append("note " + n) }
        return l
    }

    /// Ledger of `pid` with `t` (replacing `old`) must stay valid at run time.
    private func agentRevalidate(_ t: Transaction, replacing old: Transaction?) throws {
        var ledger = doc.transactions.filter { $0.portfolioID == t.portfolioID && $0.id != (old?.id ?? t.id) }
        ledger.append(t)
        if let e = PortfolioEngine.validate(ledger).first { throw AgentFailure(.conflict, "the ledger changed: \(e.description)") }
        guard !ledgerLoadDeferred, !protectedDataWaiting else { throw AgentFailure(.protectedDataUnavailable) }
    }

    func agentAddTransaction(_ a: AgentArgs) throws -> AgentOperation {
        let p = try agentWritePortfolio(a)
        let asset = try agentAsset(try a.string("asset", required: true)!)
        let type = Self.typeArg(try a.choice("type", ["buy", "sell", "transfer_in", "transfer_out"])!)
        let amount = try a.decimal("amount", required: true, positive: true)!
        let price = try a.decimal("price", nonNegative: true)
        let fee = try a.decimal("fee", nonNegative: true)
        let date = try a.date("date") ?? DateFmt.ymd(Date())
        let note = try a.string("note", max: 500) ?? ""
        let d = TxDraft(portfolioID: p.id, type: type, asset: asset.id, amount: "\(amount)", price: price.map { "\($0)" } ?? "",
                        date: date, fee: fee.map { "\($0)" } ?? "", note: note)
        let plan = try agentPlan(d, asset: asset)
        let t = plan.tx!
        return agentTxOperation(title: "add transaction", t, asset: asset, replacing: nil, plan: plan) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            try self.agentRevalidate(t, replacing: nil)
            self.commitTransaction(t, asset: asset)
            return .obj([("status", "recorded"), ("transaction", self.agentTransactionJSON(t, asset: asset))])
        }
    }

    private func agentTxOperation(title: String, _ t: Transaction, asset: Asset, replacing old: Transaction?, plan: TxPreview?,
                                  run: @escaping @MainActor () throws -> JSON) -> AgentOperation {
        let exact = agent.settings.exposeValues, f = Fmt.current
        var user = txLines(t, asset.symbol, exact: true)
        if let old { user.insert("was " + txLine(old, asset.symbol, exact: true) + " · " + DateFmt.ymd(old.timestamp), at: 1) }
        if let b = plan?.before, let af = plan?.after {
            user.append("position \(f.amount(b.quantity)) → \(f.amount(af.quantity)) \(asset.symbol)")
            if t.type == .buy, let e = af.averageEntry { user.append("avg entry " + (b.averageEntry.map(f.price) ?? "—") + " → " + f.price(e)) }
            if t.type == .sell { user.append("realized p&l " + f.signed(af.realizedPnL - b.realizedPnL)) }
        }
        var agentLines = txLines(t, asset.symbol, exact: exact)
        if let old { agentLines.insert("was " + txLine(old, asset.symbol, exact: exact) + " · " + DateFmt.ymd(old.timestamp), at: 1) }
        let preview: JSON = .compact([("dry_run", true), ("would", .str(title)), ("transaction", agentTransactionJSON(t, asset: asset))] + agentImpact(t, asset: asset, removing: old) + [
            ("summary", .arr(agentLines.map(JSON.str))), ("confirmation", "a real call needs the user's confirmation in PF Terminal"),
        ])
        return AgentOperation(title: title + " · " + txLine(t, asset.symbol, exact: true), userLines: user, agentLines: agentLines, portfolio: t.portfolioID, preview: preview, run: run)
    }

    private func agentFindTransaction(_ a: AgentArgs) throws -> Transaction {
        guard let s = try a.string("transaction_id", required: true, max: 40), let id = UUID(uuidString: s) else { throw AgentFailure(.invalidArgument, "transaction_id must be a transaction id") }
        guard let t = doc.transactions.first(where: { $0.id == id }), doc.portfolio(t.portfolioID)?.isArchived == false else { throw AgentFailure(.transactionNotFound) }
        return t
    }

    func agentUpdateTransaction(_ a: AgentArgs) throws -> AgentOperation {
        let old = try agentFindTransaction(a)
        guard let asset = asset(old.assetID) else { throw AgentFailure(.assetNotFound) }
        guard a.raw.count > 1 || a.has("dry_run") && a.raw.count > 2 else { throw AgentFailure(.invalidArgument, "nothing to change") }
        let type = try a.choice("type", ["buy", "sell", "transfer_in", "transfer_out"]).map(Self.typeArg) ?? old.type
        let amount = try a.decimal("amount", positive: true) ?? old.quantity
        let price = try a.decimal("price", nonNegative: true) ?? old.price
        let fee = try a.decimal("fee", nonNegative: true) ?? old.fee
        let date = try a.date("date") ?? DateFmt.ymd(old.timestamp)
        let note = a.isNull("note") ? "" : (try a.string("note", max: 500) ?? old.note ?? "")
        let d = TxDraft(editing: old.id, portfolioID: old.portfolioID, type: type, asset: asset.id, amount: "\(amount)", price: "\(price)",
                        date: date, fee: "\(fee)", note: note)
        let plan = try agentPlan(d, asset: asset)
        let t = plan.tx!
        return agentTxOperation(title: "update transaction", t, asset: asset, replacing: old, plan: plan) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.doc.transactions.first(where: { $0.id == old.id }) == old else { throw AgentFailure(.conflict, "the transaction changed since the request") }
            try self.agentRevalidate(t, replacing: old)
            guard self.safetySnapshot(.beforeAgent) else { throw AgentFailure(.internalError, "could not save a recovery snapshot first · nothing changed") }
            self.commitTransaction(t, asset: asset)
            return .obj([("status", "updated"), ("transaction", self.agentTransactionJSON(t, asset: asset))])
        }
    }

    func agentDeleteTransaction(_ a: AgentArgs) throws -> AgentOperation {
        let t = try agentFindTransaction(a)
        var probe = doc
        do { try probe.removeTransaction(t) } catch { throw AgentFailure(.validationFailed, "a later transaction depends on it: \(error)") }
        let sym = asset(t.assetID)?.symbol ?? t.assetID
        let exact = agent.settings.exposeValues
        let after = PortfolioEngine.positions(probe.transactions.filter { $0.portfolioID == t.portfolioID })[t.assetID]
        let preview: JSON = .compact([("dry_run", true), ("would", "delete transaction"), ("transaction", agentTransactionJSON(t)),
                                      ("position_after", agentExposure.qty(after?.quantity ?? 0)),
                                      ("snapshot", "a recovery snapshot is taken before deleting")])
        let user = ["delete " + txLine(t, sym, exact: true)] + Array(txLines(t, sym, exact: true).dropFirst())
        let agentLines = ["delete " + txLine(t, sym, exact: exact)] + Array(txLines(t, sym, exact: exact).dropFirst())
        return AgentOperation(title: "delete transaction · " + txLine(t, sym, exact: true), userLines: user, agentLines: agentLines, portfolio: t.portfolioID, preview: preview) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.doc.transactions.first(where: { $0.id == t.id }) == t else { throw AgentFailure(.conflict, "the transaction changed or is gone") }
            guard !self.ledgerLoadDeferred, !self.protectedDataWaiting else { throw AgentFailure(.protectedDataUnavailable) }
            guard self.safetySnapshot(.beforeAgent) else { throw AgentFailure(.internalError, "could not save a recovery snapshot first · nothing changed") }
            do { try self.removeTransactionCommitted(t) } catch { throw AgentFailure(.conflict, "a later transaction depends on it") }
            return .obj([("status", "deleted"), ("transaction_id", .str(t.id.uuidString))])
        }
    }

    func agentConvertWatch(_ a: AgentArgs) throws -> AgentOperation {
        let asset = try agentAsset(try a.string("asset", required: true)!)
        guard let w = intel.watchlist.first(where: { $0.assetID == asset.id && $0.isActive }) else { throw AgentFailure(.watchNotFound, "\(asset.symbol) isn't on the watchlist") }
        guard intelReadOnly == nil, !intelPrivateDeferred else { throw AgentFailure(.protectedDataUnavailable) }
        let p = try agentWritePortfolio(a)
        let amount = try a.decimal("amount", required: true, positive: true)!
        let price = try a.decimal("price", nonNegative: true)
        let fee = try a.decimal("fee", nonNegative: true)
        let date = try a.date("date") ?? DateFmt.ymd(Date())
        let carry = WatchConversion.CarryOver(target: try a.boolStrict("carry_target") ?? true, note: try a.boolStrict("carry_note") ?? true, alert: try a.boolStrict("carry_alert") ?? true)
        let d = TxDraft(portfolioID: p.id, type: .buy, asset: asset.id, amount: "\(amount)", price: price.map { "\($0)" } ?? "",
                        date: date, fee: fee.map { "\($0)" } ?? "", note: carry.note ? (w.note ?? "") : "")
        let plan = try agentPlan(d, asset: w.asset)
        let t = plan.tx!
        var op = agentTxOperation(title: "convert watch → position", t, asset: w.asset, replacing: nil, plan: plan) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard let cur = self.intel.watchlist.first(where: { $0.id == w.id }), cur.isActive else { throw AgentFailure(.conflict, "the watch item changed") }
            try self.agentRevalidate(t, replacing: nil)
            self.commitTransaction(t, asset: w.asset)
            self.finishConversion(WatchConvertState(item: cur, carry: carry), tx: t)   // carry-over + ⌘Z undo, as in the app
            return .obj([("status", "converted"), ("transaction", self.agentTransactionJSON(t, asset: w.asset)), ("watch", "archived")])
        }
        var carried: [String] = []
        if carry.target, w.target != nil { carried.append("target → Base scenario") }
        if carry.alert, w.target != nil { carried.append("target alert armed") }
        if carry.note, w.note != nil { carried.append("note") }
        if !carried.isEmpty { op.userLines.append("carries " + carried.joined(separator: " · ")); op.agentLines.append("carries " + carried.joined(separator: " · ")) }
        op.userLines.append("the watch item is archived · ⌘Z undoes both")
        return op
    }

    // MARK: watchlist

    /// updateIntel for agents: refusal → a stable error instead of a status message.
    private func agentUpdateIntel(_ change: (inout IntelDocument) -> Void) throws {
        if let r = intelReadOnly { throw AgentFailure(.validationFailed, r) }
        if intelPrivateDeferred { throw AgentFailure(.protectedDataUnavailable) }
        guard updateIntel(change) else { throw AgentFailure(.protectedDataUnavailable) }
    }

    private func agentWatchJSON(_ id: AssetID) -> JSON {
        guard let r = watchRows.first(where: { $0.item.assetID == id }) else { return .null }
        return .compact([("watch_id", .str(r.item.id.uuidString)), ("asset_id", .str(id)), ("symbol", .str(r.item.asset.symbol)),
                         ("entry", .opt(r.item.entry)), ("target", .opt(r.item.target)), ("note", agentExposure.note(r.item.note))])
    }

    private func intelOp(_ title: String, _ lines: [String], preview: JSON = .null, run: @escaping @MainActor () throws -> JSON) -> AgentOperation {
        AgentOperation(title: title, userLines: lines, agentLines: lines, portfolio: nil,
                       preview: preview == .null ? .obj([("dry_run", true), ("would", .str(title)), ("summary", .arr(lines.map(JSON.str)))]) : preview, run: run)
    }

    func agentAddWatch(_ a: AgentArgs) throws -> AgentOperation {
        let asset = try agentAsset(try a.string("asset", required: true)!)
        let entry = try a.decimal("entry", positive: true), target = try a.decimal("target", positive: true)
        let note = try a.string("note", max: 500)
        let f = Fmt.current
        var lines = ["watch \(asset.symbol) · \(asset.name)"]
        if let entry { lines.append("entry " + f.price(entry)) }
        if let target { lines.append("target " + f.price(target)) }
        var userLines = lines
        if let note { userLines.append("note " + note); if agent.settings.exposeNotes { lines.append("note " + note) } }
        var op = intelOp("add to watchlist · \(asset.symbol)", lines) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            try self.agentUpdateIntel { Watchlist.add(asset, price: self.quotes[asset.id]?.price, entry: entry, target: target, note: note, to: &$0, now: Date()) }
            if self.quotes[asset.id] == nil { Task { await self.refresh(auto: false) } }
            return .obj([("status", "watching"), ("watch", self.agentWatchJSON(asset.id))])
        }
        op.userLines = userLines
        return op
    }

    func agentUpdateWatch(_ a: AgentArgs) throws -> AgentOperation {
        let asset = try agentAsset(try a.string("asset", required: true)!)
        guard let w = intel.watchlist.first(where: { $0.assetID == asset.id && $0.isActive }) else { throw AgentFailure(.watchNotFound, "\(asset.symbol) isn't on the watchlist") }
        guard a.has("entry") || a.has("target") || a.has("note") else { throw AgentFailure(.invalidArgument, "nothing to change") }
        let entry: Decimal?? = a.has("entry") ? .some(try a.decimal("entry", positive: true)) : .none
        let target: Decimal?? = a.has("target") ? .some(try a.decimal("target", positive: true)) : .none
        let note: String?? = a.has("note") ? .some(try a.string("note", max: 500)) : .none
        let f = Fmt.current
        var lines = ["update watch \(asset.symbol)"]
        if let e = entry { lines.append("entry " + (e.map(f.price) ?? "cleared")) }
        if let t = target { lines.append("target " + (t.map(f.price) ?? "cleared")) }
        if let n = note { lines.append("note " + (n == nil ? "cleared" : agent.settings.exposeNotes ? n! : "changed")) }
        return intelOp("update watch · \(asset.symbol)", lines) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.watchlist.contains(where: { $0.id == w.id && $0.isActive }) else { throw AgentFailure(.conflict, "the watch item changed") }
            try self.agentUpdateIntel { d in
                guard let i = d.watchlist.firstIndex(where: { $0.id == w.id }) else { return }
                if let e = entry { d.watchlist[i].entry = e }
                if let t = target { d.watchlist[i].target = t }
                if let n = note { d.watchlist[i].note = (n?.isEmpty ?? true) ? nil : n }
            }
            return .obj([("status", "updated"), ("watch", self.agentWatchJSON(asset.id))])
        }
    }

    func agentRemoveWatch(_ a: AgentArgs) throws -> AgentOperation {
        let asset = try agentAsset(try a.string("asset", required: true)!)
        guard let w = intel.watchlist.first(where: { $0.assetID == asset.id && $0.isActive }) else { throw AgentFailure(.watchNotFound, "\(asset.symbol) isn't on the watchlist") }
        return intelOp("remove from watchlist · \(asset.symbol)", ["remove \(asset.symbol) from the watchlist", "entry, target and note are deleted"]) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.watchlist.contains(where: { $0.id == w.id }) else { throw AgentFailure(.conflict, "the watch item is gone") }
            try self.agentUpdateIntel { Watchlist.remove(w.id, from: &$0) }
            return .obj([("status", "removed"), ("asset_id", .str(asset.id))])
        }
    }

    // MARK: alerts

    private func agentRule(_ a: AgentArgs) throws -> AlertRule {
        let n = try a.int("alert", required: true, range: 1...100_000)!
        guard let r = intel.alerts.first(where: { $0.number == n }) else { throw AgentFailure(.alertNotFound, "no alert #\(n)") }
        return r
    }

    private static func repeatArg(_ s: String?) -> AlertRepeat? {
        switch s { case "once"?: .once; case "cross"?: .cross; case "daily"?: .daily; default: nil }
    }

    private func alertText(_ r: AlertRule) -> String {
        let valueRule = r.kind == .valueAbove || r.kind == .valueBelow
        return "#\(r.number) " + alertSubjectLabel(r.subject) + " " + (valueRule && !agent.settings.exposeValues ? r.kind.label : AlertEngine.condition(r, fmt: .current))
    }

    func agentAlertOp(_ a: AgentArgs, editing old: AlertRule?) throws -> AgentOperation {
        let cond = try a.string("condition", required: old == nil, max: 120)
        let rep = Self.repeatArg(try a.choice("repeat", ["once", "cross", "daily"]))
        let note: String?? = a.has("note") ? .some(try a.string("note", max: 300)) : .none
        var draft: AlertCommand.Draft?
        if let cond {
            switch parseAlert("alert " + cond) {
            case let .success(d): draft = d
            case let .failure(e): throw AgentFailure(.invalidArgument, "condition: \(e.description)")
            }
            guard draft!.threshold.isFinite else { throw AgentFailure(.invalidArgument, "condition: threshold must be a number") }
        }
        if old != nil, cond == nil, rep == nil, note == nil { throw AgentFailure(.invalidArgument, "nothing to change") }
        var r = old ?? AlertRule(number: intel.nextAlertNumber, kind: draft!.kind, subject: draft!.subject, threshold: draft!.threshold, createdAt: Date())
        if let d = draft { r.kind = d.kind; r.subject = d.subject; r.threshold = d.threshold }
        if let rep { r.repeatMode = rep }
        if r.kind == .depeg && r.repeatMode == .once { r.repeatMode = .cross }
        if let n = note { r.note = (n?.isEmpty ?? true) ? nil : n }
        let frozen = r
        let review = setupReview(frozen)
        let lines = [(old == nil ? "create alert " : "update alert ") + alertText(frozen), "repeat " + frozen.repeatMode.rawValue]
            + (review.overlaps.isEmpty ? [] : ["overlaps " + review.overlaps.map { "#\($0.number)" }.joined(separator: ", ")])
        let preview: JSON = .compact([("dry_run", true), ("would", .str(old == nil ? "create alert" : "update alert")), ("rule", agentAlertJSON(frozen)),
                                      ("backtest_30d_fired", review.fired.map { .int($0.count) }),
                                      ("backtest_30d_dates", review.fired.map { .arr($0.prefix(10).map { .date($0) }) }),
                                      ("overlaps", .arr(review.overlaps.map { .int($0.number) }))])
        return intelOp((old == nil ? "create alert · " : "update alert · ") + alertText(frozen), lines, preview: preview) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            var x = frozen
            if let old {
                guard let cur = self.intel.alerts.first(where: { $0.id == old.id }) else { throw AgentFailure(.conflict, "alert #\(old.number) is gone") }
                x.createdAt = cur.createdAt
                // An edit that changes what the rule watches starts armed again (as in the app).
                if cur.kind == x.kind && cur.subject == x.subject && cur.threshold == x.threshold { x.state = cur.state; x.firedAt = cur.firedAt }
                else { x.state = .armed; x.firedAt = nil; x.unseen = false }
                try self.agentUpdateIntel { d in if let i = d.alerts.firstIndex(where: { $0.id == old.id }) { d.alerts[i] = x } }
            } else {
                x.number = self.intel.nextAlertNumber
                try self.agentUpdateIntel { $0.alerts.append(x) }
                if self.settings.alertBanner { Notifier.requestAuthorization() }
            }
            self.evaluateAlerts()
            return .obj([("status", .str(old == nil ? "armed" : "saved")), ("rule", self.agentAlertJSON(self.intel.alerts.first { $0.id == x.id } ?? x))])
        }
    }

    func agentPauseAlert(_ a: AgentArgs) throws -> AgentOperation {
        let r = try agentRule(a)
        let paused = try a.boolStrict("paused", required: true)!
        return intelOp((paused ? "pause " : "resume ") + alertText(r), [(paused ? "pause " : "resume ") + alertText(r)]) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.alerts.contains(where: { $0.id == r.id }) else { throw AgentFailure(.conflict, "alert #\(r.number) is gone") }
            try self.agentUpdateIntel { d in if let i = d.alerts.firstIndex(where: { $0.id == r.id }) { d.alerts[i].paused = paused } }
            return .obj([("status", .str(paused ? "paused" : "resumed")), ("alert", .int(r.number))])
        }
    }

    func agentRearmAlert(_ a: AgentArgs) throws -> AgentOperation {
        let r = try agentRule(a)
        return intelOp("re-arm " + alertText(r), ["re-arm " + alertText(r)]) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.alerts.contains(where: { $0.id == r.id }) else { throw AgentFailure(.conflict, "alert #\(r.number) is gone") }
            try self.agentUpdateIntel { d in if let i = d.alerts.firstIndex(where: { $0.id == r.id }) { d.alerts[i].state = .armed; d.alerts[i].unseen = false; d.alerts[i].firedAt = nil } }
            return .obj([("status", "armed"), ("alert", .int(r.number))])
        }
    }

    func agentDeleteAlert(_ a: AgentArgs) throws -> AgentOperation {
        let r = try agentRule(a)
        return intelOp("delete " + alertText(r), ["delete " + alertText(r), "its log entries stay"]) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.alerts.contains(where: { $0.id == r.id }) else { throw AgentFailure(.conflict, "alert #\(r.number) is gone") }
            try self.agentUpdateIntel { $0.alerts.removeAll { $0.id == r.id } }
            return .obj([("status", "deleted"), ("alert", .int(r.number))])
        }
    }

    // MARK: scenarios

    private func agentScenario(_ a: AgentArgs) throws -> PortfolioScenario {
        let s = try a.string("scenario", required: true, max: 60)!
        let l = s.lowercased()
        if let x = intel.scenarios.first(where: { $0.key == l || $0.name.lowercased() == l || $0.id.uuidString.lowercased() == l }) { return x }
        throw AgentFailure(.scenarioNotFound, "no scenario named \(s.prefix(40))")
    }

    /// targets: [{asset, price?, weight?}] → validated (asset, price?, weight?? ) triples.
    private func agentTargets(_ a: AgentArgs) throws -> [(Asset, Decimal?, Double??)] {
        guard let v = a.value("targets"), !v.isNull else { return [] }
        guard let items = v.array, items.count <= 100 else { throw AgentFailure(.invalidArgument, "targets must be a list (≤ 100)") }
        return try items.map { item in
            let t = try AgentArgs(item, allowed: ["asset", "price", "weight"])
            let asset = try agentAsset(try t.string("asset", required: true)!)
            let price = try t.decimal("price", positive: true)
            var weight: Double?? = .none
            if t.has("weight") {
                if t.isNull("weight") { weight = .some(nil) } else {
                    let w = try t.decimal("weight", positive: true)!.double
                    guard w <= 100 else { throw AgentFailure(.invalidArgument, "weight must be 0–100") }
                    weight = .some(w)
                }
            }
            guard price != nil || weight != nil else { throw AgentFailure(.invalidArgument, "each target needs a price or a weight") }
            return (asset, price, weight)
        }
    }

    private func targetLines(_ targets: [(Asset, Decimal?, Double??)]) -> [String] {
        let f = Fmt.current
        return targets.map { a, p, w in
            "\(a.symbol)" + (p.map { " → " + f.price($0) } ?? "") + (w.map { " · weight " + ($0.map { f.num($0, 1) + "%" } ?? "cleared") } ?? "")
        }
    }

    private static func apply(_ targets: [(Asset, Decimal?, Double??)], to sc: inout PortfolioScenario, prices: [AssetID: Decimal]) throws {
        for (a, p, w) in targets {
            if let p { sc.targets[a.id, default: ScenarioTarget(price: p)].price = p }
            if let w {
                guard sc.targets[a.id] != nil || prices[a.id] != nil else { throw AgentFailure(.invalidArgument, "\(a.symbol): set a target price first (no current price)") }
                sc.targets[a.id, default: ScenarioTarget(price: prices[a.id]!)].weight = w
            }
        }
    }

    func agentCreateScenario(_ a: AgentArgs) throws -> AgentOperation {
        let name = (try a.string("name", required: true, max: 40)!).uppercased()
        guard !intel.scenarios.contains(where: { $0.name == name }) else { throw AgentFailure(.invalidArgument, "a scenario named \(name) exists") }
        let targets = try agentTargets(a)
        var sc = PortfolioScenario(name: name, editedAt: Date())
        try Self.apply(targets, to: &sc, prices: valuationQuotes.mapValues(\.price))
        let frozen = sc
        return intelOp("create scenario · \(name)", ["create scenario \(name)"] + targetLines(targets)) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard !self.intel.scenarios.contains(where: { $0.name == name }) else { throw AgentFailure(.conflict, "a scenario named \(name) exists") }
            try self.agentUpdateIntel { $0.scenarios.append(frozen) }
            return .obj([("status", "created"), ("scenario_id", .str(frozen.id.uuidString)), ("name", .str(name))])
        }
    }

    func agentUpdateScenario(_ a: AgentArgs) throws -> AgentOperation {
        let sc = try agentScenario(a)
        let rename = try a.string("name", max: 40).map { $0.uppercased() }
        let targets = try agentTargets(a)
        guard rename != nil || !targets.isEmpty else { throw AgentFailure(.invalidArgument, "nothing to change") }
        if let rename, rename.isEmpty || intel.scenarios.contains(where: { $0.name == rename && $0.id != sc.id }) { throw AgentFailure(.invalidArgument, "name is empty or already used") }
        var next = sc
        if let rename { next.name = rename }
        try Self.apply(targets, to: &next, prices: valuationQuotes.mapValues(\.price))
        next.editedAt = Date()
        let frozen = next
        return intelOp("update scenario · \(sc.name)", ["update scenario \(sc.name)" + (rename.map { " → \($0)" } ?? "")] + targetLines(targets)) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.scenarios.first(where: { $0.id == sc.id }) == sc else { throw AgentFailure(.conflict, "the scenario changed since the request") }
            try self.agentUpdateIntel { d in if let i = d.scenarios.firstIndex(where: { $0.id == sc.id }) { d.scenarios[i] = frozen } }
            return .obj([("status", "updated"), ("scenario_id", .str(sc.id.uuidString)), ("name", .str(frozen.name))])
        }
    }

    func agentDuplicateScenario(_ a: AgentArgs) throws -> AgentOperation {
        let sc = try agentScenario(a)
        return intelOp("duplicate scenario · \(sc.name)", ["duplicate scenario \(sc.name) with \(sc.targets.count) targets"]) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            var copy: PortfolioScenario?
            try self.agentUpdateIntel { copy = Scenarios.duplicate(sc.id, in: &$0, now: Date()) }
            guard let copy else { throw AgentFailure(.conflict, "the scenario is gone") }
            return .obj([("status", "duplicated"), ("scenario_id", .str(copy.id.uuidString)), ("name", .str(copy.name))])
        }
    }

    func agentDeleteScenario(_ a: AgentArgs) throws -> AgentOperation {
        let sc = try agentScenario(a)
        return intelOp("delete scenario · \(sc.name)", ["delete scenario \(sc.name)", "\(sc.targets.count) target\(sc.targets.count == 1 ? "" : "s") are deleted"]) { [weak self] in
            guard let self else { throw AgentFailure(.internalError) }
            guard self.intel.scenarios.contains(where: { $0.id == sc.id }) else { throw AgentFailure(.conflict, "the scenario is gone") }
            try self.agentUpdateIntel { Scenarios.delete(sc.id, in: &$0) }
            if self.scenarioID == sc.id { self.scenarioID = nil }
            return .obj([("status", "deleted"), ("name", .str(sc.name))])
        }
    }
}
