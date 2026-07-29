// Lightweight AVI reader for the preview / scrub paths.
//
// Built on AVFoundation: AVAsset + AVAssetImageGenerator gives us
// codec-agnostic frame access for any container macOS can decode (which
// covers the YUV422 / BGR uncompressed AVIs that FireCapture and SharpCap
// emit, plus any compressed AVI). API mirrors SerReader closely enough
// that the preview / scrub / play paths can pick the reader by file type
// without further code branching downstream.
//
// Lucky-Stack consumes this reader through `SourceReader.loadFrame`, which
// hands back a ready-to-use rgba16Float texture — the stacker's SER fast
// path (raw frame-bytes pointer + GPU unpack) is bypassed for video.
//
// Codec support is whatever macOS itself can decode: ProRes, H.264, HEVC,
// and the uncompressed AVIs FireCapture / SharpCap emit. Notably NOT FFV1,
// which ffmpeg tutorials recommend for lossless output — see
// `undecodableCodec` below, which catches it at open time with an
// actionable message instead of failing on every frame.
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
    /// The track passed the `isDecodable` check at open time but a frame
    /// still failed to produce an image. Motion JPEG is the known case:
    /// macOS reports it as decodable in both AVI and MOV, then hands back
    /// nothing. Since this cannot be predicted at open time, the message
    /// carries the same re-encode advice as `undecodableCodec`.
    case decodeFailed(frame: Int)
    /// The container is readable and declares a video track, but macOS has
    /// no decoder for its codec. FFV1 is the one users hit in practice —
    /// it is ffmpeg's default suggestion for "lossless", and every
    /// ffmpeg-based tutorial reaches for it, but AVFoundation cannot touch
    /// it. Without this check the failure surfaced late and uselessly as
    /// "frame 0 decode failed", after the frame count had already been
    /// read successfully from the container metadata.
    case undecodableCodec(fourCC: String)

    /// Single source of truth for the re-encode advice, so the two codec
    /// failures can't drift apart. ProRes 4444 is the recommendation
    /// because it is natively decoded on every Mac, keeps 4:4:4 chroma
    /// (no subsampling before stacking), and measures effectively
    /// lossless — 0.09% RMS error on an 8-bit round trip.
    static let reencodeHint = "ffmpeg -i input -c:v prores_ks -profile:v 4444 output.mov"

    var description: String {
        switch self {
        case .cannotOpen(let url):
            return "cannot open \(url.lastPathComponent)"
        case .noVideoTrack:
            return "no AVFoundation-decodable video track (SharpCap-style rawvideo / pal8 AVIs need re-encoding to ProRes or H.264 first; see ffmpeg one-liner in source comments)"
        case .unknownDuration:
            return "container reports zero / invalid duration"
        case .decodeFailed(let f):
            return """
                frame \(f) decode failed — macOS accepted this video's codec but could not produce an image from it (Motion JPEG does this). Re-encode to ProRes:
                  \(Self.reencodeHint)
                """
        case .undecodableCodec(let fourCC):
            return """
                video codec '\(fourCC)' cannot be decoded by macOS. Re-encode to ProRes (visually lossless) or H.264:
                  \(Self.reencodeHint)
                """
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
        // Reject an undecodable codec HERE rather than letting every frame
        // fail later. `isDecodable` answers "can this machine decode this
        // track", which is exactly the question — the container parses, the
        // duration and frame count read back fine, and only the pixels are
        // unreachable. Naming the codec turns an inscrutable failure into
        // an actionable one.
        guard track.isDecodable else {
            throw AviReaderError.undecodableCodec(fourCC: Self.codecName(of: track))
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

    /// The track's codec as a readable four-character code (`FFV1`, `avc1`,
    /// `ap4h`, …). CMFormatDescription stores the media subtype as a packed
    /// big-endian FourCC; unpack it back into characters so the error names
    /// something the user can search for. Falls back to "unknown" when the
    /// track carries no format description.
    private static func codecName(of track: AVAssetTrack) -> String {
        guard let desc = track.formatDescriptions.first else { return "unknown" }
        // swiftlint:disable:next force_cast
        let subtype = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
        let bytes = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF),
        ]
        // Non-printable bytes mean this isn't a conventional FourCC; show
        // the numeric value rather than control characters.
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return "0x\(String(subtype, radix: 16))"
        }
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }

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
