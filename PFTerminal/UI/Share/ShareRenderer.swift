import PFCore
import PFCoreUI
import AppKit
import SwiftUI

/// Dedicated export pipeline: renders the card offscreen at its exact pixel size,
/// independent of window size or display scale.
@MainActor
enum ShareRenderer {
    static func image(_ m: ShareCardModel) -> NSImage? {
        let r = ImageRenderer(content: ShareCardView(m: m))
        r.scale = 1
        r.isOpaque = true
        guard let cg = r.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func png(_ m: ShareCardModel) -> Data? {
        let r = ImageRenderer(content: ShareCardView(m: m))
        r.scale = 1
        r.isOpaque = true
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ img: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(tiff, forType: .tiff)
        } else {
            pb.writeObjects([img])
        }
    }

    static func save(_ m: ShareCardModel, suggestedName: String, done: @escaping (URL?) -> Void) {
        guard let data = png(m) else { done(nil); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { done(nil); return }
        do { try data.write(to: url, options: .atomic); done(url) } catch { done(nil) }
    }

    private static var pickerDelegate: PickerDelegate?

    static func presentPicker(_ m: ShareCardModel, from view: NSView, chosen: @escaping (String) -> Void) {
        guard let data = png(m) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-portfolio-card.png")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        presentPicker(url: url, from: view, chosen: chosen)
    }

    /// Any rendered file (png, mp4, gif) through the macOS share picker.
    static func presentPicker(url: URL, from view: NSView, chosen: @escaping (String) -> Void) {
        let picker = NSSharingServicePicker(items: [url])
        let d = PickerDelegate(chosen)
        pickerDelegate = d
        picker.delegate = d
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    final class PickerDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        let chosen: (String) -> Void
        init(_ c: @escaping (String) -> Void) { chosen = c }
        func sharingServicePicker(_ p: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if let s = service { chosen(s.title) }
        }
    }
}

/// Captures an NSView for anchoring the native share picker.
struct ViewAnchor: NSViewRepresentable {
    let set: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { set(v) }; return v }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
