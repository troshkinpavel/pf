# How PF Terminal works

Privacy model, market data, accounting and architecture. Back to the [README](../README.md).

## Local-first and privacy

```text
your transactions ─▶ PF engine (on your Mac) ─▶ ~/Library/Containers/…/pf/portfolio.json
                                                  market cache (SwiftData, same container)
                         └─ optional iCloud sync ─▶ your private CloudKit database (portfolios, transactions)

market-data APIs ◀── coin identifiers only (e.g. "bitcoin", "BTCUSDT", chain + contract)
```

- **Portfolio data** stays on your Mac: transactions, quantities, cost basis and portfolio names. If you turn on [iCloud sync](ICLOUD-SYNC.md), it is also copied to your private iCloud. PF has no account, no backend, no analytics and no crash reporting.
- **Network requests** go only to Binance, Bybit, CoinGecko and DexScreener (public market data, no account), Apple's iCloud if you turn on sync, and `api.github.com` when you choose **Check for Updates** (it reads the latest release; nothing about you or your portfolio is sent). Market requests carry asset identifiers, plus your search text when you look up a new asset. They use an ephemeral HTTP session, with no cookies. No quantities or values are ever sent.
- **API key.** You can add an optional CoinGecko key. It is stored in the Keychain and sent only to `api.coingecko.com`.
- **Sandboxing.** The app is sandboxed, with outgoing network access and access to files you choose. Widgets read a small snapshot from a shared App Group container. That snapshot contains no transactions.
- **Backups.** Export writes a readable `.json` backup. Import validates the whole file and asks for confirmation before it replaces anything.
- **Recovery snapshots**. PF keeps a bounded set of local snapshots of the ledger in `backups/` next to `portfolio.json`. Each is verified after writing. They hold only portfolios, transactions and asset identities: no settings, keys or caches. They never sync, and like `portfolio.json` they are not encrypted by PF.
- **App lock**. Touch ID or your login password. It locks at launch, as soon as you turn it on, when the Mac sleeps or the screen locks, and after 5 minutes in the background. If the system can't authenticate, PF stays locked; it never unlocks by default.
- **Agent access (optional)**. Off by default. When on, an MCP client on your Mac talks to PF through a Unix socket in PF's sandbox container (no network port), only via PF's own signed executable and with a per-Mac credential. See [Agent access](AGENTS.md).
- **Diagnostics**. A local log of operational events, and a report you can copy from Settings → DIAGNOSTICS. It holds versions, sync and source status and error types, but no portfolio names, values, quantities, notes, keys or account identifiers. Nothing is sent anywhere unless you paste the report somewhere yourself.

## Market data

- **Asset registry.** The app includes a registry of the top 1,000 assets, with their verified exchange pairs and contracts. Searching for an asset is instant and works offline. Tickers that belong to more than one asset are never picked for you.
- **Where prices come from.** With **Auto** (the default), each asset uses live exchange feeds first: Binance, then Bybit. CoinGecko is the batched fallback, and DexScreener is used only for an asset's verified contract. A source is used only when the asset is verified to trade there; nothing is matched by ticker alone.
- **Price status.** Asset Detail shows the source and state of each price: `LIVE · BINANCE`, `CACHED · 2m`, `DELAYED · 6m`, `FALLBACK · COINGECKO`, `STALE · 18m` or `NO PRICE`. If your preferred source fails, the fallback is labeled as such.
- **Preferred source.** Choose Auto, Binance, Bybit or CoinGecko in Settings → MARKET DATA. For a single asset, use **Asset Detail → price source**, which only offers the sources that asset actually has.
- **Refresh.** Live feeds update prices continuously. Other prices refresh every 60 s by default (15 s to 5 min), less often in the background, never during sleep. Cached prices appear immediately at launch. CoinGecko is asked much less often than before, so rate limits rarely leave a gap.
- **Stablecoins.** USDT, USDC and other USD stablecoins are valued at exactly $1.00 while within ±0.5% of the peg. Their peg is checked every few minutes. Outside that band they're marked **DEPEG** and valued at the real market price.

## Accounting model

Transactions are the source of truth. PF never stores a balance; it derives everything from the ledger:

- **Average cost.** Fees are added to the cost basis on buys and subtracted from the proceeds on sells. A sell realizes P&L against the average cost. A full exit clears the cost basis exactly.
- **Exact decimals.** Ledger maths uses `Decimal`.
- **24h change is flow-adjusted.** A buy made today is not counted as a gain. **TODAY · WHAT MOVED** lists the three positions that moved the portfolio's value the most, which are not necessarily the ones with the largest percentage move.
- **Validation.** A sell can't exceed what the portfolio held at that date.
- **Total return** = (realized + unrealized P&L) ÷ everything ever invested (buys and transfers in, at cost, with fees).
- **Prices you leave blank**. A buy or sell dated today uses the market price. A backdated one uses that day's price from history, or asks you for it; it never uses today's price. A transfer in uses the average entry of a matching transfer out, or asks for its cost basis (0 is allowed, but must be entered). The preview always says when a price was filled in automatically.

## Architecture

```text
Package.swift      the PFCore Swift package (products PFCore, PFCoreUI, PFCoreTestSupport)
PFCore/            platform-neutral core (no AppKit/UIKit/SwiftUI), shared by PF Terminal clients
├── Domain/        portfolio engine, history, movers, scenarios, transaction planner, command parser, share privacy
├── Market/        provider router · Binance + Bybit (REST, LiveFeeds WebSockets) · CoinGecko · DexScreener · sources · mock
├── Registry/      bundled canonical asset registry (top 1,000) + validated overlay store
├── Persistence/   JSON ledger (schema-versioned, migrated), recovery snapshots, settings, SwiftData market cache
├── Platform/      Keychain, notifications, app lock (LocalAuthentication), reachability, diagnostics log
├── Updates/       GitHub release check, semantic versions
├── Sync/          sync engine, record model, CloudKit store (private database), host helpers
├── Formatting/    number and date formatting
└── Widgets/       widget snapshot model and App Group store
PFCoreUI/          shared SwiftUI: design tokens, widget layouts, share card
PFCoreTestSupport/ in-memory CloudKit stand-in for tests      PFCoreTests/ package tests (wire format)
PFTerminal/        macOS app (App, Agent (MCP server + stdio relay), Persistence, UI; System: DEBUG-only snapshots, CloudKit self-test, sync E2E, WidgetCheck)
PFWidgets/         macOS WidgetKit extension (App Intents configuration)
PFTerminalTests/   unit tests (Swift Testing)                 PFTerminalUITests/ UI tests (XCUITest)
```

The app is built with Swift, SwiftUI and AppKit. It also uses SwiftData (the market cache), WidgetKit and App Intents, and `URLSession` (REST and WebSocket). Charts are custom SwiftUI drawing; Swift Charts is not used.

**Tests.**
- Unit tests cover:
  - accounting and history;
  - multiple portfolios and the ALL aggregate;
  - migrations, including the move from the earlier app identity;
  - backup validation, command parsing and provider fallback;
  - share-card and widget privacy;
  - sync, against a simulated CloudKit store with two devices, including a second client exchanging portfolios, transactions and deletes with the real Mac app state;
  - the PFCore package tests pin the sync payloads and CloudKit record fields that every PF client shares.
  - return semantics, blank-price rules, recovery snapshots and restore, import classification, Data Health, diagnostic report redaction, app-lock and menu bar privacy, depeg alerts, a 10,000-transaction benchmark, and the sync hardening matrix;
  - agent access (0.8): permissions, exposure redaction, confirmations (expiry, replay, conflicts), dry runs, lock, resources, hostile input, audit and the socket handshake.
- UI tests cover onboarding, a palette trade with confirmation, quick share, and the Dock / menu bar lifecycle.

The build, signing, data formats and how to add a market-data provider are documented in **[docs/DEVELOPMENT.md](DEVELOPMENT.md)**.
