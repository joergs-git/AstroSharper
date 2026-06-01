// 256-bucket luminance histogram of an image file. Computed once per preview
// file load, used by the tone-curve editor overlay and the Stretch button.
//
// Runs off-thread via ImageIO → 8-bit grayscale snapshot (thumbnail-sized), so
// the cost is bounded regardless of the source image's pixel count.
import CoreGraphics
import Foundation
import ImageIO
import Metal

/// Per-channel 256-bucket histograms. Populated for colour images; for
/// monochrome inputs the three channels are identical and ToneCurveEditor
/// falls back to drawing a single luma curve.
struct ChannelHistogram: Equatable {
    var r: [UInt32]
    var g: [UInt32]
    var b: [UInt32]
    /// True when r/g/b differ enough that drawing them as separate
    /// curves is meaningful. Mono captures (R=G=B exactly) trip false
    /// and the editor renders a single curve.
    var isColor: Bool {
        guard r.count == 256, g.count == 256, b.count == 256 else { return false }
        for i in 0..<256 where r[i] != g[i] || g[i] != b[i] { return true }
        return false
    }
}

enum Histogram {
    /// Compute a 256-bucket luminance histogram. The image is thumbnailed to
    /// `maxSide` on its longest side first so cost stays flat for 6k frames.
    static func compute(url: URL, maxSide: Int = 512) -> [UInt32] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return [] }

        let w = cg.width
        let h = cg.height
        let bytesPerRow = w
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: info
        ) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        var hist = [UInt32](repeating: 0, count: 256)
        let total = w * h
        for i in 0..<total {
            hist[Int(ptr[i])] &+= 1
        }
        return hist
    }

    /// Percentile-based stretch endpoints. Returns (lowX, highX) in [0,1] such
    /// that the darkest `lowPercent` and brightest `highPercent` of pixels land
    /// at curve y=0 and y=1 respectively. Useful for auto-stretching dim
    /// astrophotos where the bulk of pixels sits in the bottom 5% of range.
    static func stretchBounds(histogram: [UInt32], lowPercent: Double = 0.5, highPercent: Double = 0.5) -> (CGFloat, CGFloat) {
        guard histogram.count == 256 else { return (0, 1) }
        let total = histogram.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return (0, 1) }

        let lowCut = UInt64(Double(total) * lowPercent / 100.0)
        let highCut = UInt64(Double(total) * (100.0 - highPercent) / 100.0)

        var acc: UInt64 = 0
        var low = 0, high = 255
        for i in 0..<256 {
            acc &+= UInt64(histogram[i])
            if acc >= lowCut { low = i; break }
        }
        acc = 0
        for i in 0..<256 {
            acc &+= UInt64(histogram[i])
            if acc >= highCut { high = i; break }
        }
        if high <= low { high = min(255, low + 1) }
        return (CGFloat(low) / 255.0, CGFloat(high) / 255.0)
    }

    /// Per-channel R/G/B histograms (each 256 buckets). Cheap single-
    /// pass companion to `compute()` for tools that need colour-aware
    /// curves (Tone Curve editor's per-channel overlay on OSC stacks).
    /// Same ImageIO → thumbnail → 8-bit RGBA path so cost stays bounded.
    static func computeRGB(url: URL, maxSide: Int = 512) -> ChannelHistogram {
        let empty = ChannelHistogram(r: [], g: [], b: [])
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return empty }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return empty }
        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: info
        ) else { return empty }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return empty }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var r = [UInt32](repeating: 0, count: 256)
        var g = [UInt32](repeating: 0, count: 256)
        var b = [UInt32](repeating: 0, count: 256)
        let total = w * h
        for i in 0..<total {
            let off = i * 4
            r[Int(ptr[off])]     &+= 1
            g[Int(ptr[off + 1])] &+= 1
            b[Int(ptr[off + 2])] &+= 1
        }
        return ChannelHistogram(r: r, g: g, b: b)
    }

    /// Per-channel R/G/B histograms read directly from a Metal texture.
    /// Used for SER/AVI scrub frames where ImageIO can't open the
    /// source file, but the engine has already decoded the frame into
    /// a preview texture. Source format must be `rgba16Float` or
    /// `rgba32Float` — the engine's two standard preview formats.
    /// Private-storage textures are blit-copied into a shared-storage
    /// staging texture before readback (getBytes on `.private` silently
    /// hangs). Down-samples implicitly via a sparse stride so the
    /// CPU pass stays bounded on 6 k frames.
    static func computeRGB(
        texture: MTLTexture,
        device: MTLDevice,
        queue: MTLCommandQueue,
        maxSamples: Int = 512 * 512
    ) -> ChannelHistogram {
        let empty = ChannelHistogram(r: [], g: [], b: [])
        let W = texture.width, H = texture.height
        guard W > 0, H > 0 else { return empty }

        // Blit private → shared if needed (getBytes hangs on .private).
        let source: MTLTexture
        if texture.storageMode == .private {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: W, height: H, mipmapped: false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            guard let staging = device.makeTexture(descriptor: desc),
                  let cmd = queue.makeCommandBuffer(),
                  let blit = cmd.makeBlitCommandEncoder() else { return empty }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: .init(x: 0, y: 0, z: 0),
                      sourceSize: .init(width: W, height: H, depth: 1),
                      to: staging, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            source = staging
        } else {
            source = texture
        }

        // Sparse stride to cap CPU cost: aim for ~maxSamples pixel reads.
        let totalPixels = W * H
        let stride = max(1, Int((Double(totalPixels) / Double(maxSamples)).squareRoot()))
        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: W, height: H, depth: 1))
        var r = [UInt32](repeating: 0, count: 256)
        var g = [UInt32](repeating: 0, count: 256)
        var b = [UInt32](repeating: 0, count: 256)

        switch source.pixelFormat {
        case .rgba16Float:
            var buf = [UInt16](repeating: 0, count: W * H * 4)
            source.getBytes(&buf, bytesPerRow: W * 8, from: region, mipmapLevel: 0)
            // Convert IEEE half → float per pixel. Inline conversion for
            // speed; only the strided pixels actually decode.
            for y in stride.strided(from: 0, through: H - 1) {
                let rowBase = y * W * 4
                for x in stride.strided(from: 0, through: W - 1) {
                    let off = rowBase + x * 4
                    let rh = halfToFloat(buf[off])
                    let gh = halfToFloat(buf[off + 1])
                    let bh = halfToFloat(buf[off + 2])
                    r[bucket(rh)] &+= 1
                    g[bucket(gh)] &+= 1
                    b[bucket(bh)] &+= 1
                }
            }
        case .rgba32Float:
            var buf = [Float](repeating: 0, count: W * H * 4)
            source.getBytes(&buf, bytesPerRow: W * 16, from: region, mipmapLevel: 0)
            for y in stride.strided(from: 0, through: H - 1) {
                let rowBase = y * W * 4
                for x in stride.strided(from: 0, through: W - 1) {
                    let off = rowBase + x * 4
                    r[bucket(buf[off])]     &+= 1
                    g[bucket(buf[off + 1])] &+= 1
                    b[bucket(buf[off + 2])] &+= 1
                }
            }
        default:
            return empty
        }
        return ChannelHistogram(r: r, g: g, b: b)
    }

    @inline(__always)
    private static func bucket(_ v: Float) -> Int {
        let clamped = max(0.0, min(1.0, Float(v)))
        return min(255, Int(clamped * 255.0))
    }

    /// IEEE 754 binary16 → Float32. Compact decoder for the
    /// rgba16Float texture readback path.
    @inline(__always)
    private static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) & 0x0001
        let expo = UInt32(h >> 10) & 0x001f
        let mant = UInt32(h) & 0x03ff
        var bits: UInt32
        if expo == 0 {
            if mant == 0 {
                bits = sign << 31
            } else {
                // Subnormal — normalise.
                var m = mant; var e: UInt32 = 0
                while (m & 0x0400) == 0 { m <<= 1; e &+= 1 }
                m &= 0x03ff
                bits = (sign << 31) | ((127 - 15 - e + 1) << 23) | (m << 13)
            }
        } else if expo == 31 {
            bits = (sign << 31) | 0x7f800000 | (mant << 13)
        } else {
            bits = (sign << 31) | ((expo + (127 - 15)) << 23) | (mant << 13)
        }
        return Float(bitPattern: bits)
    }
}

private extension Int {
    /// Stride-iteration helper since stride(from:through:by:) wants by.
    func strided(from start: Int, through end: Int) -> StrideThrough<Int> {
        return Swift.stride(from: start, through: end, by: self)
    }
}
