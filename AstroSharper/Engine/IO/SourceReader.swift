// Common abstraction over frame-sequence sources (SER, AVI, future FITS).
//
// LuckyStack, Stabilizer, QualityProbe and the headless CLI consume any
// conforming reader through this protocol so adding a new container
// format means adding one new file rather than threading branches through
// the pipeline. Format-specific fast paths (e.g. SerReader's
// memory-mapped `withFrameBytes`) stay on the concrete type — callers
// downcast when they want them.
//
// Implementers must be safe to read concurrently from different frame
// indices (`DispatchQueue.concurrentPerform` and `Task.detached` both
// touch the reader). SerReader's memory-mapped Data and AviReader's
// AVAssetImageGenerator both qualify per Apple's documented thread
// safety.
import Foundation
import Metal

/// Universal frame-source API.
///
/// All values are derived from the source itself and do not change for
/// the lifetime of the reader. `loadFrame` performs decode plus upload
/// and returns an `rgba16Float` MTLTexture matching the rest of the
/// AstroSharper pipeline.
protocol SourceReader: AnyObject {
    /// Original on-disk location. Kept for diagnostics, cache keys, and
    /// any code path that needs to re-open the source.
    var url: URL { get }

    /// Frame dimensions in pixels.
    var imageWidth: Int { get }
    var imageHeight: Int { get }

    /// Total decodable frames in the sequence. Callers must clamp before
    /// requesting the last frame; AVI containers occasionally over-report
    /// by one (handled inside AviReader).
    var frameCount: Int { get }

    /// Bits per pixel plane reported by the source (8 or 16 typically).
    /// AVI sources are reported as 8-bit since AVFoundation decodes to
    /// 8-bit RGB before we touch them.
    var pixelDepth: Int { get }

    /// Pixel layout reported in the source's native vocabulary.
    /// SER reports its `colorID` field directly; AVI reports `.rgb`
    /// post-decode regardless of the original camera Bayer pattern.
    var colorID: SerColorID { get }

    /// Capture frame rate when the container records it (AVI yes via
    /// `AVAssetTrack.nominalFrameRate`, SER no — header has no FPS field
    /// so we return nil and let the capture-side validator infer it from
    /// the timestamp trailer if available).
    var nominalFrameRate: Double? { get }

    /// UTC capture timestamp when the source supplies it (SER stores it
    /// in the header trailer; AVI typically does not). Used by the
    /// capture-side validator and derotation timestamp logic.
    var captureDate: Date? { get }

    /// Decode and upload the requested frame as an `rgba16Float`
    /// MTLTexture. SER paths through `SerFrameLoader.loadFrame` (Bayer
    /// demosaic + scale on GPU). AVI paths through AVFoundation +
    /// CGImage → texture. Both produce textures with `.shaderRead`
    /// usage; callers handle their own write-target allocation.
    func loadFrame(at index: Int, device: MTLDevice) throws -> MTLTexture
}

/// Errors that surface when the factory can't open a URL.
enum SourceReaderOpenError: Error, LocalizedError {
    case unsupportedExtension(String)
    case openFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext):
            return "SourceReader: unsupported extension '.\(ext)'"
        case .openFailed(let kind, let underlying):
            return "SourceReader: \(kind) open failed — \(underlying)"
        }
    }
}

extension SourceReader where Self == SerReader {
    /// Format-agnostic factory — dispatches by file extension to the
    /// matching concrete reader. Use when the calling code only needs
    /// the universal `SourceReader` API. Format-specific fast paths
    /// (raw byte access for SER's accumulator loop, AVFoundation
    /// hooks for AVI) still want a direct construction.
    ///
    /// Supported extensions:
    /// - `.ser` → `SerReader`
    /// - `.avi`, `.mov`, `.mp4`, `.m4v` → `AviReader`
    /// - `.fits`, `.fit` → `FitsFrameReader`
    static func open(url: URL) throws -> SourceReader {
        try SourceReaderFactory.open(url: url)
    }
}

enum SourceReaderFactory {
    static func open(url: URL) throws -> SourceReader {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ser":
            do { return try SerReader(url: url) }
            catch { throw SourceReaderOpenError.openFailed("SER", error) }
        case "avi", "mov", "mp4", "m4v":
            do { return try AviReader(url: url) }
            catch { throw SourceReaderOpenError.openFailed("AVI", error) }
        case "fits", "fit":
            do { return try FitsFrameReader(url: url) }
            catch { throw SourceReaderOpenError.openFailed("FITS", error) }
        default:
            throw SourceReaderOpenError.unsupportedExtension(ext)
        }
    }
}

// MARK: - SerReader conformance

extension SerReader: SourceReader {
    var imageWidth: Int       { header.imageWidth }
    var imageHeight: Int      { header.imageHeight }
    var frameCount: Int       { header.frameCount }
    var pixelDepth: Int       { header.pixelDepthPerPlane }
    var colorID: SerColorID   { header.colorID }
    var nominalFrameRate: Double? { nil }
    var captureDate: Date?    { header.dateUTC }

    func loadFrame(at index: Int, device: MTLDevice) throws -> MTLTexture {
        try SerFrameLoader.loadFrame(url: url, frameIndex: index, device: device)
    }
}

// MARK: - AviReader conformance

extension AviReader: SourceReader {
    /// AVI passes through AVFoundation's 8-bit RGB decode regardless of
    /// the source camera bit depth — we only see 8-bit at the texture
    /// boundary today. Capture-side validator should warn separately
    /// when an AVI's header says otherwise.
    var pixelDepth: Int       { 8 }

    /// AVFoundation hands us pre-debayered RGB; the original Bayer layout
    /// is lost by the time we touch the frame.
    var colorID: SerColorID   { .rgb }

    /// AviReader already exposes the nominal FPS as a `Double`; surface
    /// it as the protocol's optional.
    var nominalFrameRate: Double? { frameRate }

    /// AVAsset.creationDate is sometimes populated for SharpCap/FireCapture
    /// AVIs but not consistently — wired through later if a capture file
    /// surfaces a usable timestamp.
    var captureDate: Date?    { nil }

    // `loadFrame(at:device:)` already defined on AviReader.
}
