# PF Terminal 0.6.0: a ledger you can trust

**Status: released** as v0.6.0. [CHANGELOG.md](../CHANGELOG.md) lists every change.

0.6.0 makes PF Terminal safer to trust with a real ledger than a spreadsheet or a browser dashboard. It has three outcomes:
1. Understand what happened to the portfolio faster.
2. Spend less time maintaining data.
3. Never lose or silently revert it.

There are no new providers, no trading, and no redesign. The scope comes from the feature audit of 0.5.0: existing features are reused, not rebuilt.

## Never lose data

| Item | Status |
|---|---|
| **Sync hardening.** Stale copies and tombstones never win. A reset or unreadable ledger is recovered from iCloud, not tombstoned. Passes are serialized and cancellable. A missing zone stops sync. Sync state is pinned to its CloudKit environment. | done · in-memory matrix, plus the CloudKit Development soak (`--sync-e2e`), plus the 0.5.0 ↔ 0.6 round trip |
| **Safety snapshots.** Verified snapshots before replace-import, restore, remove position, portfolio delete and USE ICLOUD. The operation is cancelled if the snapshot fails. | done |
| **Rolling recovery snapshots.** Bounded, versioned, verified, never synced. | done |
| **Restore.** Pick a snapshot, see the preview and diff, confirm. The current state is snapshotted first, and the result is verified afterwards. | done |

## Numbers you can trust

| Item | Status |
|---|---|
| **Total P&L and total return.** Realized + unrealized, over everything ever invested. Overview, Analytics, ALL panel, menu bar, movers (ALL). | done |
| **Clear labels.** "Unrealized %" is shown as such. Realized P&L, net contributed. | done |
| **TWR %** in Analytics (deposits excluded). | done |
| **Backdated transactions.** That day's price from history, or the user enters it. Never today's price. Auto-filled prices are labelled. | done |
| **Transfer cost basis.** Linked to a matching transfer out (the source's average entry), or confirmed by the user. Never the market price. | done |

## Privacy that holds

| Item | Status |
|---|---|
| **App lock fails closed.** If the system can't authenticate, PF stays locked with an explanation. It can't be enabled without Touch ID or a password. | done |
| **Relock rules.** On sleep, screen lock, 5 minutes in the background, and as soon as it is turned on. | done |
| **Menu bar and popover** show no amounts while locked. | done |

## Less manual maintenance

| Item | Status |
|---|---|
| **Import into a portfolio** with a READY / DUPLICATE / NEEDS REVIEW / INVALID preview. | done |
| **Remove position** (right-click; ledger operation with confirmation and a safety snapshot). | done |
| **Transaction notes** shown in Asset Detail. | done |
| **Menus.** Switch portfolio `⌘P`, import into current portfolio, import (replace), export `⌘⇧E`, restore, diagnostics. | done |

## When something goes wrong

| Item | Status |
|---|---|
| **Data Health** in Settings: ledger, duplicates, prices, sync, recovery. Read-only; each warning leads to a review. | done |
| **Diagnostics.** Bounded local event log plus `os_log`, and a copyable report. Redaction is enforced by tests. | done |
| **Provider cooldowns** in Settings. The dead `fallbackProvider` setting is removed. | done |
| **Depeg notification.** Opt-in, once per event, with hysteresis. | done |
| **Sync status** in the status bar. | done |

## Performance (10,000-transaction fixture, `swift test -c release --filter LargePortfolioBenchmark`)

- **Contributions:** 53 → 26 ms.
- **Sync detection with an unchanged ledger:** 140 → 12 ms.
- **ALL summary:** 93 → 63 ms. Live ticks now coalesce to at most one recalculation every 0.5 s.
- **Portfolio history:** cached between renders.
- **Import preview (10k into 10k):** 24 ms.
- **Snapshot write and verify:** 125 ms, run in the background 20 s after edits settle.

Also shipped in 0.6.0: appearance themes (dark, light, midnight, graphite, system), Movers and Analytics following the design layout, share-card gainers by your own return.

## Follow-ups

- [ ] Run a two-device soak on two physical Macs, or a Mac and an iPhone build, against Development. Before release, the `--sync-e2e` soak ran with two independent clients on one Mac.
- [x] Update README screenshots for the new Overview and Analytics layouts (the menu bar and widget images are unchanged).

Before release, the 0.6.0 build was used on a real ledger with Production iCloud sync.

## Deferred (later releases)

- CSV, exchange and API imports; wallet integrations; watchlist.
- Generic price, value and allocation alerts.
- Scenario lab, portfolio and allocation targets, rebalancing.
- Volatility and best/worst periods, benchmark UI.
- Global hotkey.
- Registry remote overlay (the mechanism exists and stays off).
- Backup encryption.
- More exchanges.
