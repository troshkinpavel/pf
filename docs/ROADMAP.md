# Roadmap

Back to the [README](../README.md).

> Local-first is a feature, not a temporary limitation.

Roadmap milestones are product milestones, not app version numbers. The iPhone app has its own version line (1.1.0 on the App Store); its source is not part of this repository.

| Version | Scope | Status |
|---|---|---|
| v0.1 · Core terminal | Overview, movers, analytics, asset detail, transactions, command palette, share cards, menu bar, settings | **done** · internal milestone |
| v0.2 · Multiple portfolios | Independent portfolios, ALL aggregate, switcher, management, v1 → v2 migration | **done** · internal milestone |
| v0.3 · Widgets & alerts | Desktop widgets, portfolio 24h-move notification | **done** · internal milestone |
| v0.4 · iCloud sync | Optional sync between your own devices through your private iCloud (CloudKit) database, off by default | **done** |
| v0.5 · Market data | Canonical Asset Registry (bundled top-1000) · offline local asset search · Binance + Bybit live pricing · selectable preferred source · LIVE / CACHED / FALLBACK source status · far fewer CoinGecko requests · canonical-contract DexScreener fallback · stablecoin / cash-like support with peg monitoring · stale-while-revalidate caching | **done** |
| v0.6 · A ledger you can trust | Hardened iCloud sync, recovery snapshots and restore, correct total return and TWR, safer transaction prices and imports, app lock that holds, Data Health and diagnostics without portfolio data, appearance themes | **done** |
| v0.7 · Portfolio Intelligence | What Changed (market move vs money in/out), watchlist with watch → position, local alert rules, scenarios (c · b · u), benchmark vs BTC / ETH, share cards with effects and animation, redesigned navigation, settings, status bar and menu bar | **done** |
| v0.8 · Agent Access | Local MCP access for AI agents you choose: read-only by default, exposure controls, in-app confirmation of every ledger change, dry runs, activity log, kill switch | **done** · current |
| v0.9 · Automation | Shortcuts / App Intents actions, scheduled exports and share cards, synced watchlist / alerts / scenarios | planned |
| v0.10 · Wallets & exchanges | Read-only on-chain addresses (watch-only wallets), read-only exchange APIs, CSV import | planned |
| v1.0 · Stable PF Terminal for macOS | Stable, signed and notarized macOS release | planned |
| v2.0 · PF Terminal for iPhone | Native iOS app sharing the portfolio and accounting core | **released** · iPhone 1.0.0; 1.1.0 adds What Changed, watchlist, alerts and scenarios · [App Store](https://apps.apple.com/us/app/pf-terminal/id6817097908) |
| v2.1 · iOS widgets | Home and lock screen widgets | **released** · since iPhone 1.0.0; What Changed, Watch and Alerts widgets in 1.1.0 |
| v2.2 · Apple ecosystem | Deeper system integration across Apple platforms | planned |
| v3.0 · PF Cloud | Optional hosted features | exploratory |
