// Presentation only: rounds the corners of a captured window like macOS does, adds a soft
// shadow on a transparent canvas, optionally downscales. The UI pixels are not altered.
// usage: swift scripts/frame-screenshot.swift in.png out.png [maxWidth]
import AppKit

let a = CommandLine.arguments
guard a.count >= 3, let src = NSImage(contentsOfFile: a[1]), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: frame-screenshot in.png out.png [maxWidth]")
}
let scale = a.count > 3 ? min(1, Double(a[3])! / Double(cg.width)) : 1
let w = Double(cg.width) * scale, h = Double(cg.height) * scale
let pad = 60 * scale * 2, radius = 16 * scale * 2
let W = Int(w + pad * 2), H = Int(h + pad * 2)
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let rect = CGRect(x: pad, y: pad, width: w, height: h)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale * 2), blur: 50 * scale * 2, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(path); ctx.clip()
ctx.draw(cg, in: rect)
ctx.resetClip()
ctx.addPath(path); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.setLineWidth(1 * scale * 2); ctx.strokePath()
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("\(a[2]) \(W)x\(H)")
