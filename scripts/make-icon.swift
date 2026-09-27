// Generates PFTerminal/Resources/Assets.xcassets/AppIcon.appiconset. Run: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "PFTerminal/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let glyph = ["111 111", "101 100", "111 110", "100 100", "100 100"]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, r = s * 0.8
    let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: r, height: r), xRadius: r * 0.225, yRadius: r * 0.225)
    NSColor(red: 0x0e / 255, green: 0x0f / 255, blue: 0x11 / 255, alpha: 1).setFill(); body.fill()
    NSColor(red: 0x34 / 255, green: 0x37 / 255, blue: 0x3c / 255, alpha: 1).setStroke(); body.lineWidth = max(1, s / 256); body.stroke()
    let cell = r * 0.075, w = cell * 7, h = cell * 5
    let ox = (s - w) / 2, oy = (s - h) / 2 + cell * 0.4
    NSColor(red: 0xe0 / 255, green: 0xb3 / 255, blue: 0x5a / 255, alpha: 1).setFill()
    for (y, row) in glyph.enumerated() {
        for (x, c) in row.enumerated() where c == "1" {
            NSRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(4 - y) * cell, width: cell, height: cell).fill()
        }
    }
    // cursor underline, terminal style
    NSColor(red: 0x7a / 255, green: 0x7e / 255, blue: 0x85 / 255, alpha: 1).setFill()
    NSRect(x: ox + cell * 8, y: oy, width: cell * 1.6, height: cell * 0.5).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(base * scale).write(to: out.appendingPathComponent(name))
        images.append(#"{ "idiom": "mac", "size": "\#(base)x\#(base)", "scale": "\#(scale)x", "filename": "\#(name)" }"#)
    }
}
try! ("{ \"images\": [\n" + images.joined(separator: ",\n") + "\n], \"info\": { \"author\": \"xcode\", \"version\": 1 } }\n").write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("ok")
