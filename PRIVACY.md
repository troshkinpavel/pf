# Privacy Policy

PF Terminal is designed to be local-first and privacy-focused.

This policy covers PF Terminal for macOS and PF Terminal for iPhone ([App Store](https://apps.apple.com/us/app/pf-terminal/id6817097908)). Where a section applies to one app only, it says so.

## Data collection

PF Terminal does not collect, sell, track, or use personal data for advertising or analytics.

There is no PF Terminal account system and no PF Terminal backend server.

## Portfolio data

Portfolio data, transactions, settings, and related information are stored locally on your device, on your Mac and on your iPhone.

iCloud sync is optional and off until you turn it on. If you enable it, portfolio data is synchronized between your own devices through your private Apple iCloud / CloudKit database.

PF Terminal does not operate a server that receives or stores your portfolio data.

PF Terminal keeps local recovery snapshots of your portfolio data next to it on your device, so you can restore an earlier state. They never sync and are not sent anywhere.

On macOS, the portfolio ledger and recovery snapshots use "complete" file protection: while the Mac is locked they can't be read or written, and PF Terminal waits for unlock instead of changing or syncing them.

## Watchlist, alerts and scenarios (macOS)

Your watchlist (with its notes), alert rules and scenarios are stored locally on your device, on that Mac only; they are not synced and not sent anywhere. Watchlist and scenarios use the same "complete" protection as the ledger. Alert rules and their log use "until first unlock" protection so alerts can run from the menu bar while the Mac is locked; they hold no notes or scenario values.

Alerts are evaluated on your device. Alert notifications contain asset symbols, prices and percentages, never the amounts you hold.

## AI agents (MCP, macOS)

PF Terminal for macOS 0.8 and later can give an AI agent you choose access to your portfolio through the Model Context Protocol. It is off by default and you turn it on in Settings.

- PF Terminal does not contain an AI model and does not send your portfolio to any PF server; there is none.
- While on, an MCP client on your Mac can read what you expose (exact values, notes and transaction history are off by default) and, if you allow writes, propose changes that you confirm in PF Terminal.
- If the agent you connect is a cloud service, the data it reads from PF is processed by that service's provider under its own privacy terms. PF Terminal can't control that; expose only what you're comfortable sharing with it.
- PF Terminal keeps a local activity log of agent requests (tool, time, result). It contains no notes, amounts or credentials, holds at most 500 entries and can be cleared.
- The connection credential is stored in the Keychain and in your MCP client's configuration.

## Market data

PF Terminal connects directly from your device to third-party market-data services, including:

- Binance
- Bybit
- CoinGecko
- DexScreener

These requests are used only to retrieve market prices and related public market information.

PF Terminal does not intentionally send your portfolio balances, transaction history, or portfolio value to these services.

Third-party services may process network information such as your IP address according to their own privacy policies.

On iPhone, if Background App Refresh is on, iOS may let PF Terminal refresh these prices in the background to update its widgets. That refresh uses the same market-data requests and never contacts iCloud.

## Widgets

Widgets read a snapshot that the PF Terminal app writes on your device. They don't connect to the network or to iCloud. On iPhone, widgets show percentages only unless you allow amounts in PF Terminal (separately for the Home Screen and the Lock Screen). On macOS, the widget privacy setting in PF Terminal controls whether amounts appear.

## Update checks (macOS)

When you choose Check for Updates, PF Terminal for macOS asks GitHub (`api.github.com`) for the latest PF Terminal release. The request contains no portfolio data. GitHub may process network information such as your IP address according to its own privacy policy.

On iPhone, updates come from the App Store; PF Terminal itself doesn't check for updates.

## Diagnostics (macOS)

PF Terminal for macOS keeps a small local log of operational events, such as sync and market-data errors, to help with troubleshooting. You can copy a diagnostic report from Settings. It contains no portfolio names, values, quantities, transaction notes, API keys or account identifiers. It stays on your device unless you share it yourself.

## Biometric authentication

Face ID or Touch ID may be used to lock access to the app, depending on the device.

PF Terminal does not receive or store biometric data. Authentication is handled by the operating system.

On macOS, when the app lock is on, the menu bar shows no portfolio amounts while the app is locked. If the system can't authenticate, the app stays locked.

On iPhone, Face ID lock is optional, and PF Terminal can hide its contents in the app switcher.

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
