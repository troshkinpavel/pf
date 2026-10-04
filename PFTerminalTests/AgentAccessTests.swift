import PFCore
import Foundation
import Testing
@testable import PFTerminal

/// 0.8 Agent Access: the MCP surface end to end through `agentHandle` (the same entry the socket
/// uses), with in-memory stores and prices set directly. No network, no Keychain.
@MainActor
struct AgentAccessTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!
    private let sol = AssetCatalog.known.first { $0.symbol == "SOL" }!

    private func store(_ configure: (inout AgentSettings) -> Void = { _ in }) -> AppStore {
        var o = AppStore.Options()
        o.directory = nil; o.inMemory = true; o.mockMarket = false; o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf-agent-\(UUID().uuidString)")!
        let s = AppStore(o)
        s.createEmpty()
        s.openTx(TxDraft(asset: "BTC", amount: "0.5", price: "60000", date: "2026-01-02", note: "secret thesis"))
        s.confirmTx()
        s.quotes[btc.id] = Quote(price: 90000, change: [.h24: 2], source: "test", timestamp: Date())
        s.quotes[sol.id] = Quote(price: 150, change: [.h24: 1], source: "test", timestamp: Date())
        s.recompute()
        s.agent.credentialOverride = "test-credential"
        s.agent.settings.enabled = true
        configure(&s.agent.settings)
        return s
    }

    private func rpc(_ s: AppStore, _ method: String, _ params: JSON = .obj([]), id: Int = 1) async -> JSON {
        let line = JSON.obj([("jsonrpc", "2.0"), ("id", .int(id)), ("method", .str(method)), ("params", params)]).text
        let out = await s.agentHandle(Data(line.utf8), connection: 1)
        return try! JSON.parse(out[0])
    }

    /// (structuredContent, isError)
    private func call(_ s: AppStore, _ tool: String, _ args: JSON = .obj([])) async -> (JSON, Bool) {
        let r = await rpc(s, "tools/call", .obj([("name", .str(tool)), ("arguments", args)]))
        return (r["result"]!["structuredContent"]!, r["result"]!["isError"]!.bool!)
    }

    private func code(_ j: JSON) -> String? { j["error"]?["code"]?.string }
    private func ledger(_ s: AppStore) -> Data { try! s.doc.encoded() }

    // MARK: permissions

    @Test func offMeansInaccessible() async {
        let s = store { $0.enabled = false }
        let out = await s.agentHandle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pf_status","arguments":{}}}"#.utf8), connection: 1)
        let j = try! JSON.parse(out[0])
        #expect(j["error"]?["message"]?.string == "agent access is off" && j["result"] == nil)
        #expect(s.agent.server == nil && !s.agent.listening, "nothing listens while off")
        #expect(AgentSettings().enabled == false && AgentSettings().mode == .readOnly && !AgentSettings().exposeValues && !AgentSettings().exposeNotes && !AgentSettings().exposeTransactions,
                "off and least-privilege by default")
    }

    @Test func readOnlyBlocksWritesAndHidesWriteTools() async {
        let s = store()
        let before = ledger(s)
        let (j, err) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150])
        #expect(err && code(j) == "read_only")
        #expect(ledger(s) == before)
        let tools = await rpc(s, "tools/list")["result"]!["tools"]!.array!.compactMap { $0["name"]?.string }
        #expect(tools.contains("pf_get_positions") && !tools.contains { $0.hasPrefix("pf_add") || $0.hasPrefix("pf_delete") })
    }

    @Test func readWriteRunsSafeWritesWithoutConfirmationWhenAllowed() async {
        let s = store { $0.mode = .readWrite; $0.confirmWrites = false }
        let (j, err) = await call(s, "pf_add_watch", ["asset": "cg:solana", "entry": 120, "target": 300])
        #expect(!err && j["status"]?.string == "watching")
        #expect(s.intel.watchlist.contains { $0.assetID == sol.id && $0.entry == 120 && $0.target == 300 })
        #expect(s.agent.pending.isEmpty)
    }

    @Test func ledgerAndDestructiveAlwaysConfirmEvenWithConfirmWritesOff() async {
        let s = store { $0.mode = .readWrite; $0.confirmWrites = false }
        let before = ledger(s)
        let (add, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150])
        #expect(add["status"]?.string == "confirmation_required")
        let t = s.doc.transactions[0]
        let (del, _) = await call(s, "pf_delete_transaction", ["transaction_id": .str(t.id.uuidString)])
        #expect(del["status"]?.string == "confirmation_required")
        #expect(ledger(s) == before, "nothing changes before the user confirms")
        let (bypass, err) = await call(s, "pf_delete_transaction", ["transaction_id": .str(t.id.uuidString), "confirmed": true])
        #expect(err && code(bypass) == "invalid_argument", "no argument skips the confirmation")
        #expect(AgentTier.destructive.needsConfirmation(AgentSettings()) && AgentTier.ledger.needsConfirmation({ var x = AgentSettings(); x.confirmWrites = false; return x }()))
    }

    @Test func exposureTogglesRedactInPF() async {
        let s = store()
        for tool in ["pf_get_portfolio_summary", "pf_get_positions", "pf_get_portfolio_context", "pf_get_analytics", "pf_get_asset"] {
            let (j, _) = await call(s, tool, tool == "pf_get_asset" ? ["asset": "btc"] : .obj([]))
            let text = j.text
            #expect(!text.contains("45000") && !text.contains("60000") && !text.contains("30000") && !text.contains("15000"), "\(tool) leaks a value: \(text.prefix(200))")
            #expect(!text.contains("\"quantity\""), "\(tool) leaks a quantity")
        }
        let (tx, err) = await call(s, "pf_get_transactions")
        #expect(err && code(tx) == "permission_denied")

        s.agentUpdate { $0.exposeValues = true; $0.exposeTransactions = true }
        let (sum, _) = await call(s, "pf_get_portfolio_summary")
        #expect(sum["value"]?.double == 45000 && sum["cost_basis"]?.double == 30000)
        let (txs, _) = await call(s, "pf_get_transactions")
        #expect(txs["transactions"]?.array?.count == 1 && !txs.text.contains("secret thesis"), "notes stay hidden with values on")
        s.agentUpdate { $0.exposeNotes = true }
        let (txn, _) = await call(s, "pf_get_transactions")
        #expect(txn.text.contains("secret thesis"))

        s.agentUpdate { $0.exposeWatchlist = false }
        let tools = await rpc(s, "tools/list")["result"]!["tools"]!.array!.compactMap { $0["name"]?.string }
        #expect(!tools.contains("pf_get_watchlist"))
        let (w, werr) = await call(s, "pf_get_watchlist")
        #expect(werr && code(w) == "permission_denied")
        let res = await rpc(s, "resources/list")["result"]!["resources"]!.array!.compactMap { $0["uri"]?.string }
        #expect(!res.contains("pf://watchlist"))
    }

    // MARK: transactions

    @Test func addThroughMCPMatchesTheSheet() async {
        let s = store { $0.mode = .readWrite }
        let (j, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": "2.5", "price": "140", "fee": "1", "date": "2026-03-01"])
        let id = j["confirmation_id"]!.string!
        #expect(s.agent.pending.count == 1 && s.doc.transactions.count == 1)
        s.agentResolve(id, confirm: true)
        #expect(s.doc.transactions.count == 2)
        let (st, _) = await call(s, "pf_get_confirmation", ["confirmation_id": .str(id)])
        #expect(st["status"]?.string == "confirmed" && st["result"]?["status"]?.string == "recorded")

        // The same buy through the transaction sheet gives the same position.
        let sheet = store()
        sheet.openTx(TxDraft(asset: "SOL", amount: "2.5", price: "140", date: "2026-03-01", fee: "1"))
        sheet.confirmTx()
        let a = PortfolioEngine.positions(s.doc.transactions)[sol.id], b = PortfolioEngine.positions(sheet.doc.transactions)[sol.id]
        #expect(a?.quantity == b?.quantity && a?.costBasis == b?.costBasis && a?.costBasis == 351)
    }

    @Test func untrackedCoinUsesAFetchedQuoteLikeTheSheet() async throws {
        let s = store { $0.mode = .readWrite; $0.exposeValues = true }
        let xrp = try #require(AssetRegistry.shared.entries(symbol: "XRP").first.map { AssetRegistry.shared.asset(for: $0) })
        let (none, err) = await call(s, "pf_add_transaction", ["type": "buy", "asset": .str(xrp.id), "amount": 500, "dry_run": true])
        #expect(err && code(none) == "validation_failed", "no quote anywhere: the agent must pass a price")
        s.agent.quoteCache[xrp.id] = Quote(price: 2.4, source: "test", timestamp: Date())   // what agentPrefetchQuote stores
        let (j, e2) = await call(s, "pf_add_transaction", ["type": "buy", "asset": .str(xrp.id), "amount": 500, "dry_run": true])
        #expect(!e2 && j["transaction"]?["price"]?.double == 2.4 && j["weight_after_pct"]?.double != nil)
        #expect(s.quotes[xrp.id] == nil, "a fetched quote doesn't make PF track the coin")
        let (a, _) = await call(s, "pf_get_asset", ["asset": .str(xrp.id)])
        #expect(a["market"]?["price"]?.double == 2.4)
    }

    @Test func longTailAssetsFoundOnlineResolveOnlyWhenUnique() async {
        let s = store { $0.mode = .readWrite }
        let one = Asset(id: "dex:base:0x111", symbol: "ZZTOP", name: "Zz Top", chain: "base", contractAddress: "0x111")
        s.agent.foundAssets[one.id] = one   // what the online search in agentPrefetchQuote stores
        #expect(await call(s, "pf_get_asset", ["asset": "zztop"]).0["asset_id"]?.string == one.id)
        s.agent.foundAssets["dex:solana:abc"] = Asset(id: "dex:solana:abc", symbol: "ZZTOP", name: "Zz Top (Solana)", chain: "solana", contractAddress: "abc")
        let (j, err) = await call(s, "pf_get_asset", ["asset": "zztop"])
        #expect(err && code(j) == "asset_ambiguous" && j["error"]?["details"]?.array?.count == 2)
        #expect(await call(s, "pf_get_asset", ["asset": "dex:solana:abc"]).0["name"]?.string == "Zz Top (Solana)", "the id picks one")
    }

    @Test func dryRunChangesNothing() async {
        let s = store { $0.mode = .readWrite; $0.exposeValues = true }
        let before = ledger(s), snaps = s.snapshotList.count, log = s.agent.audit.entries.count
        let (j, err) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 100, "price": 150, "dry_run": true])
        #expect(!err && j["dry_run"]?.bool == true && j["weight_after_pct"]?.double != nil)
        #expect(j["portfolio_value_after"]?.double == 60000, "real engine: 45000 BTC + 15000 SOL")
        let (j2, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 100, "price": 150, "dry_run": true])
        #expect(j2["weight_after_pct"] == j["weight_after_pct"], "deterministic")
        let t = s.doc.transactions[0]
        _ = await call(s, "pf_delete_transaction", ["transaction_id": .str(t.id.uuidString), "dry_run": true])
        #expect(ledger(s) == before && s.snapshotList.count == snaps && s.agent.pending.isEmpty)
        #expect(s.agent.audit.entries.count == log, "a dry run is not logged as a write")
    }

    @Test func deleteNeedsConfirmationDenyKeepsStateAndSnapshotOnConfirm() async {
        let s = store { $0.mode = .readWrite }
        let t = s.doc.transactions[0]
        let before = ledger(s)
        let (j, _) = await call(s, "pf_delete_transaction", ["transaction_id": .str(t.id.uuidString)])
        let id = j["confirmation_id"]!.string!
        s.agentResolve(id, confirm: false)
        #expect(ledger(s) == before)
        #expect(await call(s, "pf_get_confirmation", ["confirmation_id": .str(id)]).0["status"]?.string == "denied")

        let (j2, _) = await call(s, "pf_delete_transaction", ["transaction_id": .str(t.id.uuidString)])
        s.agentResolve(j2["confirmation_id"]!.string!, confirm: true)
        #expect(s.doc.transactions.isEmpty)
        #expect(s.snapshotList.contains { $0.reason == "before-agent" }, "safety snapshot first")
    }

    @Test func updateKeepsIdAndChecksForConflicts() async {
        let s = store { $0.mode = .readWrite }
        let t = s.doc.transactions[0]
        let (j, _) = await call(s, "pf_update_transaction", ["transaction_id": .str(t.id.uuidString), "price": 55000])
        s.agentResolve(j["confirmation_id"]!.string!, confirm: true)
        #expect(s.doc.transactions.count == 1 && s.doc.transactions[0].id == t.id && s.doc.transactions[0].price == 55000)

        // Requested, then the user edits the same transaction: confirming must not apply a stale change.
        let (j2, _) = await call(s, "pf_update_transaction", ["transaction_id": .str(t.id.uuidString), "price": 50000])
        var edited = s.doc.transactions[0]; edited.quantity = 0.4
        s.commitTransaction(edited, asset: btc)
        let id2 = j2["confirmation_id"]!.string!
        s.agentResolve(id2, confirm: true)
        #expect(s.doc.transactions[0].price == 55000 && s.doc.transactions[0].quantity == 0.4)
        let st = await call(s, "pf_get_confirmation", ["confirmation_id": .str(id2)]).0
        #expect(st["status"]?.string == "failed" && st["error"]?["code"]?.string == "conflict")
    }

    @Test func confirmationsExpireAndNeverReplay() async {
        let s = store { $0.mode = .readWrite }
        let (j, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150])
        let id = j["confirmation_id"]!.string!
        s.agentExpireConfirmations(now: Date().addingTimeInterval(AgentRuntime.confirmationLifetime + 1))
        s.agentResolve(id, confirm: true)
        #expect(s.doc.transactions.count == 1, "an expired request never runs")
        #expect(await call(s, "pf_get_confirmation", ["confirmation_id": .str(id)]).0["status"]?.string == "expired")

        let (k, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150])
        let id2 = k["confirmation_id"]!.string!
        s.agentResolve(id2, confirm: true)
        s.agentResolve(id2, confirm: true)
        #expect(s.doc.transactions.count == 2, "confirmed once, ran once")
        let (u, err) = await call(s, "pf_get_confirmation", ["confirmation_id": "cf_nope"])
        #expect(err && code(u) == "confirmation_not_found")
    }

    @Test func pendingRequestsAreBounded() async {
        let s = store { $0.mode = .readWrite }
        for _ in 0..<AgentRuntime.maxPending { _ = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150]) }
        let (j, err) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150])
        #expect(err && code(j) == "rate_limited" && s.agent.pending.count == AgentRuntime.maxPending)
        s.disableAgentAccess()
        #expect(s.agent.pending.isEmpty, "the kill switch drops every pending request")
    }

    @Test func oversoldAndValidationComeFromTheEngine() async {
        let s = store { $0.mode = .readWrite }
        let (j, err) = await call(s, "pf_add_transaction", ["type": "sell", "asset": "btc", "amount": 2, "price": 90000])
        #expect(err && code(j) == "validation_failed")
        for bad: JSON in [["amount": "NaN"], ["amount": -1], ["amount": "1e5"], ["amount": "1,5"], ["date": "2026-02-30"], ["date": "2999-01-01"], ["type": "short"]] {
            var args: [(String, JSON)] = [("type", "buy"), ("asset", "sol"), ("amount", 1), ("price", 150)]
            for (k, v) in bad.object! { args.removeAll { $0.0 == k }; args.append((k, v)) }
            let (r, e) = await call(s, "pf_add_transaction", .obj(args))
            #expect(e && code(r) == "invalid_argument", "\(bad.text)")
        }
    }

    // MARK: assets

    @Test func tickerCollisionsAreRejectedNotGuessed() async {
        let s = store { $0.mode = .readWrite }
        let fake = Asset(id: "dex:base:0xabc", symbol: "BTC", name: "Fake Bitcoin", chain: "base", contractAddress: "0xabc")
        s.doc.assets.append(fake)
        let (j, err) = await call(s, "pf_get_asset", ["asset": "btc"])
        #expect(err && code(j) == "asset_ambiguous" && (j["error"]?["details"]?.array?.count ?? 0) == 2)
        let (ok, e2) = await call(s, "pf_get_asset", ["asset": "cg:bitcoin"])
        #expect(!e2 && ok["asset_id"]?.string == "cg:bitcoin", "canonical ids always resolve")
        let (nf, e3) = await call(s, "pf_get_asset", ["asset": "NOTACOINXYZ"])
        #expect(e3 && code(nf) == "asset_not_found")
    }

    // MARK: watchlist · alerts · scenarios

    @Test func watchlistAddUpdateConvertRemove() async {
        let s = store { $0.mode = .readWrite; $0.confirmWrites = false }
        _ = await call(s, "pf_add_watch", ["asset": "sol", "entry": 140, "target": 300, "note": "thesis"])
        let (u, _) = await call(s, "pf_update_watch", ["asset": "sol", "entry": .null])
        #expect(u["status"]?.string == "updated" && s.intel.watchlist.first { $0.assetID == sol.id }?.entry == nil)
        let (c, _) = await call(s, "pf_convert_watch_to_position", ["asset": "sol", "amount": 3, "price": 150])
        s.agentResolve(c["confirmation_id"]!.string!, confirm: true)
        #expect(s.doc.transactions.contains { $0.assetID == sol.id && $0.quantity == 3 })
        #expect(s.intel.watchlist.first { $0.assetID == sol.id }?.isActive == false, "archived, not deleted")
        #expect(Scenarios.base(s.intel)?.targets[sol.id]?.price == 300, "target carried into Base")
        #expect(s.convertUndo != nil, "⌘Z works as after an in-app conversion")

        _ = await call(s, "pf_add_watch", ["asset": "eth"])
        let (r, _) = await call(s, "pf_remove_watch", ["asset": "eth"])
        #expect(r["status"]?.string == "confirmation_required", "removal always asks")
    }

    @Test func alertsCreatePauseRearmDelete() async {
        let s = store { $0.mode = .readWrite; $0.confirmWrites = false }
        let (dry, _) = await call(s, "pf_create_alert", ["condition": "btc below 80000", "dry_run": true])
        #expect(dry["rule"]?["kind"]?.string == "priceBelow" && s.intel.alerts.isEmpty)
        let (c, _) = await call(s, "pf_create_alert", ["condition": "btc below 80000", "repeat": "daily"])
        #expect(c["status"]?.string == "armed")
        let n = s.intel.alerts[0].number
        _ = await call(s, "pf_pause_alert", ["alert": .int(n), "paused": true])
        #expect(s.intel.alerts[0].paused)
        s.updateIntel { $0.alerts[0].state = .fired }
        _ = await call(s, "pf_rearm_alert", ["alert": .int(n)])
        #expect(s.intel.alerts[0].state == .armed)
        let (d, _) = await call(s, "pf_delete_alert", ["alert": .int(n)])
        #expect(d["status"]?.string == "confirmation_required" && s.intel.alerts.count == 1)
        s.agentResolve(d["confirmation_id"]!.string!, confirm: true)
        #expect(s.intel.alerts.isEmpty)
        let (bad, err) = await call(s, "pf_create_alert", ["condition": "btc sideways"])
        #expect(err && code(bad) == "invalid_argument")
        s.agentUpdate { $0.exposeAlerts = false }
        let (hidden, herr) = await call(s, "pf_create_alert", ["condition": "btc below 1"])
        #expect(herr && code(hidden) == "permission_denied")
    }

    @Test func scenariosCreateEditDuplicateDelete() async {
        let s = store { $0.mode = .readWrite; $0.confirmWrites = false }
        _ = await call(s, "pf_create_scenario", ["name": "moon", "targets": [["asset": "btc", "price": 250000, "weight": 40]]])
        #expect(s.intel.scenarios.first { $0.name == "MOON" }?.targets[btc.id] == ScenarioTarget(price: 250000, weight: 40))
        _ = await call(s, "pf_update_scenario", ["scenario": "moon", "name": "lunar", "targets": [["asset": "btc", "weight": .null]]])
        #expect(s.intel.scenarios.first { $0.name == "LUNAR" }?.targets[btc.id]?.weight == nil)
        _ = await call(s, "pf_duplicate_scenario", ["scenario": "lunar"])
        #expect(s.intel.scenarios.count == 2)
        let (d, _) = await call(s, "pf_delete_scenario", ["scenario": "lunar"])
        #expect(d["status"]?.string == "confirmation_required" && s.intel.scenarios.count == 2)
        let (dup, err) = await call(s, "pf_create_scenario", ["name": "Lunar"])
        #expect(err && code(dup) == "invalid_argument")
    }

    // MARK: lock

    @Test func lockedAppRefusesEverythingButStatus() async {
        let s = store { $0.mode = .readWrite }
        let (req, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 1, "price": 150])
        s.locked = true
        let (p, err) = await call(s, "pf_get_positions")
        #expect(err && code(p) == "app_locked")
        let (st, serr) = await call(s, "pf_status")
        #expect(!serr && st["locked"]?.bool == true)
        let r = await rpc(s, "resources/read", ["uri": "pf://portfolio/all"])
        #expect(r["error"]?["data"]?["code"]?.string == "app_locked")
        s.agentResolve(req["confirmation_id"]!.string!, confirm: true)
        #expect(s.doc.transactions.count == 1 && s.agent.pending.count == 1, "no confirming while locked")
        s.locked = false
        #expect(await call(s, "pf_get_positions").1 == false, "unlock restores access")

        s.protectedDataWaiting = true
        let (pd, perr) = await call(s, "pf_get_portfolio_summary")
        #expect(perr && code(pd) == "protected_data_unavailable")
    }

    // MARK: resources · protocol

    @Test func resourcesRouteThroughTheSamePermissions() async {
        let s = store()
        let r = await rpc(s, "resources/read", ["uri": "pf://portfolio/main/positions"])
        let text = r["result"]!["contents"]!.array![0]["text"]!.string!
        #expect(text.contains("cg:bitcoin") && !text.contains("45000"))
        for bad in ["pf://portfolio/../secret", "file:///etc/passwd", "pf://portfolio/nope", "pf://x/y/z/w/v"] {
            let e = await rpc(s, "resources/read", ["uri": .str(bad)])
            #expect(e["error"] != nil, "\(bad)")
        }
        #expect(AgentResources.route("pf://portfolio/main/changes/7d")?.0 == "pf_get_what_changed")
        let tpls = await rpc(s, "resources/templates/list")["result"]!["resourceTemplates"]!.array!
        #expect(tpls.count == AgentResources.templates.count)
    }

    @Test func protocolErrorsAreStable() async {
        let s = store()
        let parse = try! JSON.parse((await s.agentHandle(Data("{nope".utf8), connection: 1))[0])
        #expect(parse["error"]?["code"]?.double == -32700)
        let batch = try! JSON.parse((await s.agentHandle(Data("[1,2]".utf8), connection: 1))[0])
        #expect(batch["error"]?["code"]?.double == -32600)
        #expect(await rpc(s, "no/such")["error"]?["code"]?.double == -32601)
        #expect(await rpc(s, "tools/call", ["name": "pf_shell_exec", "arguments": .obj([])])["error"]?["code"]?.double == -32602)
        #expect((await s.agentHandle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), connection: 1)).isEmpty, "notifications get no reply")
        let ini = await rpc(s, "initialize", ["protocolVersion": "1999-01-01", "clientInfo": ["name": "Claude Desktop", "version": "1"]])
        #expect(ini["result"]?["protocolVersion"]?.string == MCP.supportedVersions[0] && ini["result"]?["serverInfo"]?["pfMcpApiVersion"]?.double == 1)
        #expect(s.agent.sessions[1]?.client == "Claude Desktop")
        // Oversized lines are refused by the framing.
        var big = Data(repeating: 0x61, count: AgentTransport.maxLine + 2); big.append(0x0A)
        #expect(AgentTransport.takeLines(&big) == nil)
        #expect(throws: (any Error).self) { try JSON.parse(#"{"a":1,"a":2}"#) }
        #expect((try? JSON.parse(#"{"x":0.1}"#))?["x"] == .dec(Decimal(string: "0.1")!), "exact decimals")
    }

    @Test func everyToolHasAStrictSchemaAndValidName() {
        for t in AgentTools.all {
            #expect(t.name.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil, "\(t.name)")
            #expect(t.listing["inputSchema"]?["additionalProperties"] == .bool(false))
            for r in t.required { #expect(t.argNames.contains(r), "\(t.name).\(r)") }
        }
        #expect(Set(AgentTools.all.map(\.name)).count == AgentTools.all.count)
        #expect(!AgentTools.all.contains { ["delete_portfolio", "import", "restore", "export", "shell", "file", "sql"].contains(where: $0.name.contains) })
    }

    // MARK: audit

    @Test func auditLogsWritesAndOutcomesWithoutSecrets() async throws {
        let s = store { $0.mode = .readWrite; $0.exposeNotes = true }
        let (j, _) = await call(s, "pf_add_transaction", ["type": "buy", "asset": "sol", "amount": 7, "price": 123.45, "note": "private plan"])
        s.agentResolve(j["confirmation_id"]!.string!, confirm: false)
        let e = s.agent.audit.entries
        #expect(e.contains { $0.tool == "pf_add_transaction" && $0.result == "confirmation_requested" })
        #expect(e.contains { $0.tool == "pf_add_transaction" && $0.result == "denied" })
        let text = String(decoding: try JSONEncoder.iso.encode(e), as: UTF8.self)
        #expect(!text.contains("private plan") && !text.contains("123.45") && !text.contains("test-credential") && !text.contains("MAIN"))
        var log = AgentAuditLog(directory: nil)
        for i in 0..<(AgentAuditLog.limit + 20) { log.append(AgentAuditEntry(at: Date(), connection: i, client: "c", tool: "t", tier: "read", result: "ok"), persist: false) }
        #expect(log.entries.count == AgentAuditLog.limit)
    }

    // MARK: compatibility

    @Test func settingsAreTolerantAndAgentOffChangesNothing() throws {
        let d = UserDefaults(suiteName: "pf-agent-tol-\(UUID().uuidString)")!
        d.set(Data(#"{"enabled":true,"mode":"god mode","exposeValues":"yes"}"#.utf8), forKey: AgentSettings.key)
        let s = AgentSettings.load(d)
        #expect(s.enabled && s.mode == .readOnly && !s.exposeValues, "unknown values fall back to the safe defaults")
        let st = store { $0.enabled = false }
        let encoded = try st.doc.encoded()
        #expect(!String(decoding: encoded, as: UTF8.self).contains("agent"), "the ledger format is unchanged")
        #expect(st.settingsSections.contains { $0.id == "agents" && $0.status == "off" })
    }

    // MARK: socket

    @Test func socketHandshakeCredentialAndKillSwitch() async throws {
        let s = store()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pfa-\(UUID().uuidString.prefix(6))")
        let server = AgentServer(url: AgentTransport.socketURL(in: dir),
                                 authorize: { token, peer in let ok = AgentTransport.sameSecret(token, "test-credential"); if ok { s.agent.sessions[peer.id] = .init(id: peer.id) }; return ok },
                                 handle: { line, peer in await s.agentHandle(line, connection: peer.id) },
                                 closed: { peer in s.agent.sessions[peer.id] = nil })
        server.requirePeerSignature = false
        try server.start()
        defer { server.stop() }
        #expect(FileManager.default.fileExists(atPath: server.url.path))

        func connect() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var a = AgentTransport.address(server.url)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        func readLine(_ fd: Int32) async -> JSON? {
            await Task.detached {
                var buf = Data(), c = [UInt8](repeating: 0, count: 4096)
                while true {
                    if let l = AgentTransport.takeLines(&buf)?.first { return try? JSON.parse(l) }
                    let n = read(fd, &c, c.count)
                    if n <= 0 { return nil }
                    buf.append(contentsOf: c[0..<n])
                }
            }.value
        }

        let bad = connect()
        AgentTransport.writeAll(bad, Data(#"{"pf_relay":1,"token":"wrong"}"#.utf8 + [0x0A]))
        #expect(await readLine(bad)?["error"]?.string == "invalid_credential")
        close(bad)

        let fd = connect()
        AgentTransport.writeAll(fd, Data(#"{"pf_relay":1,"token":"test-credential"}"#.utf8 + [0x0A]))
        #expect(await readLine(fd)?["ok"]?.bool == true)
        AgentTransport.writeAll(fd, Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8 + [0x0A]))
        #expect(await readLine(fd)?["id"]?.double == 7)

        // Concurrent requests with replies larger than the socket buffer arrive whole and in order
        // (an accepted socket inherits O_NONBLOCK on macOS; regression from the first Claude Desktop run).
        s.agent.settings.mode = .readWrite
        let burst = (1...3).map { i in #"{"jsonrpc":"2.0","id":\#(i),"method":"\#(["tools/list", "prompts/list", "resources/list"][i - 1])"}"# }.joined(separator: "\n") + "\n"
        AgentTransport.writeAll(fd, Data(burst.utf8))
        let replies = await Task.detached { () -> [JSON] in
            var buf = Data(), out: [JSON] = [], c = [UInt8](repeating: 0, count: 65536)
            while out.count < 3 {
                let n = read(fd, &c, c.count)
                if n <= 0 { break }
                buf.append(contentsOf: c[0..<n])
                out += (AgentTransport.takeLines(&buf) ?? []).compactMap { try? JSON.parse($0) }
            }
            return out
        }.value
        #expect(replies.compactMap { $0["id"]?.double } == [1, 2, 3])
        #expect((replies.first?["result"]?["tools"]?.array?.count ?? 0) == s.agentVisibleTools.count && s.agentVisibleTools.count > 20)

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: server.url.path), "off removes the socket")
        #expect(await readLine(fd) == nil, "and closes the connection")
        close(fd)
    }
}
