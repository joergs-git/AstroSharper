// Lightweight AVI reader for the preview / scrub paths.
//
// Built on AVFoundation: AVAsset + AVAssetImageGenerator gives us
// codec-agnostic frame access for any container macOS can decode (which
// covers the YUV422 / BGR uncompressed AVIs that FireCapture and SharpCap
// emit, plus any compressed AVI). API mirrors SerReader closely enough
// that the preview / scrub / play paths can pick the reader by file type
// without further code branching downstream.
//
// Lucky-Stack still routes AVI through its existing "SER required" gate —
// the stacker's tight loop wants a frame-bytes pointer, which AVI's lazy
// codec-aware decode doesn't expose cheaply. Wiring AVI into Lucky-Stack
// is a separate engine task; this reader unblocks browsing and quality
// scanning today.
import AVFoundation
import CoreVideo
import Foundation
import Metal

enum AviReaderError: Error, CustomStringConvertible {
    case cannotOpen(URL)
    /// AVFoundation found no decodable video track. Most common cause:
    /// the AVI uses an uncompressed `rawvideo` stream with a zeroed
    /// FourCC tag — the dominant SharpCap mono-camera format.
    /// AVFoundation only recognises tracks with a known FourCC, so the
    /// "tracks(withMediaType: .video)" call returns an empty array.
    /// Workaround until a native rawvideo decoder lands: re-encode the
    /// AVI via QuickTime Player or ffmpeg to ProRes / H.264 in MOV /
    /// MP4. ffmpeg one-liner:
    ///   ffmpeg -i in.avi -c:v prores -profile:v 4 out.mov
    case noVideoTrack
    case unknownDuration
    case decodeFailed(frame: Int)

    var description: String {
        switch self {
        case .cannotOpen(let url):
            return "cannot open \(url.lastPathComponent)"
        case .noVideoTrack:
            return "no AVFoundation-decodable video track (SharpCap-style rawvideo / pal8 AVIs need re-encoding to ProRes or H.264 first; see ffmpeg one-liner in source comments)"
        case .unknownDuration:
            return "container reports zero / invalid duration"
        case .decodeFailed(let f):
            return "frame \(f) decode failed"
        }
    }
}

final class AviReader {
    let url: URL
    let imageWidth: Int
    let imageHeight: Int
    /// Total decodable frame count derived from `duration × nominal frame rate`.
    /// Container metadata is occasionally off by one frame for lossless AVI;
    /// callers must clamp before requesting the last frame.
    let frameCount: Int
    let frameRate: Double
    let duration: CMTime

    /// Image generator is the synchronous, codec-agnostic path. We
    /// configure it for exact, untransformed pixel access — no smoothing,
    /// no orientation correction.
    private let generator: AVAssetImageGenerator

    init(url: URL) throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        let videoTracks = asset.tracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw AviReaderError.noVideoTrack
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = Int(abs(size.width).rounded())
        let h = Int(abs(size.height).rounded())
        let fps = Double(track.nominalFrameRate)
        let dur = asset.duration
        guard fps > 0, dur.isValid, dur.value > 0 else {
            throw AviReaderError.unknownDuration
        }
        self.imageWidth = w
        self.imageHeight = h
        self.frameRate = fps
        self.duration = dur
        let durSec = CMTimeGetSeconds(dur)
        // Floor — don't claim a frame that's past the asset's last sample.
        self.frameCount = max(1, Int(floor(durSec * fps)))

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter  = .zero
        gen.appliesPreferredTrackTransform = true
        self.generator = gen
    }

    // MARK: - Frame access

    /// Decode the Nth frame and upload to a fresh rgba16Float MTLTexture
    /// matching the rest of the AstroSharper pipeline.
    func loadFrame(at index: Int, device: MTLDevice) throws -> MTLTexture {
        let clamped = max(0, min(frameCount - 1, index))
        let t = CMTime(seconds: Double(clamped) / max(1.0, frameRate),
                       preferredTimescale: max(600, duration.timescale))
        var actual: CMTime = .zero
        guard let cg = try? generator.copyCGImage(at: t, actualTime: &actual) else {
            throw AviReaderError.decodeFailed(frame: clamped)
        }
        return try Self.cgImageToTexture(cg, device: device)
    }

    // MARK: - Helpers

    /// Render a CGImage into a 16-bit half-float RGBA Metal texture. Same
    /// pattern as ImageTexture.load — keeps the pipeline format consistent.
    private static func cgImageToTexture(_ cg: CGImage, device: MTLDevice) throws -> MTLTexture {
        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue |
            CGBitmapInfo.floatComponents.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 16,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else {
            throw ImageTextureError.cannotCreateTexture
        }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { throw ImageTextureError.cannotDecode(URL(fileURLWithPath: "/dev/null")) }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw ImageTextureError.cannotCreateTexture
        }
        tex.replace(region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: w, height: h, depth: 1)),
                    mipmapLevel: 0,
                    withBytes: data,
                    bytesPerRow: bytesPerRow)
        return tex
    }
}
