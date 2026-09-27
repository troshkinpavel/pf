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
| Future iOS app | `io.github.troskinpavel.pf.ios` |
| Future iOS widgets | `io.github.troskinpavel.pf.ios.widgets` |
| URL scheme | `pfterminal://` (public API, kept stable) |
| Keychain service | `io.github.troskinpavel.pf` |
| GitHub | [`troshkinpavel/pf`](https://github.com/troshkinpavel/pf) (the GitHub account is spelled with an "h"; the app identifiers above are not) |

- The repository is `pf`; the product is **PF Terminal**. Xcode targets and the Swift module keep the name `PFTerminal`.
- **Future iOS targets** use the same CloudKit container, so iPhone and Mac share one private database through `PFCore`. An App Group is a per-target entitlement: register `group.io.github.troskinpavel.pf` on the iOS App IDs too when the iOS app and its widgets need to share data. Mac and iPhone never share an App Group container; they share data only through CloudKit.
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
ICLOUD=1 NOTARY_PROFILE=pf-notary scripts/make-dmg.sh   # public release: iCloud (Production), notarized + stapled
scripts/make-dmg.sh                                     # → build/release/PF-Terminal.dmg + .sha256, no iCloud, not notarized
```

- The script archives Release with automatic signing and exports it for **Developer ID**. The App Group needs a Developer ID provisioning profile, which `-allowProvisioningUpdates` creates. It then packages the app with an Applications shortcut and signs the DMG with `Developer ID Application` (override with `SIGN_IDENTITY`). If the keychain lists the same Developer ID certificate twice, the name is ambiguous. In that case, pass its SHA-1 from `security find-identity -v -p codesigning`.
- Notarization runs only when `NOTARY_PROFILE` names an `xcrun notarytool store-credentials` profile. Without it, Gatekeeper reports the DMG as "Unnotarized Developer ID". Create the profile once, with an app-specific password or an App Store Connect API key:
  ```bash
  xcrun notarytool store-credentials pf-notary --apple-id <apple-id> --team-id <TEAM>
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
| `--snapshots` | DEBUG only. Walks every screen, renders the window, the share-card variants and the widget layouts, then quits. Add `--snapshots-stdout` to stream the PNGs to stdout (a team-signed app's container is protected), and `--snapshots-chrome` to include the title bar. |

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
- `PFTerminalUITests` covers onboarding, palette → preview → confirm, and quick share. Xcode needs macOS automation permission to run them.

## Project layout

```
PFTerminal/
  App/          PFTerminalApp (scenes, commands, key routing), AppStore (+Commands, +Transactions,
                +Portfolios, +Sources, +Widgets, +Sync, +Lifecycle)
  MarketData/   provider protocol + router, CoinGecko, Binance (+WebSocket stream), DexScreener, Mock
  Persistence/  MarketCache (SwiftData)
  System/       Keychain, notifications, app lock, reachability, DEBUG snapshots
  UI/           Components, Screens, Share, MenuBar
PFCore/         platform-neutral core, no AppKit/SwiftUI (reusable by a future iOS target):
  Domain/       Models, Portfolios (PortfolioContext, CRUD), PortfolioEngine, PortfolioHistoryEngine,
                ScenarioEngine, CommandParser, ShareModel, AsciiChart, WidgetSnapshotBuilder
  Persistence/  PortfolioDocument (JSON ledger/backup, schema v2), AppSettings
  Sync/         SyncModels, SyncEngine, CloudKitSyncStore
  Updates/      SemanticVersion, UpdateState, UpdateChecking, GitHubReleaseChecker
Shared/         compiled into app + widget: formatting, design tokens, widget snapshot model/store,
                stepped chart, widget layouts (kept platform-neutral for a future iOS target)
PFWidgets/      WidgetKit extension: App Intents configuration, timeline provider, previews
PFTerminalTests/, PFTerminalUITests/
scripts/        make-icon.swift, make-sample-portfolio.py, frame-screenshot.swift
```

## Market data

```
Views → AppStore → ProviderRouter (actor) → CoinGecko · Binance · DexScreener
                 ├→ BinanceStream (WebSocket miniTicker, USD pairs)
                 └→ MarketCache (SwiftData: last-known quotes, price history, snapshots)
```

- **Views never know which provider answered.**
- **Routing.**
  - Each asset goes to the first provider that supports it and returns a quote.
  - An asset whose source the user has pinned asks that provider first.
  - When a provider fails, its assets fall through to the next one.
  - Missing metadata (supply, ATH, 7d/30d change) is filled from another provider, at most every 15 minutes.
- **Backoff.** A failing provider is blocked for 15 s, 30 s, 60 s and so on, up to 15 minutes. `Retry-After` on HTTP 429/418 is honoured.
- **Scheduling.**
  - While the window is active, the app refreshes at the configured interval (15 s to 5 min, default 60 s).
  - In the background the interval is ×5, with a minimum of 5 minutes.
  - Opening the popover refreshes immediately.
  - Nothing polls while the Mac sleeps, and the app refreshes on wake.
- **Freshness.**
  - `LIVE`: every held asset has a non-cached quote that is younger than the interval + 30 s.
  - `SYNCING`: a request is in flight.
  - `PARTIAL`: the data is fresh, but some assets have no quote.
  - `STALE <age>`: the quotes are cached or old.
  - `OFFLINE`: there is no network; the app shows the last-known values.
- **Identity.** Assets are never keyed by ticker alone. The internal id (`cg:<id>`, `dex:<chain>:<contract>`) stays stable. The provider mapping for an asset can change through **price source** in Asset Detail.
- **Credentials.** No credentials are needed for prices. An optional CoinGecko demo key is stored in the Keychain and sent only to `api.coingecko.com`.

### Adding a provider

1. Implement `MarketDataProvider` (`PFTerminal/MarketData/MarketDataProvider.swift`). The `history(for:range:currency:)` and `search(_:)` methods are optional.
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
2. Register the provider in `AppStore.makeProviders()`. If the user should be able to select it, also add it to `AppSettings.providerOptions`.
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

## Storage

The app is sandboxed:

```
~/Library/Containers/io.github.troskinpavel.pf/Data/Library/Application Support/pf/
  portfolio.json             canonical ledger (human-readable, schema-versioned)
  portfolio.v1-backup.json   written once if a v1 file was migrated
  sync-state.json            iCloud sync bookkeeping (device-local; only when sync was used)
  legacy-migration.json      what was copied from the legacy container (see Identifiers)
  market.store               SwiftData cache: quotes, price history, per-portfolio snapshots
~/Library/Group Containers/group.io.github.troskinpavel.pf/
  widget-snapshot*.json, widget-portfolios.json   (widget data, no transactions)
```

- **Preferences** are stored in `UserDefaults`.
- **Secrets** are stored in the Keychain (service `io.github.troskinpavel.pf`).
- **Unreadable ledger.** If `portfolio.json` cannot be read, the app moves it aside; it never overwrites it.

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

- **Platform-neutral core.** `PFCore/Sync` uses Foundation, CryptoKit and CloudKit only, with no AppKit. A future iOS app reuses it as it is.
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
- **Enabling.** `SyncEngine.inspect` compares both sides without changing anything, and the user picks an option in a confirmation:

  | Situation | Action |
  |---|---|
  | iCloud has no PF data | **upload** |
  | This Mac is empty | **use iCloud** (fetched in full before anything is replaced) |
  | Both have data | **merge** (union by id) or **use iCloud** (this Mac's ledger is copied to `portfolio.before-icloud-*.json` first) |
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
- **iOS.**
  - The schema carries no platform-specific data: payloads are the `PFCore` Codable models, and all sync logic is `PFCore/Sync`.
  - A future iOS target (`io.github.troskinpavel.pf.ios`) with the same container entitlement can use `SyncEngine` and `CloudKitSyncStore` as they are, with no schema change.
  - Only the host side is per-platform: an `AppStore`-like `SyncHost`, entitlement checks, and background triggers such as a push subscription (`CKDatabaseSubscription`) on iOS.

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
