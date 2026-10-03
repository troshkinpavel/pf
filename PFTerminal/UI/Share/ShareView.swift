import PFCore
import PFCoreUI
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

extension ShareField {
    /// Mac editor labels: short enough for two columns (design §16). PFCore keeps the long ones.
    var short: String {
        switch self {
        case .name: "name"; case .value: "value"; case .pct: "% change"; case .pnl: "$ p&l"; case .chart: "chart"
        case .movers: "movers"; case .alloc: "allocation"; case .posv: "positions"; case .avg: "entries"
        case .contrib: "contributors"; case .flows: "flows note"; case .drift: "alloc drift"; case .impact: "$ impact"
        }
    }
}

extension ShareTheme {
    var short: String { self == .monochrome ? "mono" : rawValue }
}

/// One effect, small: a swatch under the preview (design §16) — click to pick.
struct ShareEffectSwatch: View {
    let effect: ShareEffect
    let theme: ShareTheme
    let text: String
    let on: Bool
    let pick: () -> Void
    var body: some View {
        let p = ShareCardView.palette(theme)
        TermButton(action: pick) {
            VStack(spacing: 6) {
                ZStack {
                    p.bg
                    Text(text).font(Theme.mono(12, .medium)).foregroundStyle(p.pos).modifier(ShareGlow(effect: effect, color: p.fg))
                    ShareEffectLayer(effect: effect, light: theme == .monochrome)
                }
                .frame(width: 78, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: effect == .crt ? 6 : 0))
                .overlay(Rectangle().strokeBorder(on ? Theme.acc : Theme.border, lineWidth: 1))
                TT(effect.rawValue, 11, on ? Theme.t1 : Theme.t3)
            }
        }
        .accessibilityIdentifier("share-effect-" + effect.rawValue)
    }
}

struct ShareView: View {
    @Environment(AppStore.self) private var store
    @State private var anchor: NSView?

    var body: some View {
        let sh = store.share
        let model = store.shareModel(sh)
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "SHARE", sub: "rendered locally · nothing leaves this Mac until you copy or export") {
                HStack(spacing: 0) { TT("privacy / ", 12, Theme.t3); TT(sh.privacy.label, 12, sh.level.color) }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    // Scrolls inside the window: a long custom field list must never grow the window.
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 18) {
                            cardPanel(sh)
                            whoPanel(sh)
                            lookPanel(sh)
                            // Right under the panels (design §16), not pinned to the window bottom.
                            HStack(spacing: 4) {
                                BracketButton(sh.motion == .animated ? "copy \(sh.motionFormat.rawValue) ⌘C" : "copy image ⌘C", color: Theme.acc) { store.copyImage() }
                                BracketButton(sh.motion == .animated ? "save \(sh.motionFormat.rawValue) ⌘S" : "save png ⌘S") { store.saveImage() }
                                BracketButton("share…") { store.shareVia(anchor: anchor) }
                                    .background(ViewAnchor { anchor = $0 })
                            }
                            TT(store.flash, 12, Theme.pos)
                        }
                        .padding(.top, 8)       // panel titles sit on the top border; keep them inside the scroll clip
                        .frame(width: 410, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .padding(.top, -8)
                }
                .frame(width: 410)
                .frame(maxHeight: .infinity, alignment: .top)

                GeometryReader { geo in
                    let size = sh.format.size
                    // About a third, like the design; smaller when the window is; the two caption
                    // lines always have room.
                    let z = min((geo.size.width - 40) / CGFloat(size.w), (geo.size.height - 190) / CGFloat(size.h), 0.4)
                    VStack(spacing: 12) {
                        Group {
                            if sh.motion == .animated {
                                // Loops the 3 s animation, as exported (glitch bursts included). Still = the
                                // exact still frame the PNG gets, nothing animating.
                                TimelineView(.animation) { tl in
                                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: ShareCardView.motionDuration)
                                    ShareCardView(m: model, progress: ShareCardView.motionProgress(at: t), time: t)
                                }
                            } else {
                                ShareCardView(m: model)
                            }
                        }
                        .scaleEffect(z, anchor: .topLeading)
                        .frame(width: CGFloat(size.w) * z, height: CGFloat(size.h) * z, alignment: .topLeading)
                        .accessibilityIdentifier("share-card-preview")
                        TT(sh.card.label + " · " + sh.privacy.label + (sh.effect == .none ? "" : " · effect " + sh.effect.rawValue), 11, Theme.t3)
                        HStack(spacing: 10) {
                            ForEach(ShareEffect.allCases, id: \.self) { e in
                                ShareEffectSwatch(effect: e, theme: sh.theme, text: model.pct ?? "+0.0%", on: sh.effect == e) { store.share.effect = e }
                            }
                        }
                        let out = sh.motion == .animated ? ShareMotionExporter.outputSize(model, sh.motionFormat) : size
                        TT("\(out.w) × \(out.h) · " + (sh.motion == .animated ? "\(sh.motionFormat.rawValue) · 3s" : "png") + " · \(sh.theme.short) · shown at " + String(format: "%.2f×", z), 11, Theme.t4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Theme.well)
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 2)
        .onAppear { store.prepareShare() }
        .onChange(of: store.share.period) { store.prepareShare() }
        .onChange(of: store.share.source) { store.prepareShare() }
    }

    private func label(_ s: String) -> some View { TT(s, 12, Theme.t3).frame(width: 78, alignment: .leading) }

    // MARK: 1 · card

    private func cardPanel(_ sh: ShareConfig) -> some View {
        Panel(title: "1 · CARD") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    label("card")
                    Tabs(items: ShareCardKind.allCases.map { TabItem(id: $0.rawValue, label: $0.label) }, selected: sh.card.rawValue, hPad: 7) {
                        store.setShareCard(ShareCardKind(rawValue: $0)!)
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    label("source")
                    // Many portfolios: the tabs scroll sideways instead of widening the column.
                    ScrollView(.horizontal) {
                        Tabs(items: store.doc.livePortfolios.map { TabItem(id: $0.id.uuidString, label: $0.name.lowercased()) } + [TabItem(id: "all", label: "all")],
                             selected: store.shareContext(sh).storageKey, hPad: 7) { store.share.source = $0 }
                    }
                    .scrollIndicators(.never)
                }
                HStack(alignment: .top, spacing: 0) {
                    label("period")
                    switch sh.card {
                    case .performance:
                        Tabs(ShareConfig.periods.map(\.rawValue), selected: sh.period.rawValue) { store.share.period = ChartRange(rawValue: $0)! }
                    case .changes:   // What Changed: today · 7d · 30d
                        Tabs([ChartRange.h24, .d7, .d30].map(\.rawValue), selected: sh.period.rawValue) { store.share.period = ChartRange(rawValue: $0)! }
                    case .benchmark:
                        Tabs(Benchmark.Range.allCases.map(\.rawValue), selected: sh.benchRange) { store.share.benchRange = $0; store.prepareShare() }
                    }
                }
                switch sh.card {
                case .changes:
                    HStack(spacing: 0) {
                        label("rows")
                        Tabs(["3", "4", "5"], selected: String(sh.moverCount), hPad: 7) { store.share.moverCount = Int($0)! }
                        TT("by impact", 11, Theme.t4).padding(.leading, 10)
                    }
                case .benchmark:
                    HStack(spacing: 0) {
                        label("headline")
                        Tabs(["BTC", "ETH"], selected: sh.benchVs) { store.share.benchVs = $0 }
                        TT("pp vs", 11, Theme.t4).padding(.leading, 10)
                    }
                case .performance:
                    HStack(alignment: .top, spacing: 0) {
                        label("movers")
                        VStack(alignment: .leading, spacing: 6) {
                            Tabs(["1", "2", "3", "4", "5"], selected: String(sh.moverCount), hPad: 7) { store.share.moverCount = Int($0)! }
                            Tabs(items: [TabItem(id: "gainers", label: "top gainers"), TabItem(id: "impact", label: "portfolio impact")], selected: sh.moverType.rawValue) {
                                store.share.moverType = MoverType(rawValue: $0)!
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 2 · who sees what (privacy + content + check in one list)

    private func whoPanel(_ sh: ShareConfig) -> some View {
        let rows = store.shareRows(sh)
        return Panel(title: "2 · WHO SEES WHAT") {
            VStack(alignment: .leading, spacing: 10) {
                Tabs(items: SharePrivacy.allCases.map { TabItem(id: $0.rawValue, label: (sh.privacy == $0 ? "● " : "") + $0.label) }, selected: sh.privacy.rawValue, hPad: 9) {
                    store.setPrivacy(SharePrivacy(rawValue: $0)!)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.label) { r in
                        TermButton(action: { if !r.fields.isEmpty { store.toggleFields(r.fields) } }, hoverBg: r.fields.isEmpty ? .clear : Theme.hover) {
                            HStack(spacing: 10) {
                                TT(r.on ? "[x]" : "[ ]", 12, r.on ? Theme.acc : Theme.t4)
                                TT(r.label, 12, r.on ? Theme.t1 : Theme.t3).lineLimit(1)
                                Spacer(minLength: 8)
                                TT(r.status, 11, r.on ? Theme.pos : Theme.t4).fixedSize()
                            }
                            .frame(height: 24)
                        }
                    }
                    TT("+ \(AppStore.neverShown.count) never shown: " + AppStore.neverShown.prefix(3).joined(separator: ", ") + "…", 11, Theme.t4)
                        .padding(.leading, 34).padding(.top, 4).lineLimit(1)
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
                if let note = store.shareNote(sh) { TT(note, 11, Theme.warning).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    TT("●", 12, sh.level.color); TT(sh.level.label(sh), 12, sh.level.color, tracking: 0.7)
                    Spacer(minLength: 8)
                    TT(store.shareSummaryNote(sh), 11, Theme.t3).fixedSize()
                }
                .padding(.top, 9).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.innerBorder).frame(height: 1) }
            }
        }
    }

    // MARK: 3 · look

    private func lookPanel(_ sh: ShareConfig) -> some View {
        Panel(title: "3 · LOOK") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    label("format")
                    Tabs(ShareFormat.mac.map(\.rawValue), selected: sh.format.rawValue) { store.share.format = ShareFormat(rawValue: $0)! }
                }
                HStack(spacing: 0) {
                    label("theme")
                    Tabs(items: ShareTheme.allCases.map { TabItem(id: $0.rawValue, label: $0.short) }, selected: sh.theme.rawValue) {
                        store.share.theme = ShareTheme(rawValue: $0)!
                    }
                }
                HStack(spacing: 0) {
                    label("effect")
                    Tabs(ShareEffect.allCases.map(\.rawValue), selected: sh.effect.rawValue, hPad: 7) { store.share.effect = ShareEffect(rawValue: $0)! }
                }
                HStack(spacing: 0) {
                    label("motion")
                    Tabs(ShareMotion.allCases.map(\.rawValue), selected: sh.motion.rawValue, hPad: 7) { store.share.motion = ShareMotion(rawValue: $0)! }
                    if sh.motion == .animated {
                        TT("3s ·", 11, Theme.t4).padding(.leading, 10).padding(.trailing, 4)
                        Tabs(ShareMotionFormat.allCases.map(\.rawValue), selected: sh.motionFormat.rawValue, hPad: 7) { store.share.motionFormat = ShareMotionFormat(rawValue: $0)! }
                    }
                }
                if sh.motion == .animated {
                    HStack(spacing: 0) {
                        label("style")
                        Tabs(items: ShareMotionStyle.allCases.map { TabItem(id: $0.rawValue, label: $0.label) }, selected: sh.motionStyle.rawValue, hPad: 7) {
                            store.share.motionStyle = ShareMotionStyle(rawValue: $0)!
                        }
                    }
                }
                HStack(spacing: 0) {
                    label("sign")
                    TermButton(action: { store.share.brand.toggle() }) {
                        HStack(spacing: 8) {
                            TT(sh.brand ? "[x]" : "[ ]", 12, sh.brand ? Theme.acc : Theme.t4)
                            TT("PF glyph, bottom right", 12, sh.brand ? Theme.t1 : Theme.t3)
                        }
                    }
                }
            }
        }
    }
}

struct QuickShareView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let sh = store.share
        let z: CGFloat = { switch sh.format { case .square: 0.42; case .landscape: 0.5; case .portrait: 0.36; case .story: 0.26 } }()
        let size = sh.format.size
        VStack(spacing: 0) {
            // Two lines: the narrow portrait/story previews can't fit title and settings on one.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TT("QUICK SHARE", 12, Theme.t1, tracking: 0.72)
                    Spacer(minLength: 12)
                    TT(sh.level.short, 11, sh.level.color).fixedSize()
                }
                TT(store.doc.displayName(store.shareContext(sh)).lowercased() + " · " + sh.summary, 11, Theme.t3)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
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
