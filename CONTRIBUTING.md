# Contributing

Thanks for your interest in PF Terminal.

- **Security problems:** see [SECURITY.md](SECURITY.md). Don't open a public issue.
- **Bugs and feature requests:** open a GitHub issue. For bugs, include your macOS version, the steps to reproduce and what you expected. Never include real balances, addresses or API keys.
- **Pull requests:** keep them focused. Match the existing style: a platform-neutral `PFCore/` (no AppKit/SwiftUI), no third-party dependencies, terminal-style UI. Add tests for any logic change.

```bash
xcodebuild -project PFTerminal.xcodeproj -scheme PFTerminal test -only-testing:PFTerminalTests
```

Architecture, signing (App Groups for widgets), the data formats and how to add a market-data provider are described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Changes must keep the core principles intact:
- portfolio data stays local;
- no telemetry;
- nothing is written to the ledger without explicit confirmation;
- privacy modes remove data from the model, not just from the view.
