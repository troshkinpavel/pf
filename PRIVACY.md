# Privacy Policy

PF Terminal is designed to be local-first and privacy-focused.

## Data collection

PF Terminal does not collect, sell, track, or use personal data for advertising or analytics.

There is no PF Terminal account system and no PF Terminal backend server.

## Portfolio data

Portfolio data, transactions, settings, and related information are stored locally on your device.

If you enable iCloud sync, portfolio data is synchronized through your private Apple iCloud / CloudKit database.

PF Terminal does not operate a server that receives or stores your portfolio data.

PF Terminal keeps local recovery snapshots of your portfolio data next to it on your device, so you can restore an earlier state. They never sync and are not sent anywhere.

The portfolio ledger and recovery snapshots use macOS "complete" file protection: while the Mac is locked they can't be read or written, and PF Terminal waits for unlock instead of changing or syncing them.

## Watchlist, alerts and scenarios

Your watchlist (with its notes), alert rules and scenarios are stored locally on your device, on that Mac only; they are not synced and not sent anywhere. Watchlist and scenarios use the same "complete" protection as the ledger. Alert rules and their log use "until first unlock" protection so alerts can run from the menu bar while the Mac is locked; they hold no notes or scenario values.

Alerts are evaluated on your device. Alert notifications contain asset symbols, prices and percentages, never the amounts you hold.

## Market data

PF Terminal connects directly to third-party market-data services, including:

- Binance
- Bybit
- CoinGecko
- DexScreener

These requests are used only to retrieve market prices and related public market information.

PF Terminal does not intentionally send your portfolio balances, transaction history, or portfolio value to these services.

Third-party services may process network information such as your IP address according to their own privacy policies.

## Update checks

When you choose Check for Updates, PF Terminal asks GitHub (`api.github.com`) for the latest PF Terminal release. The request contains no portfolio data. GitHub may process network information such as your IP address according to its own privacy policy.

## Diagnostics

PF Terminal keeps a small local log of operational events, such as sync and market-data errors, to help with troubleshooting. You can copy a diagnostic report from Settings. It contains no portfolio names, values, quantities, transaction notes, API keys or account identifiers. It stays on your device unless you share it yourself.

## Biometric authentication

Face ID or Touch ID may be used to lock access to the app, depending on the device.

PF Terminal does not receive or store biometric data. Authentication is handled by the operating system.

On macOS, when the app lock is on, the menu bar shows no portfolio amounts while the app is locked. If the system can't authenticate, the app stays locked.

## Analytics and advertising

PF Terminal does not include:

- advertising SDKs
- tracking SDKs
- third-party analytics
- behavioral profiling

## API keys

API keys, when supported, are stored locally using the system Keychain and are not synchronized through PF Terminal.

## Contact

For privacy questions:

troshkinp@proton.me
