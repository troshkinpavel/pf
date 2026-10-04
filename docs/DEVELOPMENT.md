# PF Terminal — development notes

This file is for contributors: the build setup, the architecture and the data formats. For a product overview, see the [README](../README.md).

## Identifiers

These are PF Terminal's long-term identity. They are defined once, in `Config/Signing.xcconfig`, and nothing else hard-codes them.

| What | Identifier |
|---|---|
| PF Terminal (macOS) | `io.github.troskinpavel.pf` |
| PF Widgets (macOS) | `io.github.troskinpavel.pf.widgets` |
| App Group | `group.io.github.troskinpavel.pf` |
| CloudKit container | `iCloud.io.github.troskinpavel.pf` |
| URL scheme | `pfterminal://` (public API, kept stable) |
| Keychain service | `io.github.troskinpavel.pf` |
| GitHub | [`troshkinpavel/pf`](https://github.com/troshkinpavel/pf) (the GitHub account is spelled with an "h"; the app identifiers above are not) |

- The repository is `pf`; the product is **PF Terminal**. Xcode targets and the Swift module keep the name `PFTerminal`.
- Team: your Apple Developer team (set in `Config/Signing.local.xcconfig`, never committed).
- **Legacy identity.** Up to v0.3.0, PF Terminal used `io.github.pfterminal.PFTerminal`, the widgets used `….PFWidgets`, and the App Group was `<TEAM>.io.github.pfterminal`. The CloudKit container `iCloud.io.github.pfterminal` was provisional and never registered. These identifiers survive only as `LegacyIdentifiers`, for the data migration below. Don't reuse them.

### Migration from the legacy identity

A new bundle ID means a new sandbox container and a new preferences domain. Without a migration, an existing portfolio would look empty. `LegacyMigration` runs once at launch, before the ledger is read:

- **Reads** the old container through a read-only sandbox exception for `~/Library/Containers/io.github.pfterminal.PFTerminal/Data/Library/`. macOS lets an app read the container of an app signed by the same team.
- **Copies** `portfolio*.json` (the ledger and every backup) and `market.store*` byte for byte. Portfolio IDs, transaction IDs and timestamps stay identical. The ledger is copied last.
- **Imports** `pf.*` preferences (settings, active portfolio, share defaults) only where the new domain has no value yet.
- **Never overwrites.** If the new container already has `portfolio.json`, nothing is copied.
- **Leaves the old container untouched**, as a recovery path, and writes `legacy-migration.json` next to the ledger. Once that marker exists, the migration never runs again.
- **Doesn't copy** `sync-state.json` (it belonged to the provisional container) or the widget snapshots (they are regenerated).
- **Fallback.** If the old data exists but can't be read (for example, an ad hoc build with no team), nothing changes. The status bar says so, and **import** opens the old folder, where you can pick `portfolio.json`.
- **Keychain.** The optional CoinGecko key is not migrated. The old item's access list belongs to the old app, so reading it would raise a system prompt. Re-enter the key in Settings.
- **Widgets.** Existing widgets belonged to the old extension. Remove them and add **PF Terminal** again.
- **Notifications.** Permission is per bundle ID, so macOS asks again the first time a move alert is on.

## PFCore package

The platform-neutral core is a Swift package, **PFCore**, defined by `Package.swift` at the repository root. SwiftPM only resolves remote packages whose manifest is at the root, so it lives there; its targets point at folders in this repository.

| Product | Folder | Contents |
|---|---|---|
| `PFCore` | `PFCore/` | Models, accounting, history and movers, scenarios, transaction planner, command parser, share-card privacy, market-data providers, ledger and settings persistence, SwiftData market cache, CloudKit sync, formatting, widget snapshot model. Foundation, CloudKit and SwiftData only. |
| `PFCoreUI` | `PFCoreUI/` | Shared SwiftUI: design tokens, widget layouts, share card. |
| `PFCoreTestSupport` | `PFCoreTestSupport/` | `MockRemote` (in-memory CloudKit private zone) and `Device` (minimal sync host) for tests. |
| tests | `PFCoreTests/` | Wire-format tests: byte-exact sync payloads, the CloudKit record mapping, tombstones, newer-schema blocking, price fallback. |

- **One copy.** The macOS project uses this package locally (a local package reference to the repository root). Other PF clients consume the same package by URL. No client keeps its own copy of models, accounting or sync code.
- **Public API.** Everything a client needs is `public`. Adding API is normal; renaming or removing it is a breaking change for other clients.
- **Data contract.** Record type `PFRecord`, zone `PFZone`, the container, stable ids, payload JSON, tombstones and conflict rules are defined here, once. A change here changes every client; `PFCoreTests` must keep passing.
- **Clients pin a revision.** A client depends on `https://github.com/troshkinpavel/pf` at an **exact commit** during development, and at an explicit tag once it ships. It never follows `main`, so a PF commit can't silently break it. To move a client forward: change the pinned revision in that client, resolve packages, build and run its tests (including its sync compatibility tests).
- **Checks:** `swift build` and `swift test` (macOS); for iOS: `swift build --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"`.

## Versions

The macOS version lives in **`Config/Versions.xcconfig`** and nowhere else:

```
MACOS_MARKETING_VERSION = 0.5.0     // CFBundleShortVersionString of PF Terminal.app and PFWidgets
MACOS_BUILD_NUMBER = 4              // CFBundleVersion
```

- The app and widget targets map them to `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- **Bump macOS:** edit `MACOS_MARKETING_VERSION` (semantic version) and increase `MACOS_BUILD_NUMBER`; then update `CHANGELOG.md`, the README platform table and the release notes.
- **Other PF clients** keep their own version lines and are released separately.

## Build

- macOS 14 Sonoma or later (deployment target). Development happens on current macOS with current Xcode. Xcode 16 or later is required because the project uses folder-synchronized groups.
- Swift, with the Swift 5 language mode. No third-party dependencies.

```bash
open PFTerminal.xcodeproj                      # scheme: PFTerminal, ⌘R
xcodebuild -project PFTerminal.xcodeproj -scheme PFTerminal -configuration Release -derivedDataPath build build
```

The built app is at `build/Build/Products/Release/PF Terminal.app`.

### Signing and App Groups

Signing settings come from `Config/Signing.xcconfig`. A fresh clone builds **ad hoc** ("Sign to Run Locally"). The app then works fully, except that the desktop widgets show "NO DATA YET". To enable the widgets, create `Config/Signing.local.xcconfig`. The file is gitignored, so your team ID is never committed.

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_STYLE = Automatic
```

- **Why a profile.** A `group.`-prefixed App Group (`group.io.github.troskinpavel.pf`) needs a provisioning profile, which automatic signing creates on your team. Build once with `-allowProvisioningUpdates`, or in Xcode.
- **Registering the App Group.** `xcodebuild -allowProvisioningUpdates` registers the app ID and the iCloud container, but not the App Group or the widget's app ID. Do this once in Xcode: open **Signing & Capabilities** for **PFTerminal**, add **App Groups**, and tick `group.io.github.troskinpavel.pf`. Repeat for **PFWidgets**. Until you do, Settings shows the widget snapshot as "write failed".
- **Entitlements follow the signing style.** Manual/ad hoc builds use `*-Unprovisioned.entitlements`, which have no App Group, and they don't touch the group container at runtime (`PF_APP_GROUP_RUNTIME` is empty). Automatic builds use `PFTerminal.entitlements` and `PFWidgets.entitlements`.
- **Other identifiers.** If you build under your own team and can't use these identifiers, override `PF_BUNDLE_ID`, `PF_APP_GROUP` and `PF_ICLOUD_CONTAINER` in the local file.

### iCloud sync (optional)

iCloud sync is off by default, and default builds don't include the capability. In those builds, Settings → DATA & SYNC reports "iCloud unavailable" and nothing else changes. CloudKit entitlements need a provisioning profile for a registered container, so enabling it is opt-in:

1. Add the following to `Config/Signing.local.xcconfig`:
   ```
   CODE_SIGN_STYLE = Automatic
   PF_APP_ENTITLEMENTS = Config/PFTerminal-iCloud.entitlements
   ```
2. Build once with `-allowProvisioningUpdates`, or press ⌘R in Xcode. This registers the App IDs, the App Group and `iCloud.io.github.troskinpavel.pf` on your team, and creates the profiles. Container identifiers are permanent: they can't be deleted or renamed.
3. At launch, the app checks its own entitlements (`AppStore.hasCloudEntitlement`) before it touches CloudKit.

**Environments.**
- `PF_ICLOUD_ENV` is `Development` by default. Local builds talk to the Development database, whose schema is created automatically on first save.
- Release DMGs ship iCloud sync (from v0.4). Build them with `ICLOUD=1 scripts/make-dmg.sh`, which sets `PF_ICLOUD_ENV = Production`. The Production schema must be deployed first, or sync in the release build will fail to save.
- Before shipping, deploy the schema (record type `PFRecord`, zone `PFZone`) to Production in the CloudKit Console. Production never auto-creates record types.
- Development and Production data are completely separate.

### Release DMG

```bash
ICLOUD=1 NOTARY_PROFILE=<profile> scripts/make-dmg.sh   # iCloud (Production), notarized + stapled
scripts/make-dmg.sh                                     # → build/release/PF-Terminal.dmg + .sha256, no iCloud, not notarized
```

- The script archives Release with automatic signing and exports it for **Developer ID**. The App Group needs a Developer ID provisioning profile, which `-allowProvisioningUpdates` creates. It then packages the app with an Applications shortcut and signs the DMG with `Developer ID Application` (override with `SIGN_IDENTITY`). If the keychain lists the same Developer ID certificate twice, the name is ambiguous. In that case, pass its SHA-1 from `security find-identity -v -p codesigning`.
- Notarization runs only when `NOTARY_PROFILE` names an `xcrun notarytool store-credentials` profile. Without it, Gatekeeper reports the DMG as "Unnotarized Developer ID". Create the profile once, with an app-specific password or an App Store Connect API key:
  ```bash
  xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <TEAM>
  ```
- Check a candidate:
  ```bash
  spctl -a -vvv -t open --context context:primary-signature PF-Terminal.dmg
  xcrun stapler validate PF-Terminal.dmg
  ```
- **Manual smoke checks** for each release candidate, which automated tests can't cover:
  1. Click a desktop widget while the app is menu-bar-only: the main window opens and the Dock icon returns.
  2. Click a PF notification (turn on a 24h-move alert and wait for one): the same.
  3. Test Touch ID app lock.
- The filename stays `PF-Terminal.dmg` for every version, so `releases/latest/download/PF-Terminal.dmg` keeps working.
- To publish, upload the `.dmg` and the `.sha256` to a GitHub Release.

### Development mode (offline, deterministic)

These are launch arguments. They are in the scheme but disabled by default.

| Argument | Effect |
|---|---|
| `--mock-market` | `MockMarketDataProvider`: fixed prices and a deterministic history, with no network. The UI shows a **MOCK DATA** tag. |
| `--demo` | Loads the demo ledger, which is marked **DEMO**. |
| `--ui-testing` | Throwaway storage and separate preferences. Your real portfolio is never touched, and no widget snapshots are published. |
| `--snapshots` | DEBUG only. Walks every screen, renders the window, the share-card variants and the widget layouts, then quits. Add `--snapshots-stdout` to stream the PNGs to stdout (a team-signed app's container is protected), and `--snapshots-chrome` to include the title bar. `--stablecoin-shots` renders the peg screens. |
| `--mcp` | Not a debug flag: the MCP stdio relay that agent clients launch (see Agent Access). Reads `PF_MCP_TOKEN`, optional `PF_MCP_DEBUG=1`. |
| `--agent-demo` | DEBUG only, with `--ui-testing`. Agent Access on, read + write, with the fixed credential `pfm_demo_credential` (never the Keychain), for trying a client against the demo ledger. |
| `--agent-shots` | DEBUG only, with `--snapshots`. Renders the agents settings section, confirmation sheets, activity log and status indicator. |
| `--sync-e2e` | DEBUG only, with `--ui-testing`. Two independent clients against CloudKit **Development** in a throwaway `PFE2E-*` zone (deleted at the end): enable plans, propagation, offline queue, restarts, conflicts and restore, merge / use iCloud, plus the 0.6 soak (repeated launch/foreground/reconnect, offline edits on both sides, same-record conflict, delete vs stale copy, reset ledger, interrupted pass, disable mid-pass, idempotence). Prints PASS/FAIL. |
| `--cloudkit-selftest` · `--list-pfzone` | DEBUG only. Round trip in a throwaway `PFSelfTest-*` zone · list `PFZone` record metadata. |
| `--render-conflicts` · `--widget-check` | DEBUG only. Render the conflict sheet · write and check a widget snapshot. |

Debug builds are signed for CloudKit **Development** and share the release app's container. Since 0.6, sync state records the environment it belongs to, and a build signed for another environment leaves sync paused instead of mixing tokens. The unit-test host (`xcodebuild test`) opens throwaway storage and starts nothing.

README screenshots are produced by these commands:

```bash
"build/dd/Build/Products/Debug/PF Terminal.app/Contents/MacOS/PF Terminal" \
  --ui-testing --mock-market --demo --snapshots --snapshots-stdout --snapshots-chrome \
  | grep '^PFPNG ' | while read -r _ name b64; do echo "$b64" | base64 -d > "shots/$name.png"; done
swift scripts/frame-screenshot.swift shots/03-overview.png .github/assets/hero.png 2000
```

### Tests

```bash
xcodebuild -project PFTerminal.xcodeproj -scheme PFTerminal test
swift test                                     # PFCore package tests
swift test -c release --filter LargePortfolioBenchmark   # 10,000-transaction timings
```

- `PFTerminalTests` (Swift Testing) covers the domain logic, with no network. It includes:
  - the accounting (weighted average, sells, fees, transfers, realized and unrealized P&L);
  - the flow-adjusted 24h contribution;
  - history reconstruction, and the TWR and money-weighted returns;
  - the target simulator;
  - share-card privacy;
  - command parsing;
  - provider fallback, using stub providers;
  - backup validation;
  - migration from v1 to v2;
  - portfolio create, rename, archive and delete;
  - the ALL aggregation;
  - persistence of the active portfolio;
  - widget snapshot privacy and context;
  - iCloud sync against an in-memory CloudKit stand-in with two simulated devices: the enable plans; propagation of create, edit and delete; the offline queue; conflicts; merges without duplicates; import while syncing; newer-schema records; account changes; disable.
- 0.6 (`IntegrityAppTests`, `ReturnSemanticsTests`, `TransactionPricingTests`, `RecoveryAndQualityTests`, `SyncHardeningTests`):
  - safety snapshots, including that a failed snapshot cancels the operation;
  - restore round trip;
  - import classification;
  - remove position;
  - menu bar privacy while locked, and the lock lifecycle;
  - diagnostic-report redaction;
  - depeg hysteresis;
  - tick coalescing;
  - backdated and transfer prices;
  - return semantics;
  - Data Health;
  - the sync hardening matrix.
- `UpdatesTests`, `MarketAppTests`, `StablecoinAppTests` and `PriceSourceTests` cover update checks, registry search and routing, stablecoin valuation, and source picking.
- `PFTerminalUITests` covers onboarding, palette → preview → confirm, quick share, and the Dock / menu bar lifecycle. Xcode needs macOS automation permission to run them.
  - `LifecycleUITests.testCloseHidesFromDockAndEveryReopenPathRestoresIt` clicks the menu bar item.
  - It fails if that item is hidden (a full or notched menu bar) or when another PF Terminal instance is running. It failed that way on clean `main` once during the 0.6 work, then passed 5 of 5 runs.
- **Upgrade/downgrade check** (0.5.0 ↔ 0.6), on one data directory with the real 0.5.0 code:
  ```bash
  git worktree add --detach /tmp/pf-050 v0.5.0 && cp scripts/cross-version/XV050.swift /tmp/pf-050/PFCoreTests/
  export PF_XV_DIR=$(mktemp -d)
  (cd /tmp/pf-050 && PF_XV_STEP=1-write-050 swift test --filter XV050)
  PF_XV_STEP=2-upgrade-06 swift test --filter CrossVersionTests
  (cd /tmp/pf-050 && PF_XV_STEP=3-read-050 swift test --filter XV050)
  PF_XV_STEP=4-upgrade-again-06 swift test --filter CrossVersionTests
  git worktree remove --force /tmp/pf-050
  ```
- `PFCoreTests` (package): byte-exact sync payloads, the CloudKit field mapping (`PFRecord` in `PFZone`, payload in `encryptedValues`), tombstones, newer-schema blocking, old `sync-state.json` files, what may sync, and the TEL price fallback.
- `MacPhoneCompatibilityTests` drives the real Mac `AppStore` against a second client over the in-memory CloudKit stand-in: ledger out, transaction in, delete back.

## Project layout

```
PFTerminal/
  App/          PFTerminalApp (entry: app or `--mcp` relay; scenes, commands, key routing), AppStore (+Commands,
                +Transactions, +Portfolios, +Sources, +Market, +Widgets, +Sync, +Lifecycle, +Integrity, +Agent)
  Agent/        0.8 Agent Access: JSONValue, AgentTransport (socket server + MCPRelay), MCP (JSON-RPC
                dispatch, confirmations), AgentPolicy (settings, tiers, exposure, audit), AgentTools
                (catalogue, schemas, args), AgentReads, AgentWrites, AgentResources (+ prompts)
  Persistence/  LegacyMigration
  System/       DEBUG snapshots, CloudKit self-test, sync E2E + soak, WidgetCheck
  UI/           Components, Screens, Share, MenuBar
Package.swift   the PFCore package (see PFCore package above)
PFCore/         platform-neutral core, no AppKit/UIKit/SwiftUI:
  Domain/       Models, Portfolios (PortfolioContext, CRUD), PortfolioEngine, PortfolioHistoryEngine,
                ScenarioEngine, TransactionPlanner, ImportPlanner, DataHealth, Stablecoins, CommandParser,
                ShareModel, AsciiChart, WidgetSnapshotBuilder, Freshness
  Market/       provider protocol + router, Binance, Bybit, LiveFeeds (WebSockets), MarketSources,
                CoinGecko, DexScreener, AssetCatalog, Mock
  Registry/     AssetRegistry (bundled CanonicalAssetRegistry.json), RegistryOverlayStore
  Persistence/  PortfolioDocument (JSON ledger/backup, schema v2), LedgerSnapshots, AppSettings, MarketCache (SwiftData)
  Platform/     Keychain, notifications, app lock (LocalAuthentication), reachability, Diagnostics
  Updates/      SemanticVersion, UpdateState, UpdateChecking, GitHubReleaseChecker
  Sync/         SyncModels, SyncEngine, CloudKitSyncStore, SyncHostSupport
  Formatting/   Fmt, DateFmt, NumberInput
  Widgets/      WidgetPortfolioSnapshot, WidgetSnapshotStore, PFLink
PFCoreUI/       design tokens (Theme), widget layouts, step chart, share card
PFCoreTestSupport/  MockRemote + Device (sync), LargeFixture (10k-transaction benchmark)
PFCoreTests/
PFWidgets/      WidgetKit extension: App Intents configuration, timeline provider, previews
PFTerminalTests/, PFTerminalUITests/
scripts/        make-icon.swift, make-sample-portfolio.py, frame-screenshot.swift, make-dmg.sh,
                cross-version/XV050.swift (0.5.0 half of the upgrade/downgrade check)
```

## Agent Access (MCP, 0.8)

User guide, permissions and the security model: [AGENTS.md](AGENTS.md).

- **Transport.** `PF Terminal --mcp` (`MCPRelay`) copies stdio ↔ a Unix socket at `<container>/Data/tmp/pf-mcp.sock` (`AgentTransport.socketURL`). The relay runs in PF's sandbox (same binary, same entitlements) and never touches PF data. The app (`AgentServer`) owns the socket only while access is on, checks the peer's audit token against its own designated requirement (`LOCAL_PEERTOKEN` + `SecCodeCheckValidity`), then the handshake credential (Keychain account `agent-mcp-credential`). Lines are capped at 1 MB.
- **Dispatch.** `AppStore.agentHandle` (JSON-RPC: initialize, ping, tools/*, resources/*, prompts/*) → `agentCallTool`: mode → exposure → lock → handler → confirmation → audit. Handlers read the app's in-memory state and cached calculations; nothing decodes the ledger per request.
- **Writes.** Each write handler validates with the app's own code (`TransactionPlanner.preview`, `PortfolioEngine.validate`, `AlertCommand`, `Watchlist`, `Scenarios`) and returns a frozen `AgentOperation`. Ledger writes go through `commitTransaction` / `removeTransactionCommitted`, the same path as the transaction sheet, so persistence, rolling snapshots, cache invalidation and iCloud sync behave exactly as for a user edit.
- **Agent settings** are app-only (`pf.agent.v1`), not `AppSettings`: other PF clients are unaffected. PFCore gained one additive case, `SnapshotStore.Reason.beforeAgent`.
- **Manual check.** Build Debug, launch with `--ui-testing --mock-market --demo --agent-demo`, then pipe JSON-RPC lines into `PF_MCP_TOKEN=pfm_demo_credential "…/PF Terminal" --mcp`.

## Market data

```
Views → AppStore ──→ ProviderRouter (actor) → Binance · Bybit · CoinGecko · DexScreener (REST)
          ├──────→ LiveFeed ×2 (WebSocket: Binance miniTicker, Bybit v5 spot tickers)
          ├──────→ AssetRegistry (bundled canonical registry + overlays, local search)
          └──────→ MarketCache (SwiftData: last-known quotes, price history, snapshots)
```

Views never decide routing or status. They render `SourceState` from PFCore (`PFCore/Market/MarketSources.swift`).

### Canonical Asset Registry

- **Snapshot.**
  - The file is `PFCore/Resources/CanonicalAssetRegistry.json`, bundled with PFCore.
  - It is the 2026-09-30 top-1000 list, supplied as-is: registry version `2026-09-30`, source CoinMarketCap, ranked by market cap.
  - Records have ids like `cmc-1`, and fields for symbol, name, CoinGecko id, market-cap rank, Binance symbol, contracts by chain and stablecoin info.
  - The app never regenerates it. Every field except id, symbol and name is optional. `bybitSymbol` and `exchangeSymbols` (Gate.io, KuCoin, …) are there for later enrichment.
- **Ledger ids are unchanged.**
  - Assets keep `cg:<coingecko id>`. Catalog overrides still apply: TEL stays `cg:telcoin` while the registry maps it to `telcoin-2`.
  - Registry-only assets without a CoinGecko id get `cmc:<n>`.
  - `AssetRegistry.entry(for:)` finds a record by CoinGecko id or registry id, never by ticker.
- **Overlays.** Overlays patch the snapshot; they never replace it. An overlay that fails validation (wrong base version, unknown ids, bad JSON, over 2 MB) is ignored.
  - **Curated overlay** (`RegistryOverlay.curated`, shipped in code, verified by hand): Bybit `TELUSDT`, and TEL's Base and Polygon contracts.
  - **Remote overlay** (`RegistryOverlayStore`, for later): at most one check every 5 days, never at startup, cached in `Application Support/pf/registry/`, and applied on the next launch. **No `remoteURL` is set (0.5.0), so no overlay request is ever made.**
- **Versioning.**
  - `registryVersion` names the snapshot.
  - An overlay lists the snapshot versions it applies to (`baseRegistryVersions`).
  - A new snapshot ships with an app update.
- **Local search** (`AssetRegistry.search`):
  - Order: exact ticker or name, then ticker prefix, then name prefix, then CoinGecko or registry id, then substring. Market-cap rank breaks ties.
  - It works offline and during CoinGecko 429s.
  - A ticker the registry lists more than once (10 in this snapshot, for example `GUSD`) is never auto-selected.
  - Online search (CoinGecko or DexScreener `/search`) runs only when the registry has no match. It respects backoff.
- **Known snapshot gaps, handled.**
  - USDT's Binance symbol is `USDTTRY`, a lira pair. Only pairs quoted in USDT, USDC or FDUSD are accepted, so it's rejected.
  - 44 assets have no CoinGecko id.
  - USDS isn't in the snapshot; the curated stablecoin list covers it.
  - Contract chains use CoinGecko platform ids. They map to DexScreener chain ids (`MarketMappings.dexChains`), and chains without a certain id are skipped: robinhood, hyperevm, cardano, klay, xdc, manta, internet-computer.

### Sources and routing

- **Mappings.**
  - `MarketMappings` gives each asset its verified identity per source: the asset's own identifiers, the registry, or the curated overlay. Nothing is inferred from a ticker.
  - The available sources, in automatic order, are: Binance → Bybit → CoinGecko → DexScreener (canonical contracts only).
- **Route.** `MarketMappings.route` lists the available sources in that order, with the preferred one first.
  - The preferred source comes from the asset (the picker in Asset Detail) or from Settings → preferred source. **Auto** is the default.
  - Unavailable sources are never offered.
- **Router rounds.** Each remaining asset goes to its next untried source that isn't backing off. Each round sends one batched request per provider. Failures fall through to the next source.
- **Live feeds** (`LiveFeed`, public WebSocket, no key):
  - An asset subscribes to the streaming sources in its route that come before the first non-streaming one. A preferred REST source means no stream, and so do on-peg stablecoins.
  - Heartbeat: a ping every 20 s (Bybit, `{"op":"ping"}`) or 30 s (Binance, protocol ping).
  - A feed silent for `streamSilence` (90 s) is dropped and reopened with exponential backoff (5 s … 5 min).
  - Feeds stop during sleep and reconnect on wake.
  - A backup feed's tick is used only while the first-choice feed isn't live for that asset. The price then shows as FALLBACK.
- **Status** (`SourceState.evaluate`, thresholds in `MarketStatusPolicy`):

  | Label | Meaning |
  |---|---|
  | `LIVE · BINANCE` / `LIVE · BYBIT` | Streamed within 120 s from the first-choice feed |
  | `CACHED · 2m` | From the first-choice source or disk cache, not streaming, ≤ 5 min old |
  | `DELAYED · 6m` | 5–15 min old |
  | `FALLBACK · COINGECKO` / `· DEX` | A lower source answered because the first choice failed |
  | `STALE · 18m` | Over 15 min old: the last-known value |
  | `NO PRICE` | Nothing yet |

- **CoinGecko reduction.**
  - Coins that are live on a feed skip the REST refresh.
  - A full pass every 15 min (`AppStore.fullRefreshInterval`) keeps metadata current.
  - Metadata (supply, market cap, ATH, 7d/30d/1y change) comes from CoinGecko only: one batched `/coins/markets` call per 15 min.
  - History prefers Binance or Bybit klines. It falls back to CoinGecko `market_chart` only without an exchange mapping.
  - Search uses no `/search` for registry assets, and makes no per-result price probes: known or cached prices first, then at most one batched request.
- **DexScreener safety.** DexScreener is only queried by verified chain + contract: registry contracts, the curated TEL chains, or a token the user picked by contract. The existing best-pool rule still applies (≥ $1,000 liquidity, most 24h volume), and a failing chain never loses the others.
- **Backoff.** A failing provider is blocked for 15 s, 30 s, 60 s and so on, up to 15 min. `Retry-After` on 429/418 is honored. Search and source probes respect it too.

### Caching (stale-while-revalidate)

The UI shows what it has immediately, and refreshes in the background.

| Data | Freshness |
|---|---|
| Live price | ≤ 120 s since the last tick; feed considered down after 90 s of silence |
| Current price | Refresh at the configured interval (default 60 s; ×5 in the background). Persisted in `MarketCache` and shown at launch. CACHED ≤ 5 min, STALE after 15 min |
| Stablecoin peg | Re-checked every 5 min while on peg, as part of the normal batch; a depeg is polled normally |
| Metadata | 15 min (CoinGecko, batched) |
| History | 1H: 2 min · 24H: 10 min · 7D: 30 min · longer: 6 h. Cached on disk. At most 2 requests in flight, queued, so changing chart range never bursts |
| Registry overlay | ≥ 5 days between checks; disabled in 0.5.0 |

- **Scheduling.**
  - While the window is active, the app refreshes at the configured interval (15 s to 5 min).
  - In the background, it refreshes at ×5 the interval, at least every 5 min.
  - Opening the popover refreshes immediately.
  - Nothing polls while the Mac sleeps.
- **Portfolio freshness** (status bar): `LIVE` / `SYNCING` / `PARTIAL` / `STALE <age>` / `OFFLINE`. It counts market-driven assets only; on-peg stablecoins don't count.
- **Credentials.** No credentials are needed for prices. An optional CoinGecko demo key is stored in the Keychain and sent only to `api.coingecko.com`.

### Adding a provider

1. Implement `MarketDataProvider` (`PFCore/Market/MarketDataProvider.swift`). The `history(for:range:currency:)` and `search(_:)` methods are optional.
   ```swift
   struct MyProvider: MarketDataProvider {
       let name = "MyProvider"
       func supports(_ asset: Asset) -> Bool { … }
       func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] { … }
   }
   ```
   - Batch your requests.
   - Throw `MarketError.rateLimited`, `.offline`, `.unavailable` or `.unsupported`, so that the router can back off correctly.
   - Send only the identifiers that the request needs. Never send quantities or values.
2. Give it a `MarketSource` (for example `MarketSource("Gate.io")`), a verified mapping in `MarketMappings` (for example from `RegistryAsset.exchangeSymbols["gateio"]`) and a place in `MarketSource.autoOrder`. Register it in `AppStore.makeProviders()` (and in each other PF client). If it has a public live feed, add a `LiveFeed.Venue`. If users should be able to select it globally, add it to `AppSettings.providerOptions`.
3. Test it with a stub provider (see `RouterTests`).

## Accounting

- **Average cost.**
  - Buy: adds `qty·price + fee` to the cost basis.
  - Sell: realizes `qty·price − fee − avg·qty` and removes `avg·qty` from the cost basis. A full exit removes exactly the remaining cost.
  - Transfer in: adds the quantity at the given cost per unit.
  - Transfer out: removes quantity at average cost and realizes only its fee.
- **Decimal ledger.** All ledger maths uses `Decimal`. `Double` is used only for charts and display.
- **24h contribution.** It is flow-adjusted: `qty_now·p_now − qty_24h·p_24h − net flows`. A buy made today is not counted as a gain.
- **History.** It uses the holdings at each point in time multiplied by the price at that time.
  - Performance headers show the P&L change and a **money-weighted** return.
  - Drawdown uses a **time-weighted** index, so deposits never look like gains.
- **Portfolios.**
  - Every transaction has a `portfolioID`, and a sell can only use coins from its own portfolio.
  - **ALL** computes each portfolio independently and then sums the results. It does not merge the ledgers, because that would re-average sells across portfolios.
  - Archived portfolios are excluded from ALL.
- **Base currency.** The base currency is the ledger currency. Mixed-currency ledgers are not converted.

## Stablecoins

All rules live in `PFCore/Domain/Stablecoins.swift`. The UI only renders `PegCheck`.

- **Classification.**
  - Stablecoins come from the registry's `stablecoin` metadata (`pegCurrency`, `targetPeg`): 39 USD stablecoins in the 2026-09-30 snapshot.
  - `Stablecoins.whitelist` is the curated fallback: USDT, USDC, DAI, USDS, FDUSD and PYUSD. It keeps USDS, which isn't in the snapshot.
  - `Asset.isStablecoin`, `pegCurrency` and `targetPeg` read the registry first, then the fallback.
  - `StablecoinPeg` has a currency and a target, so other pegs can be added later.
- **Tolerance.** `Stablecoins.tolerance` is ±0.5% of the target, and the edge is inclusive.
- **Valuation** (when the ledger currency is the peg currency):

  | Market price | Valued at | Status |
  |---|---|---|
  | Within tolerance | Exactly the target, 0% change | normal |
  | Outside tolerance | The real market price | depeg |
  | None yet | The target | unchecked |

  - **One source of valuation prices.** `valuationQuotes` produces them, and everything that values or charts the portfolio reads them: summaries, P&L, movers, the widget snapshot and the menu bar. The raw market quotes stay in `AppStore.quotes`, for freshness and the peg panel.
  - **History.** `valuationSeries` flattens points inside the band and keeps real historical depegs. An on-peg stablecoin with no history gets `flatSeries`, so the portfolio chart doesn't disappear.
  - **Other ledger currencies** (EUR, CHF): PF has no FX rates, so a USD stablecoin is priced like any other asset.
- **Checks.**
  - On-peg stablecoins join the normal batched refresh only every `Stablecoins.checkInterval` (5 min). They add no extra requests.
  - A depeg is polled like any other asset.
  - Requests go through `ProviderRouter` as before, with its cache, backoff and 429 handling.
  - When providers fail, the last cached quote keeps deciding the state: a depeg stays a depeg.
  - On-peg stablecoins don't count toward the LIVE/STALE freshness state.
- **P&L.**
  - Transactions and cost basis are unchanged. A USDC buy at 0.9998 keeps that cost.
  - On peg, the value is quantity × 1.00, so unrealized P&L is only the difference against the entry price, and the 24h change is 0.
  - In a depeg, value and P&L follow the market price.
  - Stablecoins aren't ranked as best/worst investments. On peg they're left out of Analytics → contribution to P&L; a depegged one is listed there.
- **UI.**
  - Overview: a `STABLE` label, or `DEPEG` in red.
  - Asset Detail: a **PEG STATUS** panel (market, deviation, when checked, target, valued at) replaces the price chart and the price-target panel.
  - Analytics → allocation: a **STABLECOINS** total.
  - Widgets stay snapshot-only.

## Storage

The app is sandboxed:

```
~/Library/Containers/io.github.troskinpavel.pf/Data/Library/Application Support/pf/
  portfolio.json             canonical ledger (human-readable, schema-versioned)
  portfolio.v1-backup.json   written once if a v1 file was migrated
  sync-state.json            iCloud sync bookkeeping (device-local; only when sync was used)
  backups/pf-*.json          recovery snapshots (0.6): versioned envelope, verified on write, bounded
  diagnostics.json           last 200 operational events (0.6): category, level, fixed code, error kind
  agent-audit.json           agent activity (0.8): newest 500 calls, no notes / amounts / credential
  legacy-migration.json      what was copied from the legacy container (see Identifiers)
  market.store               SwiftData cache: quotes, price history, per-portfolio snapshots
~/Library/Group Containers/group.io.github.troskinpavel.pf/
  widget-snapshot*.json, widget-portfolios.json   (widget data, no transactions)
```

- **Preferences** are stored in `UserDefaults`.
- **Secrets** are stored in the Keychain (service `io.github.troskinpavel.pf`).
- **Unreadable ledger.** If `portfolio.json` cannot be read, the app moves it aside; it never overwrites it.
- **Recovery snapshots** (`SnapshotStore`).
  - **Envelope.** `{format: "pf-ledger-snapshot", version: 1, createdAt, reason, appVersion, contentHash, portfolios, transactions, document}`. The document is the schema-v2 ledger without settings.
  - **Verification.** A snapshot counts only after it is read back and its content hash matches.
  - **Rolling.** 20 s after ledger edits settle, and at launch, but only when the ledger changed.
  - **Safety.** Taken before replace-import, restore, remove position, deleting a portfolio with transactions, and USE ICLOUD. These operations are cancelled if the snapshot fails.
  - **Retention.** The newest 8 rolling snapshots, one per day for 14 days, and the newest 8 safety snapshots, all within 64 MB. The newest 3 always stay.
  - **Unknown files.** Unknown formats and newer versions are ignored and never offered for restore.

### Backup format (schema v2)

```json
{
  "schemaVersion": 2,
  "app": "pf Terminal",
  "exportedAt": "2026-09-27T12:00:00Z",
  "portfolios": [ { "id": "…", "name": "MAIN", "glyph": "◈", "createdAt": "…", "status": "active", "isDemo": false } ],
  "assets": [ { "id": "cg:bitcoin", "symbol": "BTC", "name": "Bitcoin", "coingeckoID": "bitcoin", "binanceSymbol": "BTCUSDT" } ],
  "transactions": [ { "id": "…", "portfolioID": "…", "assetID": "cg:bitcoin", "type": "BUY", "quantity": "0.12",
                      "price": "58400", "currency": "USD", "timestamp": "…", "fee": "0" } ],
  "settings": { … }
}
```

Decimals are stored as strings. Import decodes, migrates and validates the whole file before it changes anything. The app then asks you to confirm before it replaces your portfolios. For a breaking change, increment `PortfolioDocument.currentSchema` and add a step to `migrate(_:)`.

## iCloud sync

```
AppStore (+Sync) ── SyncHost ──▶ SyncEngine (PFCore/Sync, pure + async cycle) ──▶ SyncRemoteStore
                                                                                   ├ CloudKitSyncStore (private DB)
                                                                                   └ MockRemote (tests)
```

- **Platform-neutral core.** `PFCore/Sync` uses Foundation, CryptoKit and CloudKit only, with no UI framework. Every PF client uses it as it is.
- **What syncs.** Each portfolio, transaction and asset identity is one record, keyed by its stable id (UUID, or the canonical asset id). The payload is the object's backup-format JSON, stored in a CloudKit `encryptedValues` field.
- **What never syncs.** Prices, price history, caches, widget snapshots, derived P&L, settings, UI state and Keychain secrets.
- **Where it lives.** Only the **private** database is used, in the custom zone `PFZone`, record type `PFRecord`. Nothing is ever written to the public database.
- **Change tracking.**
  - `sync-state.json`, next to `portfolio.json`, is device-local.
  - It keeps a content hash, the remote version and a `pending` flag per record, plus the change token.
  - Edits are detected by diffing the ledger against it, so every mutation path is covered without per-call hooks.
  - The diff runs on every local save. A change is queued in `sync-state.json` immediately, even while offline, and survives a restart. Its `modifiedAt` is the edit time, which is what "newer edit wins" compares.
  - Pending changes are the offline queue, retried on save (2 s debounce), on network return, when the app becomes active, every 5 minutes and on `CKAccountChanged`.
- **Deletes.** Deletes are tombstones (`deletedAt`, no payload). CloudKit records are never hard-deleted, so a device that was offline still learns about the delete.
- **Conflicts.**
  - Saves use `ifServerRecordUnchanged`.
  - When a record changed on two devices, an edit beats a delete, and a newer edit beats an older one.
  - The losing version is kept in `SyncState.conflicts` and can be restored from Settings → DATA & SYNC → conflicts. Nothing is silently discarded.
  - A transaction whose portfolio was deleted elsewhere goes to a `RECOVERED` portfolio.
  - Duplicate portfolio names get a suffix, deterministically on every device.
  - A synced ledger may become oversold. It is then shown as it is: local loads skip the oversell check, while imports stay strict.
- **Hardening (0.6).**
  - **Monotonic stamps.** A local change is stamped after the version it is based on, so clock skew can't lose it.
  - **Never-synced copies.** A copy that was never synced (`version == nil`) loses to iCloud, tombstones included.
  - **Stale versions.** A remote version older than the one held locally is treated as stale: the local one is kept and re-sent.
  - **Replaced documents.** A document that shares no portfolio with the synced set is treated as *replaced*. Its missing records are forgotten rather than tombstoned, and a full fetch brings them back (`SyncState.recovering`).
  - **Serialized passes.** Passes per host are serialized and stop after any await if cancelled or turned off.
  - **Missing zone.** `zoneNotFound` with a change token turns sync off instead of recreating an empty zone.
  - **Environment.** `SyncState.environment` pins the state to one CloudKit environment.
- **Enabling.** `SyncEngine.inspect` compares both sides without changing anything, and the user picks an option in a confirmation:

  | Situation | Action |
  |---|---|
  | iCloud has no PF data | **upload** |
  | This Mac is empty | **use iCloud** (fetched in full before anything is replaced) |
  | Both have data | **merge** (union by id; where both hold an id with different content, iCloud's version stands and the local copy goes to conflicts) or **use iCloud** (a verified `before-icloud` recovery snapshot of this Mac's ledger first) |
  | Both are identical | **resume** |

  No command or shortcut toggles sync.
- **Disabling.** Local data is kept and the iCloud copy is left alone. Turning sync on again repeats the comparison.
- **Account changes.** A different iCloud account (the `userRecordID` changed) turns sync off instead of pushing data into the new account. If the PF zone was deleted in iCloud settings, sync also turns off and nothing is re-uploaded.
- **Import while syncing.** Records match by id, so importing the same backup doesn't duplicate anything. The import alert says that the replacement propagates to synced devices.
- **Schema.**
  - `SyncRecord.schemaVersion` is currently 1.
  - A record from a newer schema is neither applied nor overwritten. It is listed in `SyncState.blocked` until the app is updated.
  - A breaking payload change needs a new version and a decode step in `SyncEngine.apply`.
- **Widgets.** Widgets never query CloudKit. They render the snapshot that the app writes after each (synced) recalculation.
- **Market cache.** `MarketCache` sets `cloudKitDatabase: .none`. With the iCloud entitlement, SwiftData would otherwise mirror the cache to CloudKit automatically. The DEBUG checks verify that no `com.apple.coredata.cloudkit.zone` exists.

### CloudKit schema (Development)

**Zones.**
- One custom zone per user, `PFZone`, in the **private** database. Custom zones give change tokens (`recordZoneChanges`) and `ifServerRecordUnchanged` saves.
- There are no subscriptions yet. Sync runs on app triggers.
- The DEBUG checks use throwaway zones (`PFSelfTest-*`, `PFE2E-*`) and delete them afterwards.

**Record type.** One record type, `PFRecord`, with one record per domain object. The record name is the sync key: `portfolio.<UUID>`, `transaction.<UUID>` or `asset.<canonical id>`.

| Field | Type | Notes |
|---|---|---|
| `kind` | String | `portfolio`, `transaction` or `asset` |
| `id` | String | Stable identity. It is never a name or a ticker. |
| `schemaVersion` | Int64 | Payload format. It is currently 1. |
| `modifiedAt` | Date/Time | When the change was made on the originating device |
| `deletedAt` | Date/Time | Set only on tombstones |
| `deviceID`, `deviceName` | String | For conflict messages. `deviceName` is the Mac's name. |
| `portfolioID` | String | Transactions only, for diagnostics |
| `payload` | Bytes, **encrypted** (`encryptedValues`) | The object's JSON, in the same form as the backup file. Decimals are strings and dates are ISO 8601. |

- **References and indexes.** Relationships are plain UUID strings inside the payloads (`transaction.portfolioID`, `transaction.assetID`). They are not `CKReference`s, so a delete never cascades on the server. The engine never runs `CKQuery`, so no queryable or sortable indexes are needed. When deploying, keep only what the console requires by default (`recordName` queryable, for the Dashboard).
- **Versioning.**
  - A payload change that old clients can't read needs a higher `schemaVersion`. Older clients never apply or overwrite such a record: they list it in `SyncState.blocked`.
  - A new CloudKit field is additive. Fields are never renamed or retyped once the schema is in Production.
- **Deploying to Production.** The schema was deployed for v0.4.0. Repeat these steps for any later schema change.
  - Do this only right before the first public build that ships iCloud sync: in the CloudKit Console, open Schema → Deploy to Production.
  - Release builds must then set `PF_ICLOUD_ENV = Production`, which `ICLOUD=1 scripts/make-dmg.sh` does.
  - `xcrun cktool export-schema` (it needs a CloudKit management token) exports the Development schema, so you can diff it against this table first.
- **Other clients.**
  - Every PF client (the iPhone app included) uses this schema unchanged: same container, private database, `PFZone`, `PFRecord`, same payloads. There is no client-specific record type or field.
  - Payloads are the `PFCore` Codable models, and all sync logic is `PFCore/Sync`. `PFCoreTests/SyncCompatibilityTests` pins the payload bytes and CloudKit fields.
  - Only the host side is per client (the Mac's `AppStore` is one `SyncHost`).
  - `SyncState.devices` / `lastRemoteChange` (device names for status lines) are optional fields, so older `sync-state.json` files decode unchanged.

## Widgets

- **App side.**
  - After each portfolio recalculation, the app writes one snapshot per context (every live portfolio and ALL) to the App Group.
  - It writes at most once every 30 s, and it skips the write when nothing visible changed.
  - It then calls `WidgetCenter.reloadTimelines`.
- **Widget side.** The widget only reads a snapshot and renders it. It makes no network calls, reads no ledger and does no portfolio maths.
- **Privacy.** With widget privacy off, every currency amount is removed while the snapshot is built. It is not just hidden when the widget renders.
- **Deep links.** `pfterminal://portfolio` and `pfterminal://asset/<canonical id>`.

## App lifecycle

| State | Behavior |
|---|---|
| Main window open | Regular app: Dock icon and menu bar item |
| Main window closed | Keeps running as a menu bar item. `NSApp.setActivationPolicy(.accessory)` removes the Dock icon, unless **keep in Dock when closed** (`AppSettings.keepInDock`, Mac-local, never synced) is on. |
| Reopened | `AppStore.presentMainWindow()` sets `.regular`, opens or focuses the single `Window("main")`, then activates the app |
| `⌘Q` | Quits |

- **Close is never quit.** `applicationShouldTerminateAfterLastWindowClosed` returns `false`, and `Info.plist` has no `LSUIElement`.
- **Every reopen path calls `presentMainWindow()`:**
  - the menu bar popover;
  - the app-menu commands;
  - a Dock or Finder reopen (`applicationShouldHandleReopen`);
  - `pfterminal://` deep links, which include widget taps (`handleDeepLink`);
  - notification clicks (`UNUserNotificationCenterDelegate`).
- **Safety net.** Whenever the main window becomes key, the app is `.regular` again.
- **Launch.** The menu bar label captures SwiftUI's `openWindow` and opens the window if window restoration left none.
- **Tests.** `LifecycleUITests` checks the real activation policy through `NSRunningApplication`.

## Updates

**Today: manual checks only.**
- **Where it runs.** **Check for Updates…**, in the app menu and under Settings → GENERAL.
- **What it does.**
  - Asks the GitHub Releases API of `troshkinpavel/pf` for recent releases. The request is anonymous: no account, token, cookies, identifiers or portfolio data. The `User-Agent` is just `PF-Terminal`.
  - Compares versions semantically (`SemanticVersion`). Drafts and prereleases are ignored, as are tags that aren't plain version tags.
  - If a newer release exists, opens its canonical page, `https://github.com/troshkinpavel/pf/releases/tag/<tag>`. That URL is built from the validated tag, never taken from response fields.
- **What it never does.** Download, mount or install anything, or touch quarantine or Gatekeeper.
- **Structure** (`PFCore/Updates`):
  - `UpdateChecking` is the source protocol; `GitHubReleaseChecker` implements it.
  - `Updates.evaluate`, a pure decision, maps the result to `UpdateState` (idle, checking, up to date, update available, failed).
  - Settings renders only `UpdateState`, so the source can be swapped without touching the UI.

**Future automatic updates with Sparkle** (assessed; not integrated):
- **Fit.** Sparkle 2 is the standard updater for Developer ID apps outside the Mac App Store. It suits PF's DMG releases and supports sandboxed apps through its XPC installer services.
- **Required:**
  - Add the Sparkle package, the first third-party dependency, and include its XPC services in the sandboxed app.
  - Generate an **EdDSA (ed25519) key pair** with `generate_keys`. The private key stays in the maintainer's Keychain and never goes into the repo. The public key goes into `Info.plist` (`SUPublicEDKey`).
  - Sign every update archive with `sign_update`. Sparkle checks that signature and the Developer ID code signature before installing.
  - Publish an **appcast** feed (`SUFeedURL`). It can be generated by `generate_appcast` and hosted on GitHub (Pages, or a file in the repo), with release assets as the download URLs.
- **Signing and notarization.** Each update must still be Developer ID signed, notarized and stapled, the same pipeline as `scripts/make-dmg.sh`. Sparkle doesn't relax Gatekeeper.
- **Preferences.** Automatic checking and installing should be opt-in, with `SUEnableAutomaticChecks` off by default and a Settings toggle. Manual **Check for Updates…** keeps working the same way. A `SparkleUpdateChecker` behind `UpdateChecking`, or Sparkle's own UI, would replace `GitHubReleaseChecker`.

## Typeface

The design uses **Geist Mono** (SIL OFL). By default the app renders with SF Mono, which has every box-drawing and block glyph the charts need. To use Geist Mono instead, put `GeistMono-*.ttf` files in `PFTerminal/Resources/`. They are bundled and used automatically.
