# PF Terminal 0.6.0 plan: reliability and data integrity

Status: **planned**. Nothing below has shipped unless it's listed under `[Unreleased]` in [CHANGELOG.md](../CHANGELOG.md).

0.6.0 makes PF Terminal safer to trust with a real ledger. Data must never be lost or reverted silently. When something goes wrong, you can see it and recover from it. No redesign and no new analytics: those move to 0.7.

## Must-have

1. **CloudKit sync hardening.** Started on `fix/sync-hardening`.
   - Record-level merge, with change tags and monotonic edit stamps.
   - A stale remote record or tombstone never wins over newer data.
   - A pre-sync local copy never overrides iCloud or resurrects a delete.
   - A replaced or empty local document is recovered from iCloud instead of being tombstoned.
   - Serialized passes. Sync stops cleanly when it is turned off mid-pass. A missing zone stops sync.
   - Still to do: a two-Mac soak test against the CloudKit **Development** environment, and the change-token-expiry path exercised against real CloudKit.
2. **Data integrity and recovery.**
   - Rolling automatic local snapshots of `portfolio.json` (last N days), plus restore from Settings.
   - An integrity check at launch: orphans, duplicates, oversold positions, and records left blocked by sync. Findings are reported, never auto-deleted.
   - Restoring the "before iCloud" backups that `USE ICLOUD` already writes.
3. **Sync observability.**
   - The status bar indicator (synced, syncing, offline, review, sync error) is done on the branch.
   - Settings gains: last successful sync, pending count, last error with its time, and the last device that changed data.
   - A clear explanation when sync stops itself (account changed, iCloud data deleted).
4. **Diagnostics report without sensitive data.**
   - One-click text report: app and macOS versions, settings flags, sync state counters, provider and feed health, and registry version.
   - No amounts, holdings, ids, addresses, names or keys. A unit test enforces the redaction.

## Nice-to-have

- **Market-source health and failover polish.** Per-source health in Settings (last success, backoff, 429s). Faster live-feed failover. Clearer `NO PRICE` reasons.
- **Stablecoin and depeg UX.** A depeg notification (opt-in). A depeg history marker on the peg panel. Non-USD pegs stay out of scope.
- **Registry overlay update strategy.**
  - A signed or checksummed overlay fetched at most every 5 days from a fixed GitHub URL.
  - Validated against the bundled schema, with rollback to the bundled snapshot.
  - Still off by default until it has been reviewed.
- **Backup, export and import.**
  - Import into the current ledger as a merge, with a preview of changes.
  - Export of a single portfolio.
  - Import while sync is on, with a clear summary of what will sync.
- **Performance for larger portfolios.**
  - Measure and fix recompute, snapshot and sync costs at 10k+ transactions.
  - Incremental hashing in sync change detection.
- **Small UX polish.** Remove a position from the right-click menu, with confirmation (requested earlier and not done yet).

## Deferred (not 0.6)

- Advanced analytics (benchmarks, period tables, realized P&L reports) moves to 0.7, along with the scenario lab.
- Wallets, exchange APIs and CSV import (0.9).
- iPhone app releases follow their own version line. The PFCore sync changes are source-compatible, and the iPhone app picks them up when it is next built.
- Any change to the CloudKit schema. 0.6 keeps record type `PFRecord` and its fields as they are.

## Release criteria

- PFCore, Mac unit and Mac UI tests are green.
- The sync test matrix (see `PFCoreTests/SyncHardeningTests.swift`) is green.
- The two-Mac Development soak test passes.
- No Production CloudKit writes from automated tests.
- A notarized DMG passes the Gatekeeper check.
