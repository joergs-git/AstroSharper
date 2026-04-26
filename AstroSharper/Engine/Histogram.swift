// 256-bucket luminance histogram of an image file. Computed once per preview
// file load, used by the tone-curve editor overlay and the Stretch button.
//
// Runs off-thread via ImageIO → 8-bit grayscale snapshot (thumbnail-sized), so
// the cost is bounded regardless of the source image's pixel count.
import CoreGraphics
import Foundation
import ImageIO

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
}
