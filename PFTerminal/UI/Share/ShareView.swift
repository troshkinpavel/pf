import SwiftUI

extension ShareConfig.Level {
    var color: Color { switch self { case .safe: Theme.pos; case .semi: Theme.acc; case .sensitive: Theme.neg } }
    func label(_ c: ShareConfig) -> String {
        switch self {
        case .safe: "SAFE TO SHARE"
        case .semi: "SHOWS " + (c.fields.contains(.value) ? "PORTFOLIO VALUE" : c.fields.contains(.alloc) ? "ALLOCATION" : "PORTFOLIO NAME") + " · no holdings"
        case .sensitive: "REVEALS POSITION DATA — review before sharing"
        }
    }
    var short: String { switch self { case .safe: "safe to share"; case .semi: "shows value"; case .sensitive: "reveals position data" } }
}

struct ShareView: View {
    @Environment(AppStore.self) private var store
    @State private var anchor: NSView?

    var body: some View {
        let sh = store.share
        let model = store.shareModel(sh)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    TT("SHARE", 15, Theme.t1, weight: .semibold, tracking: 0.6)
                    TT("rendered locally · nothing leaves this Mac until you copy or export", 12, Theme.t3)
                }
                Spacer()
                HStack(spacing: 0) { TT("privacy / ", 12, Theme.t3); TT(sh.privacy.label, 12, sh.level.color) }
            }
            .padding(.bottom, 14).overlay(alignment: .bottom) { Hairline() }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    configure(sh)
                    privacyCheck(sh)
                    HStack(spacing: 4) {
                        BracketButton("copy image ⌘C", color: Theme.acc) { store.copyImage() }
                        BracketButton("save png ⌘S") { store.saveImage() }
                        BracketButton("share…") { store.shareVia(anchor: anchor) }
                            .background(ViewAnchor { anchor = $0 })
                        TT(store.flash, 12, Theme.pos).padding(.leading, 6)
                    }
                }
                .frame(width: 410)

                GeometryReader { geo in
                    let size = sh.format.size
                    let z = min((geo.size.width - 40) / CGFloat(size.w), (geo.size.height - 50) / CGFloat(size.h), 1)
                    VStack(spacing: 12) {
                        ShareCardView(m: model)
                            .scaleEffect(z, anchor: .topLeading)
                            .frame(width: CGFloat(size.w) * z, height: CGFloat(size.h) * z, alignment: .topLeading)
                            .accessibilityIdentifier("share-card-preview")
                        TT("\(size.w) × \(size.h) · png · \(sh.theme.rawValue)", 11, Theme.t4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(hex: 0x0a0b0c))
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 2)
        .onAppear { store.prepareShare() }
        .onChange(of: store.share.period) { store.prepareShare() }
    }

    private func label(_ s: String) -> some View { TT(s, 12, Theme.t3).frame(width: 78, alignment: .leading) }

    private func configure(_ sh: ShareConfig) -> some View {
        Panel(title: "CONFIGURE") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    label("source")
                    Tabs(items: store.doc.livePortfolios.map { TabItem(id: $0.id.uuidString, label: $0.name.lowercased()) } + [TabItem(id: "all", label: "all")],
                         selected: store.shareContext(sh).storageKey, hPad: 7) { store.share.source = $0 }
                }
                HStack(alignment: .top, spacing: 0) {
                    label("period")
                    Tabs(ShareConfig.periods.map(\.rawValue), selected: sh.period.rawValue) { store.share.period = ChartRange(rawValue: $0)! }
                }
                HStack(alignment: .top, spacing: 0) {
                    label("privacy")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach([(SharePrivacy.public, "% · chart · movers"), (.value, "+ total value"), (.custom, "pick fields")], id: \.0) { p, d in
                            let on = sh.privacy == p
                            TermButton(action: { store.setPrivacy(p) }) {
                                Columns([.fixed(16), .fixed(110), .fr(1)]) {
                                    TT(on ? "●" : "○", 12, on ? Theme.acc : Theme.t3)
                                    TT(p.label, 12, on ? Theme.t1 : Theme.t2)
                                    TT(d, 11, Theme.t4)
                                }
                                .frame(height: 20)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    label("content")
                    let fl = sh.fields
                    Columns([.fr(1), .fr(1)]) {
                        VStack(alignment: .leading, spacing: 0) { ForEach([ShareField.name, .pct, .chart, .alloc, .avg], id: \.self) { toggle($0, fl) } }
                        VStack(alignment: .leading, spacing: 0) { ForEach([ShareField.value, .pnl, .movers, .posv], id: \.self) { toggle($0, fl) } }
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    label("movers")
                    VStack(alignment: .leading, spacing: 6) {
                        Tabs(["1", "2", "3", "4", "5"], selected: String(sh.moverCount), hPad: 7) { store.share.moverCount = Int($0)! }
                        Tabs(items: [TabItem(id: "gainers", label: "top gainers"), TabItem(id: "impact", label: "portfolio impact")], selected: sh.moverType.rawValue) {
                            store.share.moverType = MoverType(rawValue: $0)!
                        }
                    }
                }
                HStack(spacing: 0) {
                    label("format")
                    Tabs(ShareFormat.allCases.map(\.rawValue), selected: sh.format.rawValue) { store.share.format = ShareFormat(rawValue: $0)! }
                }
                HStack(spacing: 0) {
                    label("theme")
                    Tabs(ShareTheme.allCases.map(\.rawValue), selected: sh.theme.rawValue) { store.share.theme = ShareTheme(rawValue: $0)! }
                }
                HStack(spacing: 0) {
                    label("signature")
                    TermButton(action: { store.share.brand.toggle() }) {
                        TT((sh.brand ? "[x] " : "[ ] ") + "PF glyph, bottom right", 11.5, sh.brand ? Theme.t1 : Theme.t3)
                    }
                }
            }
        }
    }

    private func toggle(_ f: ShareField, _ fl: Set<ShareField>) -> some View {
        let on = fl.contains(f)
        return TermButton(action: { store.toggleField(f) }) {
            TT((on ? "[x] " : "[ ] ") + f.label, 11.5, on ? (f.isSensitive || f.isSemiSensitive ? Theme.acc : Theme.t1) : Theme.t3)
                .frame(height: 20, alignment: .leading)
        }
    }

    private func privacyCheck(_ sh: ShareConfig) -> some View {
        let chk = ShareCardBuilder.privacyCheck(sh)
        return Panel(title: "PRIVACY CHECK") {
            VStack(alignment: .leading, spacing: 10) {
                Columns([.fr(1), .fr(1)], spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        TT("visible", 11.5, Theme.t3).padding(.bottom, 3)
                        ForEach(chk.visible, id: \.self) { TT($0, 11.5, Theme.text) }
                    }.frame(maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 3) {
                        TT("hidden", 11.5, Theme.t3).padding(.bottom, 3)
                        ForEach(chk.hidden, id: \.self) { TT($0, 11.5, Theme.t3) }
                    }.frame(maxHeight: .infinity, alignment: .top)
                }
                HStack(spacing: 8) { TT("●", 12, sh.level.color); TT(sh.level.label(sh), 12, sh.level.color, tracking: 0.7) }
                    .padding(.top, 9).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
            }
        }
    }
}

struct QuickShareView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let sh = store.share
        let z: CGFloat = { switch sh.format { case .square: 0.42; case .landscape: 0.5; case .portrait: 0.36 } }()
        let size = sh.format.size
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                TT("QUICK SHARE", 12, Theme.t1, tracking: 0.72)
                Spacer()
                HStack(spacing: 0) { TT(store.doc.displayName(store.shareContext(sh)).lowercased() + " · " + sh.summary + " · ", 11, Theme.t3); TT(sh.level.short, 11, sh.level.color) }.fixedSize()
            }
            .padding(.horizontal, 14).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            ShareCardView(m: store.shareModel(sh))
                .scaleEffect(z, anchor: .topLeading)
                .frame(width: CGFloat(size.w) * z, height: CGFloat(size.h) * z, alignment: .topLeading)
                .padding(14)
            HStack(spacing: 20) {
                TT("⌘C copy image · ↵ customize · esc close", 11, Theme.t2)
                Spacer()
                TT(store.flash, 11, Theme.pos)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: CGFloat(size.w) * z + 28)
        .accessibilityIdentifier("quick-share")
        .onAppear { store.prepareShare() }
    }
}
