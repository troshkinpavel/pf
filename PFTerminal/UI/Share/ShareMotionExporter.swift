import PFCore
import PFCoreUI
import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Animated cards (design §16): 3 s, rendered frame by frame with the same view as the PNG,
/// encoded locally. MP4 at the card's full size (30 fps); GIF at half size (15 fps), which keeps
/// it a few MB instead of tens.
@MainActor
enum ShareMotionExporter {
    enum Failure: Error { case render, encode }

    static func fileExtension(_ f: ShareMotionFormat) -> String { f.rawValue }
    static func outputSize(_ m: ShareCardModel, _ f: ShareMotionFormat) -> (w: Int, h: Int) {
        let s = m.format.size
        return f == .gif ? (s.w / 2, s.h / 2) : s
    }

    /// Renders and encodes to a temporary file. Yields between frames so the window stays responsive.
    static func export(_ m: ShareCardModel, format: ShareMotionFormat) async throws -> URL {
        let fps = format == .gif ? 15 : 30
        let count = Int(ShareCardView.motionDuration * Double(fps))
        let scale: CGFloat = format == .gif ? 0.5 : 1
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / Double(fps)
            let r = ImageRenderer(content: ShareCardView(m: m, progress: ShareCardView.motionProgress(at: t), time: t))
            r.scale = scale
            r.isOpaque = true
            guard let cg = r.cgImage else { throw Failure.render }
            frames.append(cg)
            await Task.yield()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-card-\(UUID().uuidString.prefix(6)).\(format.rawValue)")
        switch format {
        case .gif: try gif(frames, fps: fps, to: url)
        case .mp4: try await mp4(frames, fps: fps, to: url)
        }
        return url
    }

    private static func gif(_ frames: [CGImage], fps: Int, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { throw Failure.encode }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, frameProps) }
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
    }

    private static func mp4(_ frames: [CGImage], fps: Int, to url: URL) async throws {
        guard let first = frames.first else { throw Failure.render }
        // H.264 wants even dimensions.
        let w = first.width & ~1, h = first.height & ~1
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.encode }
        writer.startSession(atSourceTime: .zero)
        for (i, f) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.encode }
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
            guard let pb = buf else { throw Failure.encode }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(f, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.encode }
    }

    /// The file on the pasteboard: paste into Messages, Telegram, Finder…
    static func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    static func save(_ url: URL, suggestedName: String, format: ShareMotionFormat) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dst = panel.url else { return nil }
        try? FileManager.default.removeItem(at: dst)
        return (try? FileManager.default.copyItem(at: url, to: dst)) != nil ? dst : nil
    }
}
