// Half-Flux Radius — radius from a brightness centroid that contains
// half the total flux. Standard star metric, repurposed here for planetary
// discs (where the same math applied to a Jupiter / Saturn / Mars frame
// gives an "effective" HFR that tracks PSF blur in a physically intuitive
// way: lower HFR = sharper).
//
// CPU reference for now (A.5 v0). The full HUD wiring lands in v1 once
// the scanner has texture-readback infrastructure to feed the CPU
// function per sampled frame; for v0 the math + tests are in place so
// the Metal-accelerated path can validate against this.
//
// Algorithm (Pertuz 2013-style):
//   1. Compute the intensity-weighted centroid (cx, cy).
//   2. Bin pixels into 0.5 px-wide annuli around (cx, cy), summing the
//      luminance in each bin.
//   3. Find the bin where the cumulative flux first crosses half of the
//      total flux. The lower edge of that bin is the half-flux radius
//      (units: pixels).
//
// Edge cases:
//   * Empty buffer or all-zero → return 0.
//   * Single bright pixel → centroid is that pixel, half-flux falls
//     inside bin 0 → return 0 (delta-function PSF).
//   * Uniform field — centroid at image centre, HFR is a geometric
//     constant (~0.5 × min(W,H) for a square buffer). Useful sanity
//     test, not a real-world case.
import Foundation

enum HalfFluxRadius {
    /// Compute the half-flux radius (in pixels) of a luminance buffer.
    ///
    /// - Parameters:
    ///   - pixels: row-major luminance buffer of length `width * height`
    ///   - width: image width
    ///   - height: image height
    ///   - binWidth: annulus width in pixels for the radial histogram.
    ///     Default 0.5 — sub-pixel resolution without huge bin counts.
    ///     Smaller values trade precision for compute on tiny inputs.
    /// - Returns: half-flux radius in pixels. 0 when the buffer is empty
    ///   or all-zero, signalling "no useful PSF measurement".
    static func compute(
        luma pixels: [Float],
        width: Int,
        height: Int,
        binWidth: Double = 0.5
    ) -> Float {
        precondition(pixels.count == width * height, "buffer size mismatch")
        guard !pixels.isEmpty, width > 0, height > 0, binWidth > 0 else {
            return 0
        }

        // Pass 1: intensity-weighted centroid.
        var totalFlux: Double = 0
        var sumIX: Double = 0
        var sumIY: Double = 0
        for y in 0..<height {
            let yOffset = y * width
            for x in 0..<width {
                let v = Double(pixels[yOffset + x])
                if v > 0 {
                    totalFlux += v
                    sumIX += v * Double(x)
                    sumIY += v * Double(y)
                }
            }
        }
        guard totalFlux > 0 else { return 0 }
        let cx = sumIX / totalFlux
        let cy = sumIY / totalFlux

        // Pass 2: radial flux histogram. Max radius is the longest
        // distance from the centroid to any corner.
        let maxRadius = max(
            hypot(cx, cy),
            max(
                hypot(Double(width) - cx, cy),
                max(
                    hypot(cx, Double(height) - cy),
                    hypot(Double(width) - cx, Double(height) - cy)
                )
            )
        )
        let binCount = max(1, Int((maxRadius / binWidth).rounded(.up)) + 1)
        var bins = [Double](repeating: 0, count: binCount)
        for y in 0..<height {
            let dy = Double(y) - cy
            let yOffset = y * width
            for x in 0..<width {
                let v = Double(pixels[yOffset + x])
                if v > 0 {
                    let dx = Double(x) - cx
                    let r = (dx * dx + dy * dy).squareRoot()
                    let binIdx = min(binCount - 1, Int(r / binWidth))
                    bins[binIdx] += v
                }
            }
        }

        // Pass 3: cumulative scan, find the bin where cumulative ≥ half.
        let halfTotal = totalFlux * 0.5
        var cumul: Double = 0
        for (i, b) in bins.enumerated() {
            cumul += b
            if cumul >= halfTotal {
                // Linear interpolation inside the crossing bin: the bin
                // accumulates at a steady rate from `cumul - b` (start)
                // to `cumul` (end) across the bin's width. We want the
                // r where cumul == halfTotal exactly.
                let beforeBin = cumul - b
                guard b > 0 else { return Float(Double(i) * binWidth) }
                let frac = (halfTotal - beforeBin) / b   // 0…1 inside this bin
                let r = (Double(i) + frac) * binWidth
                return Float(r)
            }
        }
        // Should be unreachable when totalFlux > 0; defensive fallback.
        return Float(maxRadius)
    }
}
