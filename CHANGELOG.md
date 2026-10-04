# Changelog

All notable changes to PF Terminal are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.8.1]

### Fixed
- Crash in Overview's **Today · What Moved** band when every top mover's contribution was $0.

## [0.8.1] - Maintenance

### Changed
- The repository contains the source code and user and contributor documentation only: internal implementation plans are no longer published, and the development notes keep what contributors need to build and change PF.
- No app changes since 0.8.0.

## [0.8.0] - Agent Access

Your portfolio. Your data. Your agent. An optional way to connect an AI agent you choose to your local portfolio and manage it through MCP, with every ledger change confirmed in PF.

### Added
- **Agent access (MCP)**, off by default: an MCP client you choose (Claude Desktop, Cursor, local agents) connects to PF on this Mac by launching PF's own executable with `--mcp`. No network port, no server, no account. See [docs/AGENTS.md](docs/AGENTS.md).
- **Settings → agents + mcp**: access on / off, read only (default) or read + write, confirm writes, exposure toggles (exact values, notes and transaction history off by default; watchlist, alerts, scenarios), connection status, copy configuration, reveal executable, test connection, regenerate credential, activity log.
- **Tools**: portfolio context, summary, positions, asset, transactions, What Changed, analytics, benchmark, watchlist, alerts, scenarios, health; with read + write, transactions (add / update / delete), watch → position, watchlist, alert and scenario changes. Resources (`pf://…`) and review prompts.
- **In-app confirmation**: ledger changes and deletions always wait for **AGENT REQUEST** in PF (`⌘↵` confirm, `esc` deny), run exactly once as shown, expire after 2 minutes, and re-check the data before running. A recovery snapshot is taken before an agent's edit or deletion of a transaction.
- **Dry runs**: agents can preview a transaction (validation, weight and value after) or an alert (30-day backtest) without saving anything.
- **Any coin**: agents can ask about and record coins you don't hold yet, including ones outside the bundled registry (found online, priced for the request), as the transaction sheet does. Ambiguous tickers come back with the candidates, never a guess.
- **Connect a client**: Settings shows the steps for Claude Desktop, Claude Code and Cursor, with *copy json* and a ready-to-run Claude Code command.
- **Kill switch**: `⌘K` → *Disable MCP access* closes every connection at once. Status bar shows `⌁` only while a request waits, a client is connected or an agent just wrote.

### Changed
- **README** split into a short front page and [docs/GUIDE.md](docs/GUIDE.md), [docs/ICLOUD-SYNC.md](docs/ICLOUD-SYNC.md), [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md), [docs/AGENTS.md](docs/AGENTS.md) and [docs/ROADMAP.md](docs/ROADMAP.md).
- Settings has a tenth section (agents + mcp, `⌘9`); shortcuts moved to `⌘0`.

### Data
- New, local only: `agent-audit.json` (bounded activity log, no notes or amounts), the agent credential in the Keychain, agent settings in preferences. The ledger, `intel.json`, `alerts.json`, iCloud sync and widgets are unchanged.

## [0.7.0] - Portfolio Intelligence

Know what changed. Know what matters: what moved your portfolio and why, a watchlist, local alert rules, scenarios, a benchmark, and share cards with effects and animation.

### Added
- **What Changed** (tab 2, `d` from the portfolio): today · 7d · 30d split into market move and money in / out (excluded from performance), a one-line summary, a start → now bridge, allocation drift and every asset's impact on the portfolio. Missing start prices are named, never estimated. Movers stays one key away (`m`).
- **Watchlist** (tab 4): assets you follow without holding them, with price since added, distance to your entry, target, alert and note.
- **Watch → position**: `⌘↵` opens the add-transaction sheet prefilled; target, note and alert carry over; the watch row is archived; `⌘Z` undoes both.
- **Alerts** (`g a`, ⚑ in the status bar): price above/below, position P&L, portfolio value, weight, 24h move, stablecoin depeg, scenario target and drawdown. Fire once, on every cross (with hysteresis) or daily; never on stale prices. Setup goes command → fields → review with a 30-day backtest and overlapping rules. Delivery: macOS banner, the newest unseen alert in the menu bar popover, optional sound, quiet hours that queue.
- **Scenarios** (`g s`): conservative · base · bull sets of target prices projected onto your holdings, edited in place with the target parser (`25x`, `150k`), compared side by side. The target screen saves to the Base scenario (`⌘S`).
- **Benchmark** (Analytics, `b`): TWR vs BTC and ETH buy-and-hold for 1M · 3M · 6M · 1Y · ALL, in percentage points.
- **Asset Detail**: portfolio impact (today · 7d · 30d), weight against the Base target weight with trim size, drawdown from the position's local peak, and context (watch history, scenario targets, alerts).
- **⌘K verbs**: `alert …`, `watch …`, `convert …`, `scenario …`, `compare …`; typing a symbol lists the asset, where it appears and what you can do with it.
- **Settings**: day start for Today, dark variant for the system theme, launch at login (menu bar only), alert delivery.
- **Share cards**: two new cards, **what changed** (market move, flows, impact per asset) and **vs benchmark** (TWR against BTC / ETH in pp), next to performance. A WHO SEES WHAT panel lists every field as visible or hidden, with a safe-to-share check; percentages only unless the value is visible.
- **Card effects and animation**: scanlines, glow, dither, glitch and CRT; animated cards (3 s: count up, typewriter or scan) export as MP4 or GIF, rendered on this Mac.

### Changed
- **Navigation**: four tabs: portfolio · changes · analytics · watch (⌘1–4 or 1–4). Settings leaves the tab bar (⌘,). `g` then a key goes to any screen; `?` lists the keys of the current view.
- **Status bar**: five fixed zones. One message slot (events fade, failures stay longer), ⚑ count of unseen alerts, one health glyph with a popover (prices · feeds · iCloud · ledger · recovery). The title bar no longer shows LIVE / last update.
- **Settings**: one section at a time from a sidebar of nine, each with its status, a filter over every setting and a health summary. Nothing was removed; storage / cloud sync and health appear once.
- **Overview**: TWR · ALL replaces the 24h driver cell; TODAY · WHAT MOVED is a band with the market move, flows and the top three; ▲ marks positions above their target weight.
- **Menu bar popover**: value, 24h and $ impact per position with sparklines, what moved today, money in / out, and the newest unseen alert; open and details (`d`) actions. The menu bar title no longer carries an alert count, and many portfolios scroll instead of widening the popover.
- **UI/UX improvements** across every screen.
- The demo portfolio holds SOL instead of TEL.
- **0.6 notifications are alert rules now**: the 24h move and stablecoin depeg switches become editable rules, once, with the same behaviour: the 24h rule watches the active portfolio's 24h change (as in 0.6), at most once a day, with the same notification.

### Fixed
- **Locked Mac.** The ledger and recovery snapshots can't be read or written while the Mac is locked (complete file protection). PF Terminal now waits for unlock instead: a launch while locked no longer sets `portfolio.json` aside as unreadable or offers to start over, a save waits in memory, and iCloud sync pauses without moving its change token past data that isn't saved, so nothing can be uploaded as a deletion.

### Data
- Watchlist and scenarios are stored in `intel.json`, alert rules and their log in `alerts.json`, next to the ledger, on this Mac only (not synced in 0.7.0). The ledger, its format and iCloud sync are unchanged. Watchlist notes and scenarios use complete file protection; alert rules use "until first unlock" so alerts run while the Mac is locked. A newer file is opened read-only; an unreadable one is set aside, never deleted.

## [0.6.0] - A Ledger You Can Trust

Reliability and data integrity: safer iCloud sync, local recovery snapshots, correct return figures, safer imports, an app lock that holds, and appearance themes.

### Fixed
- **iCloud sync could delete or revert data in a few edge cases.**
  - **Reset or unreadable local ledger.** If `portfolio.json` was set aside as unreadable, or the ledger was reset or replaced while sync was on, every synced record was uploaded as a deletion. Now the missing records are fetched from iCloud again, and nothing is deleted.
  - **Older copy of a ledger.** When sync was turned on again with Merge or Upload on a Mac holding an older copy, that copy could overwrite newer edits in iCloud and bring deleted records back. Now iCloud's version stands, and the local copy is kept for review in conflicts.
  - **Older remote versions.** A remote version older than the one on this Mac (stale record or stale delete) no longer replaces it.
- **Clock-independent ordering.** Edits are stamped after the version they're based on, so a Mac with a slow clock can't lose its newer edit or delete.
- **Sync passes never overlap.** Turning sync off during a pass now stops it without writing anything.
- **Missing iCloud zone.** If the iCloud zone disappears after syncing, sync stops and keeps local data, instead of silently starting over empty.
- **Chart drop after a profitable sell.** When price history was missing and the chart fell back to locally recorded snapshots, a sell at a profit showed as a loss in the time-weighted chart (share card, drawdown). Money in and out now comes from the ledger.
- **Development builds.** A build signed for another CloudKit environment (a Debug build sharing the release app's data) pauses sync instead of mixing that environment's change tokens into the release app's sync state. The unit-test host no longer opens the real ledger or syncs.
- **RETURN was unrealized only.** The Overview and Analytics "RETURN" ignored realized P&L, so it was misleading after taking profit or a loss.
  - Overview now shows **TOTAL PNL** and **total return**: realized + unrealized over everything ever invested.
  - Analytics shows unrealized, realized, total P&L, total return, net contributed and **TWR** (time-weighted, deposits excluded).
  - The per-position column is labelled **UNRLZD %**.
- **Backdated transactions used today's price.** A blank price on a past date now uses that day's price from history, or asks for it. The preview says when a price was filled in automatically.
- **Transfers could get today's price as their cost basis.** A blank cost on a transfer in now uses the average entry of a matching transfer out from another portfolio, or must be entered (0 is allowed). A transfer out no longer stores a price.
- **App lock.**
  - It no longer unlocks when the system can't authenticate.
  - It now also locks when the Mac sleeps or the screen locks, after 5 minutes in the background, and as soon as it is turned on.
  - The menu bar item and popover show no amounts while the app is locked.

### Added
- **Appearance themes.** Settings → APPEARANCE → theme cycles through **dark** (the default, unchanged), **light**, **midnight**, **graphite** and **system**, which follows macOS. The switch is instant. Every theme meets WCAG AA contrast for text and gain/loss colours. Share cards and widgets keep their own look.
- **Recovery snapshots.**
  - Bounded, verified local snapshots of the ledger after changes. They are versioned and hold no settings, keys or caches.
  - A verified safety snapshot is taken before replace-import, restore, remove position, portfolio delete and USE ICLOUD. If that snapshot fails, the operation is cancelled.
  - Restore from Settings → DATA RECOVERY, with a preview of what changes.
- **Import preview.** Importing into a portfolio classifies each transaction as READY, DUPLICATE, NEEDS REVIEW or INVALID before anything is added. Rows that need review are imported only if you include them. Also available as **Import into Current Portfolio…**.
- **Data Health** in Settings. It checks ledger validity, possible duplicate transactions, stale or missing prices, sync conflicts and held-back records, sync health, and recovery-snapshot age. It never changes data, and each warning leads to a review.
- **Diagnostics.**
  - A local, bounded operational log, also written to the unified log.
  - A copyable report with versions, sync state, source health and backoff, and error types.
  - No portfolio names, values, quantities, notes, keys or account ids; this is enforced by tests.
- **Depeg notification** (opt-in). It notifies once when a held stablecoin leaves its ±0.5% band, and again only after it has recovered.
- **Today · what moved.** The Overview's 24h cell lists the top three flow-adjusted contributors.
- **Remove position** from a position's right-click menu. It deletes that asset's transactions in one portfolio, after confirmation and a safety snapshot.
- Transaction notes are shown under each transaction in Asset Detail.
- Menu items: Switch Portfolio (`⌘P`), Import into Current Portfolio, Import Backup (Replace), Export Backup (`⌘⇧E`), Restore Recovery Snapshot, Copy Diagnostic Report.
- Provider cooldowns (backoff after errors or rate limits) in Settings → MARKET DATA.
- A compact iCloud status in the status bar while sync is on: synced, syncing, offline, review or sync error.

### Changed
- **Movers** follows the Overview layout: a NET / DRIVER / BREADTH strip with the mode and range controls, and the table in a MOVERS panel with its note.
- **Analytics** is reorganised:
  - one two-row stat box (value, net contributed, open cost basis, unrealized, realized, total P&L / total return, TWR, max drawdown, best, worst);
  - performance with its drawdown underneath, beside a full-height allocation;
  - a POSITIONS · P&L table replaces the separate contribution and cost-to-value panels.
- **Share card "TOP GAINERS"** ranks your own return on each asset over the period, flow-adjusted like the headline, instead of the asset's price move. Only positive returns are listed, and stablecoins are left out.
- **Share screen.**
  - The options column scrolls, so picking fields never resizes the window.
  - The Quick Share header fits the narrow portrait and story formats.
- **Large portfolios.** Measured on a 10,000-transaction fixture:
  - Contribution maths is about 2× faster.
  - Unchanged-ledger sync change detection is about 12× faster (≈140 ms → ≈12 ms).
  - Live price ticks are coalesced to at most one recalculation every 0.5 s.
  - Portfolio history is cached between renders.
- Tables that end at a panel border no longer draw a double line under the last row.
- USE ICLOUD's pre-replace backup is now a verified recovery snapshot (previously a `portfolio.before-icloud-*.json` file).
- Settings shows the iPhone app as "in development", as the README does.

### Removed
- The unused `fallbackProvider` setting (it had no effect since 0.5.0).

## [0.5.0] - Market Data Release

Live exchange prices, a built-in asset registry, and stablecoin support.

### Added
- **Canonical Asset Registry.** A bundled top-1000 snapshot (registry version 2026-09-30) with CoinGecko ids, Binance pairs, contracts by chain and stablecoin metadata. It adds a curated, verified overlay (Bybit TELUSDT and KASUSDT, and TEL on Base and Polygon), and a validated overlay mechanism for rare future updates (disabled in 0.5.0: no requests).
- **Offline asset search.** Typing an asset searches the registry instantly: offline, during CoinGecko rate limits, and without `/search`. Online search is only used for tokens outside the registry. Tickers listed more than once are never auto-selected.
- **Bybit.** Public spot market data: a live WebSocket, prices and chart history, for verified pairs only.
- **Live feeds.** Binance and Bybit feeds with heartbeat, stale detection and reconnect with backoff. A backup exchange takes over when the first choice drops.
- **Preferred source.** Choose Auto (the default), Binance, Bybit or CoinGecko globally in Settings; per asset in Asset Detail, DexScreener is also offered where the asset has a verified contract. Only sources with a verified mapping are offered. *(Corrected: an earlier version of this entry listed DexScreener as a global choice.)*
- **Source status** in Asset Detail and the source picker: LIVE · BINANCE, LIVE · BYBIT, CACHED · 2m, DELAYED · 6m, FALLBACK · COINGECKO, FALLBACK · DEX, STALE · 18m, NO PRICE.
- **Stablecoin support** (USD peg), initially for USDT, USDC, DAI, USDS, FDUSD and PYUSD; the registry extends the list.
  - **Valuation.** On peg (±0.5%), they're valued at exactly $1.00 and show no daily move. In a depeg, the real market price is used.
  - **Asset Detail.** A PEG STATUS panel replaces the price chart. It shows the market price, deviation, when it was checked, and the target.
  - **Overview.** A `STABLE` label, or `DEPEG` in red.
  - **Analytics.** Allocation shows a **STABLECOINS** total.
- DAI, USDS, FDUSD and PYUSD are in the built-in coin list.

### Changed
- **Market routing.** Each asset follows its own verified route: its preferred source, then Binance, then Bybit, then batched CoinGecko, then DexScreener by canonical contract. The old default primary provider (CoinGecko) migrates to Auto.
- **Far fewer CoinGecko requests.** Assets priced by a live feed skip the minute-by-minute refresh, with a full pass every 15 minutes. Metadata comes from CoinGecko only, in one batched request per 15 minutes. History comes from Binance or Bybit first. Search makes no per-result price probes.
- **Search and source probes respect provider backoff and HTTP 429** again (local search covers discovery).
- **DexScreener** is only used for verified contracts, never ticker matches, for registry assets.
- **Stablecoin classification** comes from the registry (39 USD stablecoins), with the curated list as a fallback.
- **History loading** is queued (2 at a time), so changing chart range doesn't send bursts.
- Stablecoins aren't ranked as best/worst investments, and on peg they're left out of contribution to P&L.
- Peg prices are checked every 5 minutes as part of the normal refresh, not on every refresh.

### Fixed
- The price source picker always offers a coin's original market, so a DexScreener pick can be undone.
- USDT resolves to Tether when typed, and a rate-limited CoinGecko no longer leaves search with DEX pools only (the local registry answers first).

## [0.4.2] - Maintenance Release

A maintenance release: more reliable prices and a shared core for PF clients.

### Changed (macOS, no behavior change)
- **PFCore is a Swift package** (`Package.swift` at the repository root; products `PFCore`, `PFCoreUI`, `PFCoreTestSupport`). The macOS app uses it locally; other PF clients, such as the iPhone companion app in development, use the same package, so models, accounting and sync exist once.
- Platform-independent code moved into `PFCore`: market-data providers and cache, transaction validation and preview, history charts, freshness, sync host helpers, formatting, the widget snapshot model.
- The macOS version is set in one place, `Config/Versions.xcconfig`.

### Added
- TEL gets a second price source (DexScreener) when CoinGecko is rate-limited, using the canonical `telcoin-2` token (`0x7e13…0731` on Ethereum, Base and Polygon, per CoinGecko). The asset id stays `cg:telcoin`.
- DexScreener prices come from the pool that trades most in 24h (pools under $1,000 liquidity are ignored), not the deepest one. TEL's deepest pool barely trades and was about 20% below the market.

### Fixed
- Adding a transaction for an asset the portfolio doesn't hold now shows its current market price as the placeholder. With no market price the field stays empty and says "no market price".
- A partially priced total reads "≈ $89,715.00 · 1 unpriced" in the Overview headline and menu bar popover (shared with the iPhone app); unpriced rows stay unpriced.

## [0.4.1] - Maintenance Release

A maintenance and quality-of-life release.

### Changed
- **Dock behavior.** Closing the main window keeps PF Terminal running in the menu bar and removes it from the Dock.
- **Reopening.** Opening it again restores the Dock icon and focuses the window. This works from the menu bar, a widget, a `pfterminal://` link, a notification, or Finder and the Dock.

### Added
- **Keep in Dock when closed** (Settings → GENERAL), off by default. It keeps the Dock icon while only the menu bar item is open.
- **Version and build** shown in Settings → GENERAL.
- **Check for Updates…** (app menu and Settings → GENERAL). It compares your version with the latest stable GitHub release and, if a newer one exists, opens its release page. Nothing is downloaded or installed automatically, and no portfolio data is sent.

## [0.4.0] - First Public Release

The first public release of PF Terminal. Versions 0.1–0.3 were internal development milestones and were never published.

### Portfolio and accounting
- A native macOS portfolio terminal (SwiftUI and AppKit). It needs macOS 14 Sonoma or later and runs natively on Apple silicon and Intel.
- **Transaction ledger:** buy, sell, transfer in and transfer out, with fees. Transactions can be edited and deleted.
- **Accounting:** average cost with Decimal precision, realized and unrealized P&L, cost basis, and a flow-adjusted 24h contribution.
- **Multiple portfolios:** independent portfolios, an ALL PORTFOLIOS aggregate, and rename, archive and delete.

### Analytics and market data
- **Analytics:** performance charts (value or P&L), a money-weighted return, a time-weighted drawdown, allocation, contribution, movers, and a target-price simulator.
- **Market data:** CoinGecko, Binance (REST and WebSocket) and DexScreener, with fallback, a last-known-price cache and stale-data marking. The price source can be chosen per asset.

### Interface
- **Keyboard first:** a `⌘K` command palette with structured commands, portfolio switching (`⌘P`, `[ ]`), and full keyboard navigation.
- **Menu bar:** a companion with a popover.
- **Desktop widgets:** small, medium and large sizes. Each shows one portfolio or ALL, with a privacy mode.
- **Share cards:** privacy modes, three themes and several formats.
- **System:** opt-in 24h-move notifications and a Touch ID app lock.

### Sync and privacy
- **iCloud sync (optional, off by default):**
  - Uses your private CloudKit database; there is no PF account or server.
  - Portfolios, transactions and asset identities sync. Prices, caches, settings, widget data and keys never do.
  - Offline changes are queued.
  - Deletions propagate as tombstones.
  - Conflicts go to review, where the other version can be restored.
  - When you turn sync on, PF first compares this Mac with iCloud (upload, use iCloud, or merge).
- **Local-first:** a human-readable JSON ledger, export and validated import, no telemetry, and only public market-data requests over the network.
