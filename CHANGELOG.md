# Changelog

All notable changes to PF Terminal are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

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
