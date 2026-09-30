# Changelog

All notable changes to PF Terminal are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.5.0] - Market Data Release

Live exchange prices, a built-in asset registry, and stablecoin support.

### Added
- **Canonical Asset Registry.** A bundled top-1000 snapshot (registry version 2026-09-30) with CoinGecko ids, Binance pairs, contracts by chain and stablecoin metadata. It adds a curated, verified overlay (Bybit TELUSDT and KASUSDT, and TEL on Base and Polygon), and a validated overlay mechanism for rare future updates (disabled in 0.5.0: no requests).
- **Offline asset search.** Typing an asset searches the registry instantly: offline, during CoinGecko rate limits, and without `/search`. Online search is only used for tokens outside the registry. Tickers listed more than once are never auto-selected.
- **Bybit.** Public spot market data: a live WebSocket, prices and chart history, for verified pairs only.
- **Live feeds.** Binance and Bybit feeds with heartbeat, stale detection and reconnect with backoff. A backup exchange takes over when the first choice drops.
- **Preferred source.** Choose Auto (the default), Binance, Bybit, CoinGecko or DexScreener, globally in Settings or per asset in Asset Detail. Only sources with a verified mapping are offered.
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
