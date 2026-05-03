// Export an in-memory aligned sequence (or any list of MTLTextures) as an
// image sequence or as a single video / GIF. Each frame is run through the
// shared processing pipeline first so sharpening / tone-curve are baked in.
//
// Image sequence formats: 16-bit TIFF, 8-bit PNG, 8-bit JPEG.
// Video formats:         MP4 (H.264), MOV (Apple ProRes 422), animated GIF.
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case tiffSequence       = "TIFF sequence (16-bit)"
    case tiff32FloatSequence = "TIFF sequence (32-bit float)"
    case pngSequence        = "PNG sequence (8-bit)"
    case jpegSequence       = "JPEG sequence"
    case mp4H264            = "MP4 video (H.264)"
    case movProRes          = "MOV video (ProRes 422)"
    case animatedGIF        = "Animated GIF"
    var id: String { rawValue }

    var isSequence: Bool {
        switch self {
        case .tiffSequence, .tiff32FloatSequence, .pngSequence, .jpegSequence: return true
        default: return false
        }
    }
    var sequenceExtension: String {
        switch self {
        case .tiffSequence, .tiff32FloatSequence: return "tif"
        case .pngSequence:  return "png"
        case .jpegSequence: return "jpg"
        default: return ""
        }
    }
    var fileExtension: String {
        switch self {
        case .mp4H264:     return "mp4"
        case .movProRes:   return "mov"
        case .animatedGIF: return "gif"
        default: return sequenceExtension
        }
    }

    /// Bit depth implied by the format. PNG and JPEG ignore this.
    var bitDepth: ImageTexture.BitDepth {
        switch self {
        case .tiff32FloatSequence: return .float32
        default: return .uint16
        }
    }
}

enum Exporter {
    enum Progress {
        case writing(done: Int, total: Int)
        case finished
        case error(String)
    }

    struct Options {
        var format: ExportFormat
        var fps: Double
        var sharpen: SharpenSettings
        var toneCurve: ToneCurveSettings
        var toneCurveLUT: MTLTexture?
    }

    /// Exports `frames` to `destination`.
    /// - For sequence formats, `destination` is a folder; one file per frame is
    ///   written with naming `<sourceName>_proc.<ext>`.
    /// - For video / GIF, `destination` is a *file* URL with the right extension.
    static func export(
        frames: [PlaybackFrame],
        to destination: URL,
        options: Options,
        pipeline: Pipeline,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            guard !frames.isEmpty else { await onProgress(.error("No frames to export")); return }

            do {
                if options.format.isSequence {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try writeSequence(frames: frames, folder: destination, options: options, pipeline: pipeline) { p in
                        Task { @MainActor in onProgress(p) }
                    }
                } else {
                    switch options.format {
                    case .mp4H264, .movProRes:
                        try writeVideo(frames: frames, to: destination, options: options, pipeline: pipeline) { p in
                            Task { @MainActor in onProgress(p) }
                        }
                    case .animatedGIF:
                        try writeGIF(frames: frames, to: destination, options: options, pipeline: pipeline) { p in
                            Task { @MainActor in onProgress(p) }
                        }
                    default:
                        break
                    }
                }
                await onProgress(.finished)
            } catch {
                await onProgress(.error("\(error)"))
            }
        }
    }

    // MARK: - Image sequence

    private static func writeSequence(
        frames: [PlaybackFrame],
        folder: URL,
        options: Options,
        pipeline: Pipeline,
        progress: @escaping (Progress) -> Void
    ) throws {
        for (i, frame) in frames.enumerated() {
            let processed = pipeline.process(
                input: frame.texture,
                sharpen: options.sharpen,
                toneCurve: options.toneCurve,
                toneCurveLUT: options.toneCurveLUT
            )
            let baseName = frame.sourceURL.deletingPathExtension().lastPathComponent
            let outURL = folder.appendingPathComponent("\(baseName)_proc.\(options.format.sequenceExtension)")
            try ImageTexture.write(texture: processed, to: outURL, bitDepth: options.format.bitDepth)
            progress(.writing(done: i + 1, total: frames.count))
        }
    }

    // MARK: - Video (H.264 or ProRes)

    private static func writeVideo(
        frames: [PlaybackFrame],
        to outURL: URL,
        options: Options,
        pipeline: Pipeline,
        progress: @escaping (Progress) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: outURL)

        let firstTex = frames[0].texture
        let w = firstTex.width
        let h = firstTex.height

        let fileType: AVFileType = (options.format == .mp4H264) ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: outURL, fileType: fileType)

        let codecKey: AVVideoCodecType = (options.format == .mp4H264) ? .h264 : .proRes422
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codecKey,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        if options.format == .mp4H264 {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(2_000_000, w * h * 8),  // ~8 bpp baseline
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "AstroSharper.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let timescale: Int32 = 600
        let frameDuration = CMTime(value: Int64(Double(timescale) / options.fps), timescale: timescale)

        let ctx = CIContext(mtlDevice: firstTex.device)
        for (i, frame) in frames.enumerated() {
            // Wait if writer not ready (back-pressure).
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let processed = pipeline.process(
                input: frame.texture,
                sharpen: options.sharpen,
                toneCurve: options.toneCurve,
                toneCurveLUT: options.toneCurveLUT
            )
            guard let pb = makeBGRAPixelBuffer(width: w, height: h, adaptor: adaptor) else { continue }
            try renderTextureIntoBuffer(processed, into: pb, ciContext: ctx)

            let pts = CMTime(value: Int64(i) * frameDuration.value, timescale: timescale)
            adaptor.append(pb, withPresentationTime: pts)
            progress(.writing(done: i + 1, total: frames.count))
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "AstroSharper.Export", code: 2)
        }
    }

    // MARK: - Animated GIF

    private static func writeGIF(
        frames: [PlaybackFrame],
        to outURL: URL,
        options: Options,
        pipeline: Pipeline,
        progress: @escaping (Progress) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: outURL)

        let frameDuration = 1.0 / options.fps
        let fileProps: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,  // 0 = loop forever
            ],
        ]
        let frameProps: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration,
            ],
        ]

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw NSError(domain: "AstroSharper.Export", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create GIF destination"])
        }
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let ctx = CIContext(mtlDevice: frames[0].texture.device)
        for (i, frame) in frames.enumerated() {
            let processed = pipeline.process(
                input: frame.texture,
                sharpen: options.sharpen,
                toneCurve: options.toneCurve,
                toneCurveLUT: options.toneCurveLUT
            )
            guard let cgImage = makeCGImage(from: processed, ciContext: ctx) else { continue }
            CGImageDestinationAddImage(dest, cgImage, frameProps as CFDictionary)
            progress(.writing(done: i + 1, total: frames.count))
        }

        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "AstroSharper.Export", code: 4, userInfo: [NSLocalizedDescriptionKey: "GIF finalize failed"])
        }
    }

    // MARK: - Helpers

    private static func makeBGRAPixelBuffer(width: Int, height: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        }
        return pb
    }

    private static func renderTextureIntoBuffer(_ tex: MTLTexture, into pb: CVPixelBuffer, ciContext: CIContext) throws {
        guard let ci = CIImage(mtlTexture: tex, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            throw NSError(domain: "AstroSharper.Export", code: 5)
        }
        // Flip vertically — Metal origin (0,0) is bottom-left for CIImage interop.
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
        ciContext.render(flipped, to: pb)
    }

    private static func makeCGImage(from tex: MTLTexture, ciContext: CIContext) -> CGImage? {
        guard let ci = CIImage(mtlTexture: tex, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else { return nil }
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
        return ciContext.createCGImage(flipped, from: flipped.extent)
    }
}
