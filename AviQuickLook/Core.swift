// Standalone AVI frame extractor + auto-stretch for the AstroSharper
// QuickLook AVI thumbnail extension.
//
// macOS already provides a built-in AVI QuickLook generator, but for
// planetary / lunar / solar capture AVIs (FireCapture, SharpCap raw)
// the system's preview is typically a near-black, unstretched first
// frame — visually useless. This extension replaces it with a percentile-
// stretched representative frame that matches the look users get inside
// the AstroSharper app.
//
// NOTE: this extension only registers a thumbnail provider — not a
// preview provider. Spacebar QuickLook on an AVI continues to use the
// system's built-in video preview (which plays the file). We do NOT
// want to replace that since playback is more useful than a still.
//
// Default-app association ("Open With…") is NOT affected. QuickLook
// extension registration is orthogonal to LaunchServices role mapping.

import Foundation
import AVFoundation
import CoreGraphics

enum AviQL {

    /// Pull a representative frame out of an AVI via AVFoundation, then
    /// apply the same 1% / 99.5% percentile auto-stretch the SER
    /// extension uses so both formats render with consistent contrast
    /// in Finder.
    ///
    /// Returns nil for containers AVFoundation can't decode (codec not
    /// installed, corrupt file, etc.) — Finder falls back to the system
    /// AVI thumbnail in that case.
    static func renderRepresentativeFrame(url: URL,
                                          maxDimension: Int = 1024) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        // Sample ~1 s in (or the midpoint, whichever is earlier). Skips
        // the dark / settling frames common at the start of a planetary
        // capture so the percentile stretch has signal to anchor to.
        let duration = asset.duration
        let target: CMTime
        if duration.isValid, !duration.isIndefinite, duration.seconds > 0.5 {
            let secs = min(1.0, duration.seconds / 2.0)
            let scale = duration.timescale > 0 ? duration.timescale : 600
            target = CMTime(seconds: secs, preferredTimescale: scale)
        } else {
            target = .zero
        }

        guard let cg = try? generator.copyCGImage(at: target, actualTime: nil) else {
            return nil
        }
        return autoStretch(cgImage: cg) ?? cg
    }

    /// Render the CGImage into an RGBA8 buffer, compute a 1% / 99.5%
    /// luminance percentile pair, and re-emit a contrast-stretched
    /// CGImage. Hand-rolled (no vImage) so the extension stays
    /// dependency-light inside its tiny XPC.
    private static func autoStretch(cgImage: CGImage) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = pixels.withUnsafeMutableBytes({ buf -> CGContext? in
            guard let base = buf.baseAddress else { return nil }
            return CGContext(data: base,
                             width: w, height: h,
                             bitsPerComponent: 8,
                             bytesPerRow: bytesPerRow,
                             space: cs,
                             bitmapInfo: bitmapInfo)
        }) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hist = [Int](repeating: 0, count: 256)
        let count = w * h
        for i in 0..<count {
            let r = Int(pixels[4*i])
            let g = Int(pixels[4*i + 1])
            let b = Int(pixels[4*i + 2])
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            hist[lum] += 1
        }
        let lowTarget  = count / 100
        let highTarget = count - count / 200

        var cum = 0, lo = 0, hi = 255
        for i in 0..<256 {
            cum += hist[i]
            if cum >= lowTarget { lo = i; break }
        }
        cum = 0
        for i in 0..<256 {
            cum += hist[i]
            if cum >= highTarget { hi = i; break }
        }
        guard hi > lo + 1 else { return cgImage }  // Flat — keep raw.

        let scale = 255.0 / Double(hi - lo)
        for i in 0..<count {
            for c in 0..<3 {
                let v = Int(pixels[4*i + c])
                let s = Int(Double(v - lo) * scale + 0.5)
                pixels[4*i + c] = UInt8(min(255, max(0, s)))
            }
        }
        return ctx.makeImage()
    }
}
