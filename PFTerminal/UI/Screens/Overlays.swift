import PFCore
import PFCoreUI
import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        let q = store.palette?.query ?? ""
        let items = store.paletteItems(q)
        let sel = min(store.palette?.sel ?? 0, max(0, items.count - 1))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TT(">", 15, Theme.acc)
                TextField("type a command or search", text: Binding(get: { store.palette?.query ?? "" }, set: { store.palette = PaletteState(query: $0, sel: 0) }))
                    .textFieldStyle(.plain).font(Theme.mono(15)).foregroundStyle(Theme.t1).tint(Theme.acc)
                    .focused($focused)
                    .accessibilityIdentifier("palette-input")
                TT("\(items.count) results", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .overlay(alignment: .bottom) { Hairline() }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    Button(action: it.run) {
                        Columns([.fixed(22), .fr(1), .fixed(140)]) {
                            TT(i == sel ? "›" : "", 12, Theme.acc).frame(maxWidth: .infinity)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                TT(it.label, 12, it.isCommand || i == sel ? Theme.t1 : Theme.muted)
                                TT(it.detail, 11, Theme.t4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).clipped()
                            Cell(it.hint, Theme.t3, size: 11)
                        }
                        .padding(.leading, 6).padding(.trailing, 16)
                        .frame(height: 30)
                        .background(i == sel ? Theme.paletteSel : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0, store.palette?.sel != i { store.palette?.sel = i } }
                }
                if items.isEmpty { TT("no match · try: buy eth 0.5 @ 3500 · target eth 10k · share 24h", 11, Theme.t4).padding(12) }
            }
            .padding(.vertical, 6)
            .frame(maxHeight: 420, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                TT("↑↓ select · ↵ run · esc close", 11, Theme.t4)
                Spacer()
                TT("buy eth 0.5 @ 3500 · target eth 10k · movers · pnl", 11, Theme.t4)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: 700)
        .onAppear { focused = true }
    }
}

struct TransactionSheet: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focus: Field?
    enum Field { case asset, amount, price, date, fee, note }

    var body: some View {
        let d = store.tx ?? TxDraft()
        let p = store.preview(d)
        VStack(spacing: 0) {
            HStack {
                TT(d.editing == nil ? "ADD TRANSACTION" : "EDIT TRANSACTION", 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT("tab next · ↵ confirm · esc cancel", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }

            VStack(alignment: .leading, spacing: 12) {
                row("type") {
                    Tabs(items: TransactionType.allCases.map { TabItem(id: $0.rawValue, label: $0.short) }, selected: d.type.rawValue, hPad: 12, vPad: 3) {
                        store.tx?.type = TransactionType(rawValue: $0)!
                    }
                }
                row("portfolio") {
                    // ALL owns no transactions: a concrete destination is always required.
                    Tabs(items: store.doc.livePortfolios.map { TabItem(id: $0.id.uuidString, label: $0.glyph + " " + $0.name.lowercased()) },
                         selected: d.portfolioID?.uuidString ?? "") { id in store.tx?.portfolioID = UUID(uuidString: id) }
                }
                row("asset") {
                    HStack(spacing: 10) {
                        prompt
                        field("", \.asset, .asset, width: 120, upper: true)
                        TT(p.assetHint, 12, p.assetHintError ? Theme.neg : Theme.t3)
                    }
                }
                if !d.searchResults.isEmpty, store.resolveAsset(d.asset) == nil || d.searchResults.count > 1,
                   AssetCatalog.resolve(d.asset, in: store.doc.assets + AssetCatalog.known) == nil {
                    candidates(d)
                }
                row("amount") { HStack(spacing: 10) { prompt; field("0.5 · 1.2k", \.amount, .amount) } }
                row(d.type == .transferIn || d.type == .transferOut ? "cost/unit" : "price") { HStack(spacing: 10) { prompt; field(p.pricePlaceholder, \.price, .price) } }
                row("date") { HStack(spacing: 10) { prompt; field("YYYY-MM-DD", \.date, .date) } }
                row("fee") { HStack(spacing: 10) { prompt; field("optional", \.fee, .fee) } }
                row("note") { HStack(spacing: 10) { prompt; field("optional", \.note, .note) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 6) {
                TT(p.line, 13, Theme.t1)
                ForEach(p.rows) { r in
                    HStack { TT(r.k, 12, Theme.t3); Spacer(); TT(r.v, 12, r.c) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(Theme.overlayBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .padding(.horizontal, 16)
            .accessibilityIdentifier("tx-preview")

            HStack {
                BracketButton("cancel", color: Theme.t2) { store.tx = nil }
                if let id = d.editing, let t = store.doc.transactions.first(where: { $0.id == id }) {
                    BracketButton("delete", color: Theme.neg) { store.tx = nil; store.requestDelete(t) }
                }
                Spacer()
                BracketButton(d.editing == nil ? "confirm transaction ↵" : "save changes ↵", color: p.ok ? Theme.acc : Theme.faint) { store.confirmTx() }
                    .disabled(!p.ok)
                    .accessibilityIdentifier("tx-confirm")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(width: 580)
        .onAppear { focus = d.asset.isEmpty ? .asset : (d.amount.isEmpty ? .amount : .price) }
        .onChange(of: "\(d.type.rawValue)|\(d.date)|\(p.asset?.id ?? "")|\(d.price.isEmpty)") { store.loadDraftHistoricalPrice() }
    }

    private var prompt: some View { TT(">", 12, Theme.acc) }

    /// Search matches with live prices: listed coins first; thin DEX pools flagged.
    private func candidates(_ d: TxDraft) -> some View {
        let f = Fmt.current
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(d.searchResults.prefix(5).enumerated()), id: \.element.id) { i, a in
                let q = d.candidateQuotes[a.id]
                let thin = q.map { ($0.volume24h ?? 0) < lowLiquidityVolume } ?? false
                TermButton(action: { store.tx?.pick = i }) {
                    Columns([.fixed(16), .fixed(92), .fr(1), .fixed(92), .fixed(78)]) {
                        TT(i == d.pick ? "›" : "", 12, Theme.acc)
                        if let e = AssetRegistry.shared.entry(for: a) {
                            // Registry asset: ticker, name, rank, verified sources.
                            TT(e.symbol, 11, i == d.pick ? Theme.t1 : Theme.t3)
                            TT(e.name.lowercased() + (e.marketCapRank.map { " · #\($0)" } ?? "") + " · "
                               + MarketMappings.availableSources(a).map(\.label).joined(separator: " "), 11, Theme.t4)
                        } else {
                            TT(a.coingeckoID != nil ? "coingecko" : "dex · " + (a.chain ?? ""), 11, i == d.pick ? Theme.t1 : Theme.t3)
                            TT(a.name.lowercased() + " · " + (a.coingeckoID ?? AppStore.short(a.contractAddress)), 11, Theme.t4)
                        }
                        Cell(q.map { f.price($0.price) } ?? "…", Theme.text, size: 11)
                        Cell(q.map { "vol " + f.compact($0.volume24h) } ?? "", thin ? Theme.neg : Theme.t4, size: 11)
                    }
                    .frame(height: 20)
                }
            }
            TT("↑↓ choose · registry matches are instant and offline · red = thin liquidity", 10.5, Theme.t4).padding(.top, 2)
        }
        .padding(.leading, 90)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 0) { TT(label, 12, Theme.t3).frame(width: 90, alignment: .leading); c() }
    }

    private func field(_ placeholder: String, _ kp: WritableKeyPath<TxDraft, String>, _ f: Field, width: CGFloat? = nil, upper: Bool = false) -> some View {
        TextField(placeholder, text: Binding(
            get: { store.tx?[keyPath: kp] ?? "" },
            set: { v in
                store.tx?[keyPath: kp] = upper ? v.uppercased() : v
                if f == .asset { store.draftAssetChanged() }
            }))
            .textFieldStyle(.plain).font(Theme.mono(13)).foregroundStyle(Theme.t1).tint(Theme.acc)
            .focused($focus, equals: f)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : width)
            .accessibilityIdentifier("tx-\(f)")
    }
}

struct OnboardingView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                PFGlyph(size: 20)
                TT("portfolio terminal for macOS", 12, Theme.t3)
            }
            VStack(alignment: .leading, spacing: 6) {
                TT("local-first · no account · no telemetry · nothing leaves this Mac except market-data requests", 12, Theme.t2)
                TT("transactions are the source of truth; holdings and P&L are derived from them.", 12, Theme.t3)
            }
            Panel(title: "START", padding: .init(top: 16, leading: 8, bottom: 8, trailing: 8)) {
                VStack(alignment: .leading, spacing: 0) {
                    option("1", "create empty portfolio", "start from scratch · add transactions with ⌘N or ⌘K", accent: true) { store.createEmpty() }
                    option("2", "load demo portfolio", "sample ledger from the design · marked DEMO · removable any time") { store.loadDemo() }
                    option("3", "import backup…", "restore a pf .json export · validated before anything is replaced") { store.importBackup() }
                }
            }
            .frame(maxWidth: 760)
            TT("data: \(store.displayPath)", 11, Theme.t4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 40).padding(.leading, 40)
        .accessibilityIdentifier("onboarding")
    }

    private func option(_ key: String, _ label: String, _ detail: String, accent: Bool = false, _ a: @escaping () -> Void) -> some View {
        TermButton(action: a, hoverBg: Theme.selected) {
            Columns([.fixed(36), .fixed(250), .fr(1)]) {
                Kbd(key)
                TT("[ \(label) ]", 12, accent ? Theme.acc : Theme.text)
                TT(detail, 11, Theme.t4)
            }
            .padding(.horizontal, 8).frame(height: 32)
        }
        .accessibilityIdentifier("onboarding-\(key)")
    }
}

struct LockView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        ZStack {
            Theme.bg
            VStack(spacing: 14) {
                PFGlyph(size: 28, color: Theme.t3)
                TT("LOCKED", 12, Theme.t2, tracking: 1.2)
                if let e = store.lockError {
                    // Fail closed: without a way to authenticate, the portfolio stays hidden.
                    TT("can't unlock: \(e)", 11, Theme.neg).multilineTextAlignment(.center).frame(maxWidth: 460)
                    TT("set a login password or Touch ID in System Settings, then try again", 11, Theme.t3)
                    HStack(spacing: 18) {
                        BracketButton("try again", color: Theme.acc) { store.unlock() }
                        BracketButton("quit", color: Theme.t2) { NSApp.terminate(nil) }
                    }
                } else {
                    BracketButton("unlock with Touch ID", color: Theme.acc) { store.unlock() }
                }
            }
        }
        .onAppear { store.unlock() }
    }
}
