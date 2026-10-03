import PFCore
import CoreText
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Shared by the app and the widget extension (and a future iOS target): no AppKit-only API
// outside the conditional font check.

extension AppTheme {
    public func palette(systemIsDark: Bool) -> ThemePalette {
        switch self {
        case .dark: .dark
        case .light: .light
        case .midnight: .midnight
        case .graphite: .graphite
        case .system: systemIsDark ? .dark : .light
        }
    }
}

/// One complete set of colour tokens (sRGB hex). Every theme defines every token, so a view
/// can never fall back to another theme's colour. Views use the `Theme.*` names below.
public struct ThemePalette: Equatable, Sendable {
    public let name: String
    public let isLight: Bool
    public let bg, raised, selected, hover, chrome, chromeBorder, border, rowBorder, innerBorder, overlayBorder: UInt32
    public let tabBg, paletteSel, kbdBorder, kbdBottom, track, faint: UInt32
    public let t1, text, t2, t3, t4, t5, muted, bar, barStrong: UInt32
    public let pos, neg, acc, warning, onAccent: UInt32
    public let chartGrid, popover, well: UInt32
    public let scrimOpacity: Double

    /// Text tokens and the background they must stay readable on (contrast tests).
    public var textTokens: [(String, UInt32)] { [("t1", t1), ("text", text), ("t2", t2), ("t3", t3), ("t4", t4), ("pos", pos), ("neg", neg), ("acc", acc), ("warning", warning)] }

    /// The original PF Terminal look (unchanged values).
    public static let dark = ThemePalette(
        name: "dark", isLight: false,
        bg: 0x0e0f11, raised: 0x131417, selected: 0x16181b, hover: 0x141518, chrome: 0x111215, chromeBorder: 0x1f2124,
        border: 0x232529, rowBorder: 0x18191c, innerBorder: 0x1d1f22, overlayBorder: 0x34373c,
        tabBg: 0x1c1e22, paletteSel: 0x1b1d21, kbdBorder: 0x2e3136, kbdBottom: 0x3a3d42, track: 0x3f4247, faint: 0x4b4e54,
        t1: 0xe4e5e7, text: 0xd6d7d9, t2: 0x9a9da3, t3: 0x7a7e85, t4: 0x6b6f75, t5: 0x5d6066, muted: 0xc4c6c9, bar: 0x8b8f96, barStrong: 0xa9acb1,
        pos: 0x7fcf9a, neg: 0xe8847a, acc: 0xe0b35a, warning: 0xe39b4b, onAccent: 0x131313,
        chartGrid: 0x30333a, popover: 0x141517, well: 0x0a0b0c, scrimOpacity: 0.36)

    /// Warm paper, graphite ink: a designed light theme, not an inversion.
    public static let light = ThemePalette(
        name: "light", isLight: true,
        bg: 0xf6f4ef, raised: 0xfcfbf8, selected: 0xe9e5dc, hover: 0xefece5, chrome: 0xeeebe4, chromeBorder: 0xd8d3c8,
        border: 0xd3cec3, rowBorder: 0xe7e3da, innerBorder: 0xdfdad0, overlayBorder: 0xb9b3a7,
        tabBg: 0xe4e0d6, paletteSel: 0xe6e2d8, kbdBorder: 0xc6c0b4, kbdBottom: 0xaea89c, track: 0xc9c3b7, faint: 0xa39d92,
        t1: 0x1b1d20, text: 0x2a2d31, t2: 0x4c5057, t3: 0x5c6067, t4: 0x666a71, t5: 0x7a7e85, muted: 0x3a3d42, bar: 0x7b7f86, barStrong: 0x55595f,
        pos: 0x1d7343, neg: 0xb0362b, acc: 0x8f6100, warning: 0x9c4f00, onAccent: 0xffffff,
        chartGrid: 0xcfc9bd, popover: 0xf8f6f1, well: 0xebe8e1, scrimOpacity: 0.18)

    /// Deep navy with blue-grey surfaces and a restrained teal for bars; amber for focus.
    public static let midnight = ThemePalette(
        name: "midnight", isLight: false,
        bg: 0x0b1220, raised: 0x101a2b, selected: 0x16223a, hover: 0x131d31, chrome: 0x0e1626, chromeBorder: 0x1d2940,
        border: 0x22304a, rowBorder: 0x152036, innerBorder: 0x1b2740, overlayBorder: 0x34466a,
        tabBg: 0x1a2640, paletteSel: 0x19253e, kbdBorder: 0x2c3b58, kbdBottom: 0x3a4a6a, track: 0x3c4b66, faint: 0x4d5c79,
        t1: 0xe3e9f3, text: 0xd3dbe7, t2: 0x9fadc2, t3: 0x8593a9, t4: 0x76849a, t5: 0x637189, muted: 0xc2cbd8, bar: 0x6f9fb3, barStrong: 0x9cc3cf,
        pos: 0x7fcf9a, neg: 0xe8847a, acc: 0xe0b35a, warning: 0xe39b4b, onAccent: 0x0b1220,
        chartGrid: 0x2a3956, popover: 0x101a2b, well: 0x08101c, scrimOpacity: 0.40)

    /// Neutral charcoal, calmer surfaces and lower-saturation colour for long sessions.
    public static let graphite = ThemePalette(
        name: "graphite", isLight: false,
        bg: 0x1b1c1e, raised: 0x222326, selected: 0x2a2b2f, hover: 0x252629, chrome: 0x1f2022, chromeBorder: 0x2e3033,
        border: 0x313337, rowBorder: 0x26282b, innerBorder: 0x2b2d30, overlayBorder: 0x45484d,
        tabBg: 0x2c2e31, paletteSel: 0x2b2d31, kbdBorder: 0x3d4045, kbdBottom: 0x4a4d52, track: 0x4c4f54, faint: 0x5c5f65,
        t1: 0xdcdddf, text: 0xcfd0d2, t2: 0xa3a6ab, t3: 0x8b8f95, t4: 0x80848a, t5: 0x6f7278, muted: 0xbfc1c4, bar: 0x8e9298, barStrong: 0xb0b3b8,
        pos: 0x8cc6a0, neg: 0xdb9289, acc: 0xc9a560, warning: 0xd09a5e, onAccent: 0x1b1c1e,
        chartGrid: 0x3a3c41, popover: 0x222326, well: 0x161719, scrimOpacity: 0.36)

    public static let all: [ThemePalette] = [.dark, .light, .midnight, .graphite]
}

/// Design tokens from the prototype's visual system: one typeface, 1px hairlines, colour only
/// for meaning. Values come from the active `palette` (dark unless the app sets another; the
/// widget extension never does). Set it on the main thread.
public enum Theme {
    nonisolated(unsafe) public static var palette: ThemePalette = .dark
    private static func c(_ k: KeyPath<ThemePalette, UInt32>) -> Color { Color(hex: palette[keyPath: k]) }

    public static var bg: Color { c(\.bg) }                  // window background
    public static var raised: Color { c(\.raised) }          // palette, sheets
    public static var selected: Color { c(\.selected) }      // selected row
    public static var hover: Color { c(\.hover) }
    public static var chrome: Color { c(\.chrome) }
    public static var chromeBorder: Color { c(\.chromeBorder) }
    public static var border: Color { c(\.border) }          // hairline
    public static var rowBorder: Color { c(\.rowBorder) }
    public static var innerBorder: Color { c(\.innerBorder) }
    public static var overlayBorder: Color { c(\.overlayBorder) }
    public static var tabBg: Color { c(\.tabBg) }
    public static var paletteSel: Color { c(\.paletteSel) }
    public static var kbdBorder: Color { c(\.kbdBorder) }
    public static var kbdBottom: Color { c(\.kbdBottom) }
    public static var track: Color { c(\.track) }
    public static var faint: Color { c(\.faint) }

    public static var t1: Color { c(\.t1) }                  // figures
    public static var text: Color { c(\.text) }
    public static var t2: Color { c(\.t2) }                  // secondary
    public static var t3: Color { c(\.t3) }                  // labels, keys
    public static var t4: Color { c(\.t4) }
    public static var t5: Color { c(\.t5) }
    public static var muted: Color { c(\.muted) }
    public static var bar: Color { c(\.bar) }
    public static var barStrong: Color { c(\.barStrong) }
    public static var pos: Color { c(\.pos) }                // financial only
    public static var neg: Color { c(\.neg) }                // financial only
    public static var acc: Color { c(\.acc) }                // focus, caret, cursor
    public static var warning: Color { c(\.warning) }        // needs attention (not a loss)
    public static var onAccent: Color { c(\.onAccent) }      // glyphs drawn on an accent fill
    public static var chartGrid: Color { c(\.chartGrid) }
    public static var popover: Color { c(\.popover) }        // menu bar popover
    public static var well: Color { c(\.well) }              // recessed preview area
    public static var scrim: Color { Color.black.opacity(palette.scrimOpacity) }
    public static var isLight: Bool { palette.isLight }

    // Semantic names (same tokens).
    public static var background: Color { bg }
    public static var surface: Color { chrome }
    public static var elevatedSurface: Color { raised }
    public static var textPrimary: Color { t1 }
    public static var textSecondary: Color { t2 }
    public static var accent: Color { acc }
    public static var positive: Color { pos }
    public static var negative: Color { neg }
    public static var selection: Color { selected }

    public static func signColor(_ v: Double?) -> Color {
        guard let v else { return t2 }
        return v > 0 ? pos : v < 0 ? neg : t2
    }
    public static func signColor(_ v: Decimal?) -> Color { signColor(v?.double) }

    // MARK: type

    public static let hasGeist: Bool = {
        // Optional: Geist Mono (OFL) .ttf/.otf files placed in PFTerminal/Resources are bundled and used.
        // In the widget extension Bundle.main is the .appex, which has no fonts: falls back to SF Mono.
        for ext in ["ttf", "otf"] {
            for u in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
            }
        }
        #if canImport(AppKit)
        return NSFont(name: "GeistMono-Regular", size: 12) != nil
        #else
        return UIFont(name: "GeistMono-Regular", size: 12) != nil
        #endif
    }()

    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if hasGeist { return .custom("Geist Mono", size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// Pixel "PF" mark (the prototype uses the Bytesized bitmap face).
public struct PFGlyph: View {
    public init(size: CGFloat = 14, color: Color = Theme.t1) { self.size = size; self.color = color }
    public var size: CGFloat = 14
    public var color: Color = Theme.t1
    private static let rows = ["111 111", "101 100", "111 110", "100 100", "100 100"]

    public var body: some View {
        let px = size / 7
        Canvas { ctx, _ in
            for (y, r) in Self.rows.enumerated() {
                for (x, ch) in r.enumerated() where ch == "1" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)), with: .color(color))
                }
            }
        }
        .frame(width: px * 7, height: px * 5)
    }
}
