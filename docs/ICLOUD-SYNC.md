# iCloud sync

Back to the [README](../README.md).

iCloud sync keeps your portfolios in step across your own devices. It is **off by default**. Nothing is uploaded until you turn it on in **Settings → DATA & SYNC** and confirm.

- **Your iCloud, not ours.** Data goes to the **private** CloudKit database of the Apple Account signed in on your Mac. PF has no server and no account, and it cannot see your data. Transaction data is stored in CloudKit's encrypted fields.
- **What syncs.** Portfolios, transactions and asset identities; since 0.8.3 also your watchlist, alert rules and scenarios. Records are matched by stable IDs, so renaming a portfolio or importing the same backup twice never creates duplicates.
- **What never syncs.** Market prices and caches, charts and P&L (every device recalculates them), the alert history, widget data, settings, and API keys or anything else in the Keychain.
- **Watchlist, alerts and scenarios (0.8.3).** They follow the iCloud switch, in a separate area of your private database, so Macs on 0.8.2 and earlier keep working unchanged. The first sync on each device merges: preset scenarios that exist on both get a suffix (BASE 2), a coin watched on both stays once (the other entry is archived), duplicate alert numbers are renumbered, and the same migrated 0.6 alert becomes one. If the same rule, watch or scenario was edited on two devices before they synced, nothing is merged field by field: the header shows **! 1 conflict**, and you choose *keep this Mac* or *keep the other* (newer is the default, `⌘↵`); until then each device uses its own version. An alert that only fired or was seen on another device updates without asking. Deleting your last watch, alert or scenario deletes it everywhere; a file that went missing or couldn't be read is never taken as a deletion — PF fetches your records back from iCloud instead.
- **Turning it on.** PF first compares this Mac with iCloud, then asks what to do:
  - iCloud is empty → **upload**.
  - This Mac is empty → **use iCloud**.
  - Both have data → **merge** or **use iCloud**. Before replacing anything, PF saves a backup of this Mac's ledger (a verified recovery snapshot).
- **Offline.** Changes are saved locally first and queued. They upload when iCloud is reachable again, even after a restart.
- **Conflicts.** Sometimes the same transaction changes on two devices before they sync. PF keeps the newer edit, and an edit always wins over a delete. The other version stays in **Settings → DATA & SYNC → conflicts**, where you can restore it.
- **Protection against stale data**:
  - A copy that was never synced (for example, a restored backup or an old Mac) never overrides what is in iCloud, and never brings back something deleted.
  - An older version arriving from another device never replaces a newer one.
  - If this Mac's ledger is reset or unreadable while sync is on, PF fetches your portfolios back from iCloud instead of deleting them there.
- **Turning it off.** Your portfolios stay on your Mac, and the iCloud copy is not deleted. If you turn sync on again later, PF compares both sides again first.
- **Availability.** iCloud sync ships in v0.4.0 and is off by default. It needs macOS 14 or later and an Apple Account signed in to iCloud. If you build from source, sync needs a build signed with the iCloud capability (see [docs/DEVELOPMENT.md](DEVELOPMENT.md#icloud-sync-optional)). [PF Terminal for iPhone](https://apps.apple.com/us/app/pf-terminal/id6817097908) (iOS 17 or later) uses the same sync and the same private database: turn sync on on both devices with the same Apple Account. On iPhone the setting is in **Settings → DATA & SYNC** too.
- **Validation.**
  - The sync engine has automated tests against a simulated CloudKit store.
  - The full flow was also checked between two independent PF stores, in both CloudKit's development and production environments. It covered upload and download, edits, renames, archiving, deletes, the offline queue across a restart, conflicts and restore, and turning sync off and on again.
  - The notarized v0.4.0 release app was checked against production CloudKit.
