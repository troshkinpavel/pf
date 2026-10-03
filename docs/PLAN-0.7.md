# PF Terminal 0.7.0: Portfolio Intelligence (implementation plan)

**Status:** in development on `release/0.7.0`. Nothing here is released yet.

**Specification:** `pf Terminal 0.7.dc.html` in the Claude Design project (sections 01–14). All states, notes, keys and copy in that file are requirements.

## Design section → implementation

| § | Design | Existing | New / changed |
|---|---|---|---|
| 01 | Four tabs (portfolio · changes · analytics · watch); settings leaves the tab bar; `g` leader; mode keys `m` `b`; `d` drill-down; ⌘K verbs | `Screen`, `handleKey`, palette | `Screen` cases, tab model, g-leader state (UI only, never persisted), palette groups ASSET / IN CONTEXT / ACTIONS |
| 02 | Overview: TODAY · WHAT MOVED band (market move, flows, top 3, `d`), TWR cell, ▲ over target weight | `OverviewView` | band from `Attribution`, TWR · ALL cell, ▲ flag from the Base scenario's target weight |
| 03 | What Changed: KPIs, summary, bridge, allocation drift, impact table, today / 7d / 30d | `PortfolioEngine.contributions` | `Attribution` engine (PFCore) + `ChangesView` |
| 04 | Asset Detail: MARKET as one line; POSITION · P&L; PORTFOLIO IMPACT; ALLOCATION · DRAWDOWN; CONTEXT | `AssetDetailView` | right column swapped; drawdown from the local peak; context rows hide when empty |
| 05 | Watchlist: table, selected box, actions | — | `WatchItem` (PFCore) + `WatchView` |
| 06 | Convert watch → position: add-transaction sheet + carry-over, ⌘Z undo | `TransactionSheet` | carry-over block; a real ledger transaction; the watch row is archived, not deleted |
| 07 | Alerts: rules table, log, delivery | 0.6 24h alert + depeg | `AlertRule` / `AlertEngine` (PFCore) + `AlertsView`; 0.6 notifications migrate to rules |
| 08 | Alert setup: command → fields → review (30d backtest, overlaps) → arm | palette parser | `AlertCommand` parser + setup sheet |
| 09 | Scenarios: c · b · u switcher, targets table, in-place edit, compare | 0.6 target screen | `PortfolioScenario` (PFCore) + `ScenariosView`; the target screen gains "save to scenario" |
| 10 | Benchmark: Analytics mode `b`, TWR vs BTC/ETH buy-and-hold, 1M–ALL, pp table, method | `PortfolioHistoryEngine` | `Benchmark` engine + Analytics mode |
| 11 | Empty states | — | watchlist · alerts · scenarios · what changed |
| 12 | Themes: no new colours | 0.6 `ThemePalette` | new UI uses tokens only |
| 13 | Settings: sidebar of 9 sections with status, filter, health, one section at a time | `SettingsView` (3 columns) | rewritten on the same row grammar; nothing dropped, duplicates merged |
| 14 | Status bar: five zones, message slot, ⚑, health glyph + popover, locked state | `StatusBar`, `TitleBar` | rewritten; the title bar drops LIVE / upd |

## Decisions on ambiguous points

1. **Sync of watchlist, alerts, scenarios: local to this Mac in 0.7.0.** The design says "synced". New record kinds would break the iPhone app's build (it switches over `SyncKind` exhaustively, and pf-ios is out of scope). A separate record type would need a CloudKit Production schema change. Stored in `intel.json` next to the ledger, versioned, never synced. The ledger and its sync are unchanged. Settings and the Alerts header say "on this Mac".
2. **Today = since local day start** (Settings → day starts, default 00:00), priced from price history at that moment; 7D / 30D from the quote's period change, else history. Assets without a start price are named in the empty state; nothing is estimated.
3. **"Deposits / withdrawals":** PF has no cash account. Buys and transfers in are money in; sells and transfers out are money out (the existing external-flow definition, the same one TWR uses). Labels say "money in · N buys" so nothing is renamed silently.
4. **Allocation target** = optional per-asset target weight in the Base scenario (design: "comes from the Base scenario's target weights").
5. **Overview second cell** stays TOTAL PNL with total return (0.6 semantics), rather than the design's earlier UNREALIZED PNL label.
6. **Theme rows:** `theme ‹ dark · light · system ›` + `dark variant ‹ dark · midnight · graphite ›`, mapped onto the 0.6 setting so 0.6 can still read it.
7. **Alert firing on one Mac only** needs synced rules; with local rules each Mac evaluates its own.
8. **Benchmark history** comes from the price history of BTC and ETH (fetched even when not held) and the portfolio's TWR over the same window. Missing data shows as "—" with the reason.

## Phases

1. PFCore domain: `IntelDocument` + store + migration, watchlist, alerts (engine, parser, backtest), scenarios, attribution, benchmark, with tests.
2. Navigation, g-leader, status bar + health popover, title bar.
3. Settings redesign.
4. What Changed + Overview band.
5. Watchlist + conversion.
6. Alerts manager + setup + evaluation and delivery.
7. Scenarios.
8. Benchmark.
9. Asset Detail.
10. Palette, empty states, `?` key list, theme pass, docs, full regression.
