# Security policy

## Supported versions

Security fixes go into the latest release.

| Version | Supported |
|---|---|
| 0.6.x | yes |
| 0.5.x and older | no · please update |

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report them privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. If that option is unavailable, open an issue that only asks for a private contact. Leave out any details.

Please include:
- the PF Terminal version and your macOS version;
- the steps to reproduce;
- the impact you expect.

Never include real balances, wallet addresses, API keys or portfolio exports.

## Scope

Examples of what counts as a security problem:
- portfolio data leaving the Mac other than through iCloud sync you turned on;
- market-data requests that carry quantities or values;
- secrets stored outside the Keychain;
- privacy-mode bypasses in share cards or widgets;
- portfolio data visible while the app lock is on, for example in the menu bar;
- portfolio data in the diagnostic report (Settings → DIAGNOSTICS);
- sandbox or entitlement problems.

PF Terminal has no server and no account system. It uses public market-data APIs (Binance, Bybit, CoinGecko, DexScreener), `api.github.com` when you check for updates, and, only when you turn sync on, your own private iCloud database.
