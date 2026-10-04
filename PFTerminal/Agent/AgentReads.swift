import PFCore
import Foundation

// Read tools. Every figure comes from the app's own state and cached calculations (summary,
// Attribution, PortfolioHistoryEngine, Benchmark): no second analytics engine, no file reads.
// Money and quantities go through AgentExposure, so hidden values never leave PF.

extension AppStore {
    var agentExposure: AgentExposure { AgentExposure(s: agent.settings) }

    func agentRun(_ tool: AgentTool, _ a: AgentArgs) throws -> AgentOutcome {
        switch tool.name {
        case "pf_status": return .result(agentStatus, portfolio: nil)
        case "pf_list_portfolios": return .result(agentPortfolios, portfolio: nil)
        case "pf_get_portfolio_context": let c = try agentContext(a); return .result(agentPortfolioContext(c), portfolio: Self.auditID(c))
        case "pf_get_portfolio_summary": let c = try agentContext(a); return .result(agentSummary(c), portfolio: Self.auditID(c))
        case "pf_get_positions": let c = try agentContext(a); return .result(agentPositions(c, closed: try a.boolStrict("include_closed") ?? false), portfolio: Self.auditID(c))
        case "pf_get_asset": let c = try agentContext(a); return .result(try agentAssetDetail(try agentAsset(try a.string("asset", required: true)!), in: c), portfolio: Self.auditID(c))
        case "pf_resolve_asset": return .result(agentResolve(try a.string("query", required: true, max: 60)!), portfolio: nil)
        case "pf_get_transactions": let c = try agentContext(a); return .result(try agentTransactions(c, a), portfolio: Self.auditID(c))
        case "pf_get_what_changed":
            let c = try agentContext(a)
            let p = Attribution.Period(rawValue: try a.choice("period", ["today", "7d", "30d"], default: "today")!)!
            return .result(try agentWhatChanged(c, p), portfolio: Self.auditID(c))
        case "pf_get_analytics": let c = try agentContext(a); return .result(try agentAnalytics(c), portfolio: Self.auditID(c))
        case "pf_get_benchmark":
            let c = try agentContext(a)
            let r = Benchmark.Range(rawValue: try a.choice("range", Benchmark.Range.allCases.map(\.rawValue), default: "1Y")!)!
            return .result(try agentBenchmark(c, r), portfolio: Self.auditID(c))
        case "pf_get_watchlist": return .result(agentWatchlist, portfolio: nil)
        case "pf_get_alerts": return .result(agentAlerts, portfolio: nil)
        case "pf_get_scenarios": return .result(agentScenarios, portfolio: nil)
        case "pf_get_health": return .result(agentHealth, portfolio: nil)
        case "pf_get_confirmation": return .result(try agentConfirmationStatus(try a.string("confirmation_id", required: true, max: 40)!), portfolio: nil)
        default: return try agentWrite(tool, a)
        }
    }

    static func auditID(_ c: PortfolioContext) -> String { c.portfolioID.map(shortID) ?? "all" }

    // MARK: resolution

    /// "all", a portfolio name (any case), its id or an 8+ character id prefix. Default: active context.
    func agentContext(_ a: AgentArgs) throws -> PortfolioContext {
        guard let s = try a.string("portfolio", max: 80) else { return context }
        return try agentContext(named: s)
    }

    func agentContext(named s: String) throws -> PortfolioContext {
        let l = s.lowercased()
        if l == "all" { return .all }
        if let p = doc.livePortfolios.first(where: { $0.name.lowercased() == l || $0.id.uuidString.lowercased() == l }) { return .portfolio(p.id) }
        if l.count >= 8 {
            let hits = doc.livePortfolios.filter { $0.id.uuidString.lowercased().hasPrefix(l) }
            if hits.count == 1 { return .portfolio(hits[0].id) }
        }
        throw AgentFailure(.portfolioNotFound, "no active portfolio named \(s.prefix(40))")
    }

    /// The portfolio a write lands in: an explicit one, else the app's default (never ALL).
    func agentWritePortfolio(_ a: AgentArgs) throws -> PortfolioInfo {
        if let s = try a.string("portfolio", max: 80) {
            guard case let .portfolio(id) = try agentContext(named: s), let p = doc.portfolio(id) else {
                throw AgentFailure(.invalidArgument, "choose one portfolio, not ALL")
            }
            return p
        }
        guard let id = defaultTransactionPortfolio, let p = doc.portfolio(id) else { throw AgentFailure(.portfolioNotFound) }
        return p
    }

    /// Canonical id, or a ticker matching exactly one asset: the user's own assets (ledger,
    /// watchlist), then PF's curated catalog, then the registry. Collisions are never guessed.
    func agentAsset(_ q: String) throws -> Asset {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 120 else { throw AgentFailure(.invalidArgument, "asset is required") }
        let own = Self.unique(doc.assets + intel.watchlist.map(\.asset))
        if t.contains(":") {
            let l = t.lowercased()
            if let a = own.first(where: { $0.id.lowercased() == l }) ?? AssetCatalog.known.first(where: { $0.id.lowercased() == l }) { return a }
            if let e = AssetRegistry.shared.entry(forID: l) { return AssetRegistry.shared.asset(for: e) }
            if let a = agent.foundAssets.values.first(where: { $0.id.lowercased() == l }) { return a }
            throw AgentFailure(.assetNotFound, "no asset with id \(t.prefix(60))")
        }
        let u = t.uppercased()
        let mine = own.filter { $0.symbol.uppercased() == u }
        if mine.count == 1 { return mine[0] }
        if mine.count > 1 { throw ambiguous(t, mine) }
        let cat = AssetCatalog.known.filter { $0.symbol.uppercased() == u }
        if cat.count == 1 { return cat[0] }
        let reg = AssetRegistry.shared.entries(symbol: u).map { AssetRegistry.shared.asset(for: $0) }
        if reg.count == 1 { return reg[0] }
        if reg.count + cat.count > 1 { throw ambiguous(t, Self.unique(cat + reg)) }
        // Long tail: found online for this request (agentPrefetchQuote), exact ticker only.
        let found = agent.foundAssets.values.filter { $0.symbol.uppercased() == u }.sorted { $0.id < $1.id }
        if found.count == 1 { return found[0] }
        if found.count > 1 { throw ambiguous(t, found) }
        throw AgentFailure(.assetNotFound, "no asset matches \(t.prefix(40)) · try pf_resolve_asset")
    }

    private func ambiguous(_ t: String, _ c: [Asset]) -> AgentFailure {
        AgentFailure(.assetAmbiguous, "\(c.count) assets match \(t.prefix(40)) · pass one of these ids",
                     data: .arr(c.prefix(10).map { .obj([("asset_id", .str($0.id)), ("symbol", .str($0.symbol)), ("name", .str($0.name))]) }))
    }

    static func unique(_ a: [Asset]) -> [Asset] {
        var seen = Set<AssetID>()
        return a.filter { seen.insert($0.id).inserted }
    }

    func agentResolve(_ q: String) -> JSON {
        let l = q.lowercased(), u = q.uppercased()
        let own = Self.unique(doc.assets + intel.watchlist.map(\.asset)).filter { $0.symbol.uppercased() == u || $0.name.lowercased().hasPrefix(l) || $0.id.lowercased() == l }
        let reg = AssetRegistry.shared.search(q, limit: 8)
        func row(_ a: Asset, _ source: String, rank: Int? = nil) -> JSON {
            .compact([("asset_id", .str(a.id)), ("symbol", .str(a.symbol)), ("name", .str(a.name)), ("source", .str(source)),
                      ("held", .bool(heldAnywhere.contains(a.id))), ("market_cap_rank", rank.map(JSON.int))])
        }
        var rows = own.map { row($0, "yours") }
        for e in reg {
            let a = AssetRegistry.shared.asset(for: e)
            if !own.contains(where: { $0.id == a.id }) { rows.append(row(a, "registry", rank: e.marketCapRank)) }
        }
        return .obj([("query", .str(q)), ("matches", .arr(Array(rows.prefix(12))))])
    }

    // MARK: status · portfolios

    var agentStatus: JSON {
        let s = agent.settings
        return .obj([
            ("app", "PF Terminal"), ("app_version", .str(installedVersion.display)), ("mcp_api_version", .int(MCP.apiVersion)),
            ("access_mode", .str(s.mode == .readWrite ? "read_write" : "read_only")),
            ("locked", .bool(locked || protectedDataWaiting)),
            ("confirmation", .obj([("ledger_and_deletions", "always"), ("other_writes", .bool(s.confirmWrites))])),
            ("exposed", .obj([("exact_values", .bool(s.exposeValues)), ("notes", .bool(s.exposeNotes)), ("transactions", .bool(s.exposeTransactions)),
                              ("watchlist", .bool(s.exposeWatchlist)), ("alerts", .bool(s.exposeAlerts)), ("scenarios", .bool(s.exposeScenarios))])),
            ("currency", .str(settings.currency)),
            ("capabilities", ["tools", "resources", "prompts", "dry_run", "confirmations"]),
        ])
    }

    var agentPortfolios: JSON {
        let ex = agentExposure
        let rows: [JSON] = doc.livePortfolios.map { p in
            let s = summary(for: .portfolio(p.id))
            return .compact([("id", .str(p.id.uuidString)), ("name", .str(p.name)), ("demo", .bool(p.isDemo)), ("positions", .int(s.positions.count)),
                             ("change_24h_pct", .pct(s.change24hPct)), ("value", ex.money(s.totalValue)), ("active", .bool(context == .portfolio(p.id)))])
        }
        return .obj([("portfolios", .arr(rows)), ("active", .str(context == .all ? "all" : doc.displayName(context))), ("aggregate", "all")])
    }

    // MARK: summary · positions

    private func header(_ c: PortfolioContext) -> [(String, JSON?)] {
        [("portfolio", .str(c == .all ? "ALL" : doc.displayName(c))), ("portfolio_id", c.portfolioID.map { .str($0.uuidString) } ?? .str("all")),
         ("currency", .str(settings.currency)), ("as_of", .date(Date())), ("prices", .str(freshness.label.lowercased()))]
    }

    private func redactionNote() -> (String, JSON?) {
        let r = agentExposure.redacted
        return ("redacted", r.isEmpty ? nil : .arr(r.map(JSON.str)))
    }

    func agentSummary(_ c: PortfolioContext) -> JSON {
        let s = summary(for: c), ex = agentExposure
        func ranked(_ r: Ranked?) -> JSON? { r.map { .obj([("symbol", .str($0.symbol)), ("asset_id", .str($0.assetID)), ("pct", .pct($0.value))]) } }
        return .compact(header(c) + [
            ("positions", .int(s.positions.count)), ("transactions", .int(s.transactionCount)),
            ("value", ex.money(s.totalValue)), ("cost_basis", ex.money(s.costBasis)), ("net_contributed", ex.money(s.netContributed)),
            ("unrealized_pnl", ex.money(s.unrealized)), ("realized_pnl", ex.money(s.realized)), ("total_pnl", ex.money(s.totalPnL)),
            ("unrealized_return_pct", .pct(s.returnPct)), ("total_return_pct", .pct(s.totalReturnPct)),
            ("change_24h", ex.money(s.change24h)), ("change_24h_pct", .pct(s.change24hPct)),
            ("best", ranked(s.best)), ("worst", ranked(s.worst)), ("best_24h", ranked(s.best24)), ("worst_24h", ranked(s.worst24)),
            ("unpriced", s.unpriced.isEmpty ? nil : .arr(s.unpriced.map { .str(asset($0)?.symbol ?? $0) })),
            ("first_transaction", s.firstDate.map { .str(DateFmt.ymd($0)) }),
            redactionNote(),
        ])
    }

    func agentPositionJSON(_ v: PositionValuation) -> JSON {
        let ex = agentExposure
        return .compact([
            ("asset_id", .str(v.asset.id)), ("symbol", .str(v.asset.symbol)), ("name", .str(v.asset.name)),
            ("price", .opt(v.price)), ("price_source", v.quote.map { .str($0.source) }), ("change_24h_pct", .pct(v.change24h)),
            ("weight_pct", .pct(v.allocation)), ("unrealized_return_pct", .pct(v.returnPct)), ("total_return_pct", .pct(v.totalReturnPct)),
            ("quantity", ex.qty(v.position.quantity)), ("value", ex.money(v.value)), ("cost_basis", ex.money(v.position.costBasis)),
            ("average_entry", ex.money(v.position.averageEntry)), ("unrealized_pnl", ex.money(v.unrealized)),
            ("realized_pnl", ex.money(v.position.realizedPnL)), ("impact_24h", ex.money(v.contribution24h)),
            ("target_weight_pct", agent.settings.exposeScenarios ? .pct(targetWeight(v.asset.id)) : nil),
        ])
    }

    func agentPositions(_ c: PortfolioContext, closed: Bool) -> JSON {
        let s = summary(for: c), ex = agentExposure
        var out = header(c) + [("positions", .arr(s.positions.map(agentPositionJSON)))]
        if closed {
            out.append(("closed", .arr(s.closed.map { p in
                .compact([("asset_id", .str(p.assetID)), ("symbol", .str(asset(p.assetID)?.symbol ?? p.assetID)), ("realized_pnl", ex.money(p.realizedPnL))])
            })))
        }
        out.append(redactionNote())
        return .compact(out)
    }

    // MARK: context

    func agentPortfolioContext(_ c: PortfolioContext) -> JSON {
        let s = summary(for: c), ex = agentExposure
        let hist = portfolioHistory(.all, points: 121, in: c)
        if hist.twr.count < 2 { loadHistory(assetsHeld(during: .all, in: c), .all) }
        let dd = hist.twr.count > 1 ? PortfolioHistoryEngine.drawdown(hist.twr) : nil
        var today: JSON = .obj([("complete", false)])
        if let r = attribution(.today, in: c) {
            if r.complete {
                let top = r.byImpact.prefix(3).map { a in
                    JSON.compact([("symbol", .str(asset(a.id)?.symbol ?? a.id)), ("asset_id", .str(a.id)), ("impact", ex.money(a.contribution)),
                                  ("impact_pp", .pct(r.startValue > 0 ? (a.contribution / r.startValue).double * 100 : nil)), ("price_change_pct", .pct(a.priceChange))])
                }
                today = .compact([("complete", true), ("market_move", ex.money(r.marketMove)), ("market_move_pct", .pct(r.performancePct)),
                                  ("flows", ex.money(r.flows)), ("buys", .int(r.buys)), ("sells", .int(r.sells)), ("top_contributors", .arr(top))])
            } else {
                loadHistory(assetsHeld(during: .d1, in: c), .d1)
                today = .obj([("complete", false), ("missing_start_price", .arr(r.missing.map { .str(asset($0)?.symbol ?? $0) }))])
            }
        }
        let largest = s.positions.max { ($0.allocation ?? 0) < ($1.allocation ?? 0) }
        var out = header(c) + [
            ("value", ex.money(s.totalValue)), ("positions", .int(s.positions.count)),
            ("total_return_pct", .pct(s.totalReturnPct)), ("total_pnl", ex.money(s.totalPnL)),
            ("twr_all_pct", .pct(hist.twrPercent)), ("change_24h_pct", .pct(s.change24hPct)),
            ("today", today),
            ("allocation", .compact([("largest_position", largest.map { .str($0.asset.symbol) }), ("largest_weight_pct", .pct(largest?.allocation)),
                                     ("top", .arr(s.positions.prefix(5).map { .obj([("symbol", .str($0.asset.symbol)), ("weight_pct", .pct($0.allocation))]) }))])),
            ("risk", .compact([("current_drawdown_pct", dd.map { .pct($0.current * 100) }), ("max_drawdown_pct", dd.map { .pct($0.max * 100) }),
                               ("history", .str(dd == nil ? (historyPending ? "loading" : "unavailable") : "ok"))])),
        ]
        if agent.settings.exposeAlerts {
            out.append(("alerts", .obj([("active", .int(intel.alerts.filter { !$0.paused && $0.state == .armed }.count)),
                                        ("fired", .int(intel.alerts.filter { $0.state == .fired }.count)), ("unseen", .int(unseenAlerts))])))
        }
        out.append(redactionNote())
        return .compact(out)
    }

    // MARK: asset

    func agentAssetDetail(_ a: Asset, in c: PortfolioContext) throws -> JSON {
        let s = summary(for: c), ex = agentExposure
        let q = quotes[a.id] ?? agentQuote(a.id)
        var out: [(String, JSON?)] = header(c) + [
            ("asset_id", .str(a.id)), ("symbol", .str(a.symbol)), ("name", .str(a.name)), ("chain", a.chain.map(JSON.str)),
            ("market", q.map { q in .compact([("price", .dec(q.price)), ("source", .str(q.source)), ("updated", .date(q.timestamp)),
                                               ("change_24h_pct", .pct(q.change[.h24])), ("change_7d_pct", .pct(q.change[.d7])), ("change_30d_pct", .pct(q.change[.d30])),
                                               ("market_cap", .opt(q.marketCap)), ("volume_24h", .opt(q.volume24h)), ("ath", .opt(q.ath))]) } ?? .null),
        ]
        if let v = s.valuation(a.id) {
            out.append(("position", agentPositionJSON(v)))
            out.append(("impact", .arr(Attribution.Period.allCases.map { p -> JSON in
                guard let r = attribution(p, in: c), r.complete, let x = r.assets.first(where: { $0.id == a.id }) else { return .obj([("period", .str(p.rawValue)), ("complete", false)]) }
                return .compact([("period", .str(p.rawValue)), ("impact", ex.money(x.contribution)),
                                 ("impact_pp", .pct(r.startValue > 0 ? (x.contribution / r.startValue).double * 100 : nil)),
                                 ("price_change_pct", .pct(x.priceChange)), ("rank", .str("\((r.byImpact.firstIndex { $0.id == a.id } ?? 0) + 1)/\(r.assets.count)"))])
            })))
        } else {
            out.append(("position", .null))
        }
        if agent.settings.exposeWatchlist, let w = watchContext(a.id) {
            out.append(("watch", .compact([("active", .bool(w.isActive)), ("added", .str(DateFmt.ymd(w.addedAt))), ("price_at_add", .opt(w.priceAtAdd)),
                                           ("entry", .opt(w.entry)), ("target", .opt(w.target)), ("note", agentExposure.note(w.note))])))
        }
        if agent.settings.exposeScenarios {
            let t = intel.scenarios.compactMap { sc in sc.targets[a.id].map { JSON.compact([("scenario", .str(sc.name)), ("target_price", .dec($0.price)), ("target_weight_pct", .opt($0.weight))]) } }
            out.append(("scenario_targets", .arr(t)))
        }
        if agent.settings.exposeAlerts {
            let inputs = alertInputs()
            out.append(("alerts", .arr(intel.alerts.filter { $0.subject == .asset(a.id) }.map { agentAlertJSON($0, inputs: inputs) })))
        }
        out.append(redactionNote())
        return .compact(out)
    }

    // MARK: transactions

    func agentTransactionJSON(_ t: Transaction, asset known: Asset? = nil) -> JSON {
        let ex = agentExposure
        return .compact([
            ("id", .str(t.id.uuidString)), ("portfolio", .str(doc.portfolio(t.portfolioID)?.name ?? "?")), ("portfolio_id", .str(t.portfolioID.uuidString)),
            ("date", .str(DateFmt.ymd(t.timestamp))), ("type", .str(Self.agentTypeName(t.type))),
            ("asset_id", .str(t.assetID)), ("symbol", .str(known?.symbol ?? asset(t.assetID)?.symbol ?? t.assetID)),
            ("amount", ex.qty(t.quantity)), ("price", ex.money(t.price)), ("fee", ex.money(t.fee)),
            ("total", ex.money(t.quantity * t.price)), ("currency", .str(t.currency)), ("note", ex.note(t.note)),
        ])
    }

    static func agentTypeName(_ t: TransactionType) -> String {
        switch t { case .buy: "buy"; case .sell: "sell"; case .transferIn: "transfer_in"; case .transferOut: "transfer_out" }
    }

    func agentTransactions(_ c: PortfolioContext, _ a: AgentArgs) throws -> JSON {
        var txs = doc.transactions(c)
        if let q = try a.string("asset") { let id = try agentAsset(q).id; txs = txs.filter { $0.assetID == id } }
        if let s = try a.date("since"), let d = DateFmt.parseYMD(s) { txs = txs.filter { $0.timestamp >= d } }
        let limit = try a.int("limit", range: 1...500) ?? 50
        txs.sort { $0.timestamp > $1.timestamp }
        return .compact(header(c) + [("count", .int(txs.count)), ("transactions", .arr(txs.prefix(limit).map { agentTransactionJSON($0) })), redactionNote()])
    }

    // MARK: what changed · analytics · benchmark

    func agentWhatChanged(_ c: PortfolioContext, _ p: Attribution.Period) throws -> JSON {
        guard let r = attribution(p, in: c) else { return .compact(header(c) + [("period", .str(p.rawValue)), ("empty", true)]) }
        let ex = agentExposure
        guard r.complete else {
            loadHistory(assetsHeld(during: p.historyRange, in: c), p.historyRange)
            throw AgentFailure(.historyUnavailable, "no start price yet for " + r.missing.map { asset($0)?.symbol ?? $0 }.joined(separator: ", ") + " · try again shortly",
                               data: .arr(r.missing.map { .str($0) }))
        }
        let twr = portfolioChart(start: r.start, history: p.historyRange, in: c).twrPercent
        let assets: [JSON] = r.byImpact.map { x in
            .compact([("asset_id", .str(x.id)), ("symbol", .str(asset(x.id)?.symbol ?? x.id)), ("impact", ex.money(x.contribution)),
                      ("impact_pp", .pct(r.startValue > 0 ? (x.contribution / r.startValue).double * 100 : nil)), ("price_change_pct", .pct(x.priceChange)),
                      ("weight_start_pct", .pct(x.weightStart)), ("weight_end_pct", .pct(x.weightEnd)), ("weight_delta_pp", .pct(x.weightDelta)),
                      ("bought", .bool(x.bought)), ("sold", .bool(x.sold)), ("flow", ex.money(x.flow)), ("realized", ex.money(x.realized))])
        }
        let summaryLine = agent.settings.exposeValues
            ? Attribution.summary(r, twr: twr, period: p, symbol: { self.asset($0)?.symbol ?? $0 }, fmt: .current) : nil
        return .compact(header(c) + [
            ("period", .str(p.rawValue)), ("start", .date(r.start)), ("end", .date(r.end)),
            ("start_value", ex.money(r.startValue)), ("end_value", ex.money(r.endValue)), ("change", ex.money(r.change)),
            ("market_move", ex.money(r.marketMove)), ("market_move_pct", .pct(r.performancePct)), ("twr_pct", .pct(twr)),
            ("money_in", ex.money(r.moneyIn)), ("money_out", ex.money(r.moneyOut)), ("flows", ex.money(r.flows)),
            ("buys", .int(r.buys)), ("sells", .int(r.sells)), ("realized_pnl", ex.money(r.realized)),
            ("note", "flows are money in / out and are excluded from performance; market move is the price effect on holdings"),
            ("summary", summaryLine.map(JSON.str)), ("assets", .arr(assets)), redactionNote(),
        ])
    }

    func agentAnalytics(_ c: PortfolioContext) throws -> JSON {
        let s = summary(for: c), ex = agentExposure
        let hist = portfolioHistory(.all, points: 121, in: c)
        if hist.twr.count < 2 { loadHistory(assetsHeld(during: .all, in: c), .all) }
        let dd = hist.twr.count > 1 ? PortfolioHistoryEngine.drawdown(hist.twr) : nil
        let ddDate = dd.flatMap { d in hist.points[safe: d.maxIndex].map(\.time) }
        return .compact(header(c) + [
            ("value", ex.money(s.totalValue)), ("net_contributed", ex.money(s.netContributed)), ("invested", ex.money(s.invested)),
            ("open_cost_basis", ex.money(s.costBasis)), ("unrealized_pnl", ex.money(s.unrealized)), ("realized_pnl", ex.money(s.realized)),
            ("total_pnl", ex.money(s.totalPnL)), ("unrealized_return_pct", .pct(s.returnPct)), ("total_return_pct", .pct(s.totalReturnPct)),
            ("twr_all_pct", .pct(hist.twrPercent)),
            ("max_drawdown_pct", dd.map { .pct($0.max * 100) }), ("max_drawdown_date", ddDate.map { .str(DateFmt.ymd($0)) }),
            ("current_drawdown_pct", dd.map { .pct($0.current * 100) }),
            ("history", .str(dd == nil ? (historyPending ? "loading" : "unavailable") : "ok")),
            ("allocation", .arr(s.positions.map { .obj([("symbol", .str($0.asset.symbol)), ("asset_id", .str($0.asset.id)), ("weight_pct", .pct($0.allocation))]) })),
            ("positions", .arr(s.positions.map(agentPositionJSON))), redactionNote(),
        ])
    }

    func agentBenchmark(_ c: PortfolioContext, _ r: Benchmark.Range) throws -> JSON {
        let res = benchmark(r, in: c)
        if res.portfolio.returnPct == nil || res.btc.returnPct == nil || res.eth.returnPct == nil {
            loadHistory(assetsHeld(during: r.history, in: c), r.history)
            for a in Self.benchmarkAssets { loadReferenceHistory(a, r.history) }
        }
        func side(_ x: Benchmark.Side) -> JSON { .compact([("return_pct", .pct(x.returnPct)), ("missing", x.missing.map(JSON.str))]) }
        return .compact(header(c) + [
            ("range", .str(r.rawValue)), ("start", .str(DateFmt.ymd(res.start))), ("method", "portfolio: time-weighted return (deposits excluded); BTC / ETH: buy-and-hold price return"),
            ("portfolio_twr", side(res.portfolio)), ("btc", side(res.btc)), ("eth", side(res.eth)),
            ("vs_btc_pp", .pct(res.vsBTC)), ("vs_eth_pp", .pct(res.vsETH)),
            ("history", .str(res.portfolio.returnPct == nil ? (historyPending ? "loading" : "unavailable") : "ok")),
        ])
    }

    // MARK: intel

    var agentWatchlist: JSON {
        .obj([("watchlist", .arr(watchRows.map { r in
            .compact([("watch_id", .str(r.item.id.uuidString)), ("asset_id", .str(r.item.assetID)), ("symbol", .str(r.item.asset.symbol)), ("name", .str(r.item.asset.name)),
                      ("price", .opt(r.price)), ("change_24h_pct", .pct(r.change24h)), ("added", .str(DateFmt.ymd(r.item.addedAt))),
                      ("price_at_add", .opt(r.item.priceAtAdd)), ("since_added_pct", .pct(r.sinceAdded)), ("entry", .opt(r.item.entry)),
                      ("to_entry_pct", .pct(r.toEntry)), ("at_entry", .bool(r.atEntry)), ("target", .opt(r.item.target)),
                      ("alert", .str(alertGlyph(r.item.assetID) == "⚑" ? "fired" : alertGlyph(r.item.assetID) == "●" ? "armed" : "none")),
                      ("held", .bool(heldAnywhere.contains(r.item.assetID))), ("note", agentExposure.note(r.item.note))])
        })), ("redacted", agent.settings.exposeNotes ? .null : ["notes"])])
    }

    func agentAlertJSON(_ r: AlertRule, inputs: AlertInputs? = nil) -> JSON {
        let ex = agentExposure
        let valueRule = r.kind == .valueAbove || r.kind == .valueBelow
        let inputs = inputs ?? alertInputs()
        let reading = AlertEngine.read(r, inputs)
        return .compact([
            ("alert", .int(r.number)), ("id", .str(r.id.uuidString)), ("kind", .str(r.kind.rawValue)), ("subject", .str(alertSubjectLabel(r.subject))),
            ("condition", valueRule && !agent.settings.exposeValues ? .str(r.kind.label + " (threshold hidden)") : .str(AlertEngine.condition(r, fmt: .current))),
            ("threshold", valueRule ? ex.money(r.threshold) : .num(r.threshold)),
            ("state", .str(r.paused ? "paused" : r.state.rawValue)), ("repeat", .str(r.repeatMode.rawValue)),
            ("fired_at", r.firedAt.map { .date($0) }), ("unseen", .bool(r.unseen)),
            ("distance", valueRule && !agent.settings.exposeValues ? nil : .pct(AlertEngine.distance(r, reading, inputs))),
            ("distance_unit", .str(Self.distanceUnit(r.kind))), ("note", ex.note(r.note)),
        ])
    }

    var agentAlerts: JSON {
        let inputs = alertInputs()
        return .obj([("rules", .arr(alertRows.map { agentAlertJSON($0.rule, inputs: inputs) })),
              ("log", .arr(intel.alertLog.suffix(20).reversed().map { e in
                  let r = intel.alerts.first { $0.id == e.rule }
                  let hide = (r?.kind == .valueAbove || r?.kind == .valueBelow) && !agent.settings.exposeValues
                  return .compact([("at", .date(e.at)), ("alert", .int(e.number)), ("message", hide ? nil : .str(e.message)), ("delivery", .str(e.delivery))])
              })),
              ("delivery", .obj([("banner", .bool(settings.alertBanner)), ("quiet_hours", .str(settings.quietHours))]))])
    }

    var agentScenarios: JSON {
        let ex = agentExposure
        return .obj([("note", "the user's own target prices, not forecasts"), ("scenarios", .arr(orderedScenarios.map { sc in
            let p = projection(sc)
            return .compact([
                ("scenario_id", .str(sc.id.uuidString)), ("name", .str(sc.name)), ("key", sc.key.map(JSON.str)), ("edited", .str(DateFmt.ymd(sc.editedAt))),
                ("value_now", ex.money(p.valueNow)), ("projected", ex.money(p.projected)), ("upside", ex.money(p.upside)),
                ("upside_pct", .pct(p.upsidePct)), ("multiple", .pct(p.multiple)),
                ("targets", .arr(sc.targets.sorted { $0.key < $1.key }.map { id, t in
                    let row = p.rows.first { $0.asset == id }
                    return .compact([("asset_id", .str(id)), ("symbol", .str(asset(id)?.symbol ?? watchContext(id)?.asset.symbol ?? id)),
                                     ("target_price", .dec(t.price)), ("target_weight_pct", .opt(t.weight)), ("delta_pct", .pct(row?.deltaPct)),
                                     ("projected", ex.money(row?.projected)), ("upside", ex.money(row?.upside))])
                })),
            ])
        }))])
    }

    var agentHealth: JSON {
        .obj([("status", .str(health.text)), ("level", .str(["ok", "degraded", "bad"][health.level.rawValue])),
              ("checks", .arr(healthRows.map { .obj([("check", .str($0.k)), ("ok", .bool($0.ok)), ("detail", .str($0.v))]) })),
              ("sync", .str(syncEnabled ? syncStatusLabel : "off · this Mac only"))])
    }

    func agentConfirmationStatus(_ id: String) throws -> JSON {
        agentExpireConfirmations()
        if let c = agent.pending.first(where: { $0.id == id }) {
            return .obj([("confirmation_id", .str(id)), ("status", "pending"), ("expires_at", .date(c.expiresAt))])
        }
        guard let c = agent.finished[id] else { throw AgentFailure(.confirmationNotFound) }
        var o: [(String, JSON)] = [("confirmation_id", .str(id)), ("status", .str(c.state.rawValue))]
        if let r = c.result { o.append(("result", r)) }
        if let e = c.error { o.append(("error", .obj([("code", .str(e.code.rawValue)), ("message", .str(e.message))]))) }
        return .obj(o)
    }
}

extension AppStore {
    /// Benchmark for any context (the screen's `benchmark(_:)` follows the active one).
    func benchmark(_ r: Benchmark.Range, in c: PortfolioContext) -> Benchmark.Result {
        if c == context { return benchmark(r) }
        let now = Date()
        let s = summary(for: c)
        let start = r.start(now: now, firstTransaction: s.firstDate)
        let pf = Benchmark.portfolioSide(portfolioChart(start: start, history: r.history, in: c), start: start, firstTransaction: s.firstDate)
        func side(_ id: AssetID, _ name: String) -> Benchmark.Side {
            Benchmark.priceSide(assetSeries(id, r.history) ?? assetSeries(id, .all), start: start, endPrice: quotes[id]?.price, now: now, name: name)
        }
        return Benchmark.Result(range: r, start: start, portfolio: pf, btc: side(Benchmark.btc, "BTC"), eth: side(Benchmark.eth, "ETH"))
    }
}
