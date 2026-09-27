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

/// Design tokens from the prototype's visual system: one typeface, 1px hairlines,
/// color only for meaning.
enum Theme {
    static let bg = Color(hex: 0x0e0f11)          // window background
    static let raised = Color(hex: 0x131417)      // palette, sheets
    static let selected = Color(hex: 0x16181b)    // selected row
    static let hover = Color(hex: 0x141518)
    static let chrome = Color(hex: 0x111215)
    static let chromeBorder = Color(hex: 0x1f2124)
    static let border = Color(hex: 0x232529)      // hairline
    static let rowBorder = Color(hex: 0x18191c)
    static let innerBorder = Color(hex: 0x1d1f22)
    static let overlayBorder = Color(hex: 0x34373c)
    static let tabBg = Color(hex: 0x1c1e22)
    static let paletteSel = Color(hex: 0x1b1d21)
    static let kbdBorder = Color(hex: 0x2e3136)
    static let kbdBottom = Color(hex: 0x3a3d42)
    static let track = Color(hex: 0x3f4247)
    static let faint = Color(hex: 0x4b4e54)

    static let t1 = Color(hex: 0xe4e5e7)          // figures
    static let text = Color(hex: 0xd6d7d9)
    static let t2 = Color(hex: 0x9a9da3)          // secondary
    static let t3 = Color(hex: 0x7a7e85)          // labels, keys
    static let t4 = Color(hex: 0x6b6f75)
    static let t5 = Color(hex: 0x5d6066)
    static let muted = Color(hex: 0xc4c6c9)
    static let bar = Color(hex: 0x8b8f96)
    static let pos = Color(hex: 0x7fcf9a)         // financial only
    static let neg = Color(hex: 0xe8847a)         // financial only
    static let acc = Color(hex: 0xe0b35a)         // focus, caret, cursor

    static func signColor(_ v: Double?) -> Color {
        guard let v else { return t2 }
        return v > 0 ? pos : v < 0 ? neg : t2
    }
    static func signColor(_ v: Decimal?) -> Color { signColor(v?.double) }

    // MARK: type

    static let hasGeist: Bool = {
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

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if hasGeist { return .custom("Geist Mono", size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// Pixel "PF" mark (the prototype uses the Bytesized bitmap face).
struct PFGlyph: View {
    var size: CGFloat = 14
    var color: Color = Theme.t1
    private static let rows = ["111 111", "101 100", "111 110", "100 100", "100 100"]

    var body: some View {
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
