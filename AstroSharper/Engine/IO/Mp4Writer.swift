// MP4 (H.264) video export — writes the cropped + strided + processed
// frame range as an internet-friendly video file (Instagram / YouTube /
// Facebook / Twitter all accept plain H.264-in-MP4 directly).
//
// Architecture mirrors GifWriter / SerWriter (same crop snapping, same
// stride + range handling, same BakeInExporter.Context per-frame
// pipeline). The difference is the writer backend: AVAssetWriter with
// an AVAssetWriterInputPixelBufferAdaptor instead of an ImageIO GIF
// destination.
//
// Bake-in is MANDATORY for MP4. A raw mono/Bayer SER doesn't make
// sense as a viewable video — no demosaic, no tone curve, no display
// gamut. Anyone exporting to MP4 is sharing the *processed* look they
// see in the live preview. Forcing bake-in here matches that intent.
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

enum Mp4Writer {
    enum WriteError: LocalizedError {
        case openFailed(String)
        case writeFailed(String)
        case emptyRange
        case noBakeIn

        var errorDescription: String? {
            switch self {
            case .openFailed(let s):  return "MP4 open failed: \(s)"
            case .writeFailed(let s): return "MP4 write failed: \(s)"
            case .emptyRange:         return "Frame range is empty."
            case .noBakeIn:           return "MP4 export requires Bake-in (demosaic + tone)."
            }
        }
    }

    /// Write the picked frames as an MP4 (H.264) at `fps` playback rate.
    /// `bakeIn` MUST be non-nil (we always run Sharpen + Tone for video).
    static func write(
        source: URL,
        output: URL,
        frameRange: ClosedRange<Int>,
        fps: Int,
        crop: CGRect?,
        bakeIn: BakeInExporter.Options,
        frameStride: Int = 1,
        targetFrameCount: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard !frameRange.isEmpty else { throw WriteError.emptyRange }
        let reader = try SerReader(url: source)
        let h = reader.header
        let srcW = h.imageWidth
        let srcH = h.imageHeight

        // Crop snapping — same as SerWriter / GifWriter.
        var cx = 0, cy = 0, cw = srcW, ch_ = srcH
        if let c = crop {
            cx = Int(c.origin.x.rounded())
            cy = Int(c.origin.y.rounded())
            cw = Int(c.width.rounded())
            ch_ = Int(c.height.rounded())
            if h.colorID.isBayer {
                cx &= ~1; cy &= ~1
                if cw & 1 != 0 { cw -= 1 }
                if ch_ & 1 != 0 { ch_ -= 1 }
            }
            cx = max(0, min(srcW - 1, cx))
            cy = max(0, min(srcH - 1, cy))
            cw = max(2, min(srcW - cx, cw))
            ch_ = max(2, min(srcH - cy, ch_))
        }

        let frameStart = max(0, min(frameRange.lowerBound, h.frameCount - 1))
        let frameEnd   = max(frameStart, min(frameRange.upperBound, h.frameCount - 1))
        let stride = max(1, frameStride)
        let candidates: [Int] = Swift.stride(
            from: frameStart, through: frameEnd, by: stride
        ).map { $0 }
        guard !candidates.isEmpty else { throw WriteError.emptyRange }
        // If targetFrameCount is set (duration × fps from the panel),
        // evenly distribute that many picks across candidates. Else
        // use every candidate (legacy stride-only path).
        let pickedIndices: [Int]
        if let target = targetFrameCount, target > 0, target < candidates.count {
            var picked: [Int] = []
            picked.reserveCapacity(target)
            if target == 1 {
                picked.append(candidates[0])
            } else {
                for i in 0..<target {
                    let t = Double(i) / Double(target - 1)
                    let pos = Int((t * Double(candidates.count - 1)).rounded())
                    picked.append(candidates[pos])
                }
            }
            pickedIndices = picked
        } else {
            pickedIndices = candidates
        }
        let count = pickedIndices.count
        guard count > 0 else { throw WriteError.emptyRange }

        // We need to know the FINAL output frame dimensions BEFORE
        // creating the AVAssetWriter (H.264 input sizes are baked into
        // the writer config). Decode frame 0 first to get the exact
        // post-pipeline width × height (resize + rotation can change
        // them from the raw crop dimensions).
        //
        // Force 8-bit bake — H.264 is 8-bit only; a 16-bit FrameOut
        // would just be downsampled in CPU later, wasted bytes.
        var opts = bakeIn
        opts = BakeInExporter.Options(
            sharpen: opts.sharpen,
            toneCurve: opts.toneCurve,
            coloring: opts.coloring,
            outputBitDepth: 8,
            resizeDivisor: opts.resizeDivisor,
            rotationDegrees: opts.rotationDegrees
        )
        let ctx = BakeInExporter.Context(options: opts)
        let firstCrop: CGRect? = (cx == 0 && cy == 0 && cw == srcW && ch_ == srcH)
            ? nil
            : CGRect(x: cx, y: cy, width: cw, height: ch_)
        let firstFrame = try ctx.processedFrame(
            sourceURL: source,
            frameIndex: pickedIndices[0],
            crop: firstCrop
        )
        let outW = firstFrame.width
        let outH = firstFrame.height

        // Build AVAssetWriter — H.264 inside MP4 container.
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw WriteError.openFailed("\(error)")
        }
        // Bitrate heuristic: ~8 bpp baseline ≈ broadcast-quality H.264
        // for noisy planetary content; floor at 2 Mbps so tiny crops
        // don't end up macroblocky.
        let bitrate = max(2_000_000, outW * outH * 8)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey  as String: outW,
                kCVPixelBufferHeightKey as String: outH,
            ]
        )
        guard writer.canAdd(input) else {
            throw WriteError.openFailed("AVAssetWriter cannot add input")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let timescale: Int32 = 600
        let frameDurationTicks = Int64(Double(timescale) / Double(max(1, fps)))

        // Append frame 0 first (we already decoded it for sizing).
        if let pb = makeBGRAPixelBuffer(width: outW, height: outH, adaptor: adaptor) {
            copyRGBA8ToBGRAPixelBuffer(rgba8: firstFrame.data, width: outW, height: outH, into: pb)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(pb, withPresentationTime: .zero)
        }
        progress?(1.0 / Double(count))

        // Remaining frames.
        for i in 1..<count {
            let frame = try ctx.processedFrame(
                sourceURL: source,
                frameIndex: pickedIndices[i],
                crop: firstCrop
            )
            // Dimension stability check — if bake-in's resize/rotate
            // somehow yielded a different size mid-run, skip rather
            // than write a corrupt frame. Shouldn't happen because
            // options are frozen on the Context, but cheap guard.
            guard frame.width == outW, frame.height == outH else { continue }
            guard let pb = makeBGRAPixelBuffer(width: outW, height: outH, adaptor: adaptor) else { continue }
            copyRGBA8ToBGRAPixelBuffer(rgba8: frame.data, width: outW, height: outH, into: pb)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let pts = CMTime(value: Int64(i) * frameDurationTicks, timescale: timescale)
            adaptor.append(pb, withPresentationTime: pts)
            if i % 4 == 0 || i == count - 1 {
                progress?(Double(i + 1) / Double(count))
            }
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status == .failed {
            throw WriteError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: - Pixel buffer helpers

    /// Pull a BGRA pixel buffer from the adaptor's pool (fast path) or
    /// allocate a fresh one if the pool is empty / not ready yet.
    private static func makeBGRAPixelBuffer(
        width: Int, height: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            CVPixelBufferCreate(nil, width, height,
                                kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &pb)
        }
        return pb
    }

    /// Copy interleaved RGBA8 pixels into a BGRA pixel buffer with
    /// R/B swap. BakeIn FrameOut.data is RGBA when outputBitDepth is 8
    /// (see BakeInExporter line 276), so this is just a swizzle.
    private static func copyRGBA8ToBGRAPixelBuffer(
        rgba8: Data, width: Int, height: Int, into pb: CVPixelBuffer
    ) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        rgba8.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let srcRow = src.advanced(by: y * width * 4)
                let dstRow = dst.advanced(by: y * dstRowBytes)
                for x in 0..<width {
                    let s = srcRow.advanced(by: x * 4)
                    let d = dstRow.advanced(by: x * 4)
                    d[0] = s[2]   // B ← R
                    d[1] = s[1]   // G
                    d[2] = s[0]   // R ← B
                    d[3] = 255    // A
                }
            }
        }
    }
}
