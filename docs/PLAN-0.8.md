# PF Terminal 0.8.0: Agent Access (plan)

**Status:** released as v0.8.0.

**Positioning:** your portfolio, your data, your agent. PF exposes a local MCP interface that an
MCP client (Claude Desktop, Cursor, ChatGPT desktop connectors, local agents) can use. PF does not
embed a model, has no backend, and adds no account.

## 1. Audit of 0.7 (what 0.8 builds on)

| Area | 0.7 implementation | Used by 0.8 as |
|---|---|---|
| State | `AppStore` (`@MainActor @Observable`), one instance per app | the only data source for agents: in-memory `doc`, `summary`, `intel`, `quotes`; no file reads per request |
| Ledger | `PortfolioDocument` → `PortfolioStore` (`portfolio.json`, complete protection), `save()` defers while protected data is unavailable | writes go through `AppStore.applyTransaction` / `deleteTransactionCore` (extracted from the sheet's commit, no logic copied) |
| Validation | `TransactionPlanner.preview` (parse, resolve, oversold, future dates, per-portfolio ledger validation) | every agent transaction write and dry run is a `TxDraft` through `preview` |
| Assets | `AssetCatalog` / `AssetRegistry`, canonical `AssetID` (`cg:…`, `dex:chain:contract`) | agents pass canonical ids or a ticker that resolves to exactly one asset; collisions → `asset_ambiguous` with candidates |
| Intel | `IntelDocument` (`intel.json` strict, `alerts.json` until-first-unlock), `updateIntel` refuses read-only / deferred data | all watch / alert / scenario writes go through `updateIntel` and the PFCore helpers (`Watchlist`, `AlertCommand`, `Scenarios`) |
| Analytics | `Attribution`, `Benchmark`, `PortfolioHistoryEngine`, cached per minute + data version | read tools call the same cached functions |
| Recovery | `SnapshotStore` safety snapshots before replacing operations | agent ledger deletes / edits take a `before-agent` safety snapshot first |
| Lock | `locked` (app lock), `protectedDataWaiting` (locked Mac) | all portfolio access pauses while either is set |
| Settings | `AppSettings` in PFCore, shared with pf-ios | agent settings are **app-only** (`pf.agent.v1` in UserDefaults): no PFCore settings change |
| Sandbox | app sandboxed; App Group only when provisioned | transport must work sandboxed, provisioned or not, with no network port |

## 2. Threat model

Assets to protect: the ledger (integrity), portfolio values / holdings / notes (confidentiality),
the user's control over what is exposed and what changes.

| # | Threat | Mitigation |
|---|---|---|
| T1 | Any local process reads or changes the portfolio through PF | Off by default: no socket exists. When on, the socket lives inside PF's sandbox container (macOS container protection), the peer's code signature must satisfy PF's own designated requirement (only PF's binary in relay mode can talk to it), and the relay must present the per-install credential from the client config. |
| T2 | Network exposure | No TCP/UDP listener at all. Unix domain socket only. |
| T3 | Agent (or a prompt injection inside the agent's context) issues harmful writes | Read-only by default; writes need read + write; ledger writes and destructive actions always need in-app confirmation of the exact operation; no delete-portfolio / import / restore / bulk tools exist. |
| T4 | Confirmation bypass (replay, parameter change, stale approval) | Confirmation ids are random 128-bit, single use, bound to a frozen operation; 2-minute expiry; executing re-validates against the current ledger; deny / expiry change nothing. |
| T5 | Over-exposure (values, notes) via derived fields | Redaction happens in PF when building responses: one exposure policy, money and quantity fields go through it; tests scan responses for the hidden numbers. |
| T6 | Exposure while locked | App lock or locked Mac → every portfolio tool returns `app_locked` / `protected_data_unavailable`; only `pf_status` answers. Confirmations wait and show no details until unlock. |
| T7 | Malformed / hostile input (huge lines, NaN, paths, commands) | 1 MB line cap; strict JSON-RPC parsing; typed argument validation, unknown fields rejected; no tool takes a path, a command, SQL or a URL. |
| T8 | Secret leakage | Responses never include API keys, Keychain items, CloudKit ids, file paths, environment, stack traces. Errors are codes + short messages. |
| T9 | Audit log leaks data | The log holds tool names, tiers, outcomes, short ids and error codes: no notes, no amounts, no credential. Bounded (500), local, clearable. |
| T10 | Credential theft | Credential in the Keychain (this device only) and in the client's config; regenerate invalidates every configured client at once. A stolen credential is useless without PF's own binary as the peer and the user's container. |
| T11 | Client impersonation (`clientInfo.name`) | Informational only; permissions never depend on it. |
| T12 | Denial of service / UI spam | One pending confirmation per operation id, at most 5 pending; extra requests get `rate_limited`. |

What PF cannot control: once the user exposes data to a cloud-hosted agent, that agent's provider
processes it. PF says so in Settings and docs.

## 3. Transport

**Chosen: stdio relay + local Unix domain socket.**

```
MCP client ──stdio──▶ "PF Terminal --mcp" (relay, PF's own binary) ──unix socket──▶ PF Terminal (running app)
```

- The client starts PF's own executable with `--mcp`. That process is a byte relay: it never
  opens PF data. It connects to `pf-mcp.sock` in PF's sandbox container, sends a handshake with the
  credential from `PF_MCP_TOKEN`, then copies stdin ↔ socket line by line.
- The running app owns the socket only while Agent Access is on. Off / kill switch → the socket
  file is removed and every connection closed, so every relay exits immediately.
- The app checks the connecting process with `LOCAL_PEERTOKEN` + `SecCodeCheckValidity` against
  its own designated requirement, then the credential.
- Why not a separate `pf-mcp` helper: a second executable needs its own signing / sandbox
  profile and could not reach the sandbox container without extra entitlements. PF's own binary
  in relay mode runs in the same sandbox, works for provisioned and unprovisioned builds, and is
  covered by the same notarization.
- Why not localhost HTTP: it is a listening port (visible to every local process, firewall
  prompts, needs its own auth). Not implemented in 0.8.
- PF must be running (menu bar is enough). If it isn't, or access is off, the relay answers each
  request with `pf_unavailable` and exits on EOF.

Client configuration (Settings → agents → copy configuration):

```json
{ "mcpServers": { "pf-terminal": {
  "command": "/Applications/PF Terminal.app/Contents/MacOS/PF Terminal",
  "args": ["--mcp"],
  "env": { "PF_MCP_TOKEN": "<credential>" } } } }
```

## 4. Permission model

Settings (`pf.agent.v1`, app-only, defaults in brackets):

| Setting | Values |
|---|---|
| agent access | off / on [off] |
| access mode | read only / read + write [read only] |
| confirm writes | on / off [on] (watchlist, alert and scenario writes) |
| confirm ledger + destructive | always (not a setting) |
| expose exact values | [off] — values, quantities, cost, P&L $, flows $, entries |
| expose notes | [off] |
| expose transactions | [off] |
| expose watchlist | [on] |
| expose alerts | [on] |
| expose scenarios | [on] |
| keep audit log on disk | [on] (off: this session only) |

Tool tiers: `status` (always when on), `read`, `write` (intel, non-destructive), `ledger`
(changes the ledger: always confirmed), `destructive` (removes data: always confirmed).

## 5. Tools (MCP API version 1)

Names use `_` (`pf_get_positions`): several MCP clients reject `.` in tool names.

Read: `pf_status`, `pf_list_portfolios`, `pf_get_portfolio_context`, `pf_get_portfolio_summary`,
`pf_get_positions`, `pf_get_asset`, `pf_resolve_asset`, `pf_get_transactions`,
`pf_get_what_changed`, `pf_get_analytics`, `pf_get_benchmark`, `pf_get_watchlist`, `pf_get_alerts`,
`pf_get_scenarios`, `pf_get_health`, `pf_get_confirmation`.

Write (read + write only):

| Tool | Tier | Dry run |
|---|---|---|
| `pf_add_transaction` | ledger | yes |
| `pf_update_transaction` | destructive (replaces history) | yes |
| `pf_delete_transaction` | destructive | yes |
| `pf_convert_watch_to_position` | ledger | yes |
| `pf_add_watch`, `pf_update_watch` | write | — |
| `pf_remove_watch` | destructive | — |
| `pf_create_alert`, `pf_update_alert`, `pf_pause_alert`, `pf_rearm_alert` | write | create / update: yes (30-day backtest) |
| `pf_delete_alert` | destructive | — |
| `pf_create_scenario`, `pf_update_scenario`, `pf_duplicate_scenario` | write | — |
| `pf_delete_scenario` | destructive | — |

Not exposed: delete / archive portfolio, import, restore, export, settings, sync, lock, API key,
remove position (bulk), any file, URL, shell or SQL access.

Resources: `pf://status`, `pf://portfolios`, `pf://portfolio/{name}`,
`pf://portfolio/{name}/positions`, `pf://portfolio/{name}/changes/{today|7d|30d}`,
`pf://portfolio/{name}/analytics`, `pf://asset/{symbol-or-id}`, `pf://watchlist`, `pf://alerts`,
`pf://scenarios`, `pf://health`. Each resolves to the same handler as its tool, so the same
permission and redaction apply.

Prompts: `portfolio_review`, `weekly_portfolio_review`, `what_changed`, `risk_review`,
`scenario_review`, `benchmark_review`: short templates that tell the agent which tools to call.

## 6. Confirmation

1. A ledger / destructive call (or any write while "confirm writes" is on) returns
   `{status: "confirmation_required", confirmation_id, summary, expires_at}`. Nothing changed yet.
2. PF shows an overlay: `AGENT REQUEST · <client>` with the frozen summary and `[ deny ] [ confirm ]`.
   While locked, it shows only "an agent request is waiting · unlock to review".
3. Confirm runs the frozen operation once (re-validated; a changed ledger fails with `conflict`).
   Deny, expiry (2 min) or the kill switch drop it.
4. The agent reads the outcome with `pf_get_confirmation(confirmation_id)`: `pending`,
   `confirmed` (+ result), `denied`, `expired`, `failed`.

## 7. Lock behaviour

- App lock on and locked, or the Mac locked (protected data unavailable): every portfolio tool and
  resource returns `app_locked` / `protected_data_unavailable`; writes are refused; pending
  confirmations stay pending without details. `pf_status` answers (version, `locked: true`).
- Unlock restores access without reconnecting.

## 8. Persistence

- No change to `portfolio.json`, `intel.json`, `alerts.json`, the sync records or the widget data.
- New: `agent-audit.json` next to the ledger (bounded 500 entries, no amounts or notes), the
  credential in the Keychain, `pf.agent.v1` in UserDefaults, the socket while on.
- PFCore: one additive enum case, `SnapshotStore.Reason.beforeAgent = "before-agent"` (stored as a
  string; older readers keep working). pf-ios does not use `Reason` and pins PFCore by revision.

## 9. pf-ios / PFCore impact

Everything else is in the macOS app target. No PFCore model, settings, sync or widget changes.

## 10. Phases

1. Plan + threat model (this file). 2. MCP core + read tools + resources + prompts.
3. Settings section, kill switch, palette commands, status indicator. 4. Write tools.
5. Confirmation overlay + dry run. 6. Audit + hardening. 7. Tests, docs, performance.
