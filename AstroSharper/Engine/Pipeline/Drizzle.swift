// Drizzle (variable-pixel linear reconstruction) — Fruchter & Hook 2002.
//
// Each input pixel is treated as a value sampled by a square "drop"
// smaller than the input pixel itself (controlled by `pixfrac` ∈
// (0, 1]). The drop is splatted onto an upsampled output grid; the
// random sub-pixel shifts between aligned input frames cause
// different drops to land at different sub-pixel positions, so the
// integrated output preserves more information than a plain
// resampling could. For undersampled subjects (lunar / solar surface
// captures at 0.5–1.5 "/px) drizzle recovers detail beyond the
// nominal sampling limit.
//
// Algorithm per input pixel (xi, yi) with value V and sub-pixel
// shift (sx, sy):
//   1. Drop centre in output coords:
//        cx = (xi + 0.5 + sx) * scale
//        cy = (yi + 0.5 + sy) * scale
//   2. Drop half-size in output coords:
//        h = 0.5 * pixfrac * scale
//   3. For each output pixel (xo, yo) overlapping the drop:
//        overlap_area = clamp(min(xo+1, cx+h) - max(xo, cx-h), 0, 1)
//                     * clamp(min(yo+1, cy+h) - max(yo, cy-h), 0, 1)
//        sum[(xo, yo)]    += V * overlap_area
//        weight[(xo, yo)] += overlap_area
//   4. After all input pixels are splatted:
//        output[(xo, yo)] = sum / weight   (0 where weight = 0)
//
// Multiple input frames accumulate into the same `sum` / `weight`
// buffers — a 5000-frame stack with random alignment shifts becomes
// a dense super-sampled output without a separate interpolation step.
//
// Pure-CPU + Foundation. The Metal kernel that lands in LuckyStack
// mirrors this CPU reference for validation.
import Foundation

/// Accumulator state for an in-progress drizzle stack. Use
/// `Drizzle.makeAccumulator(...)`, splat one or more frames into it
/// with `Drizzle.splat(...)`, then resolve via `Drizzle.finalize(...)`.
struct DrizzleAccumulator: Equatable {
    let outWidth: Int
    let outHeight: Int
    let scale: Int
    var sum: [Float]
    var weight: [Float]
}

enum Drizzle {

    /// BiggSky's documented planetary defaults call out 1.5× as the
    /// commonly-useful drizzle factor; AS!4 also exposes 2× and 3×.
    /// Below 1× drizzle is a no-op; above 3× the kept-frame count
    /// usually can't fill the upsampled grid densely enough.
    static let defaultPixfrac: Float = 0.7

    /// Build a fresh accumulator for an output of size
    /// `inputWidth * scale × inputHeight * scale`.
    static func makeAccumulator(
        inputWidth: Int,
        inputHeight: Int,
        scale: Int
    ) -> DrizzleAccumulator {
        precondition(scale >= 1, "drizzle scale must be ≥ 1")
        precondition(inputWidth >= 0 && inputHeight >= 0, "negative dims")
        let w = inputWidth * scale
        let h = inputHeight * scale
        return DrizzleAccumulator(
            outWidth: w,
            outHeight: h,
            scale: scale,
            sum: [Float](repeating: 0, count: w * h),
            weight: [Float](repeating: 0, count: w * h)
        )
    }

    /// Splat one input frame into the accumulator.
    ///
    /// - Parameters:
    ///   - accum: in-out accumulator — sum / weight buffers grow with
    ///     each frame.
    ///   - input: row-major input pixel buffer (`inputWidth * inputHeight`).
    ///   - inputWidth, inputHeight: input dimensions; must match
    ///     `accum.outWidth / scale` etc.
    ///   - pixfrac: drop size relative to the input pixel
    ///     (0 < pixfrac ≤ 1). 1.0 reproduces nearest-neighbour
    ///     upsampling; 0.5–0.7 are the typical drizzle values.
    ///   - shiftX, shiftY: sub-pixel shift in INPUT pixels. Same sign
    ///     convention as Align.AlignShift.
    static func splat(
        _ accum: inout DrizzleAccumulator,
        input: [Float],
        inputWidth: Int,
        inputHeight: Int,
        pixfrac: Float = defaultPixfrac,
        shiftX: Float = 0,
        shiftY: Float = 0
    ) {
        precondition(input.count == inputWidth * inputHeight, "input size mismatch")
        precondition(accum.outWidth  == inputWidth  * accum.scale, "output width mismatch")
        precondition(accum.outHeight == inputHeight * accum.scale, "output height mismatch")
        guard pixfrac > 0, pixfrac <= 1.0 else { return }
        guard shiftX.isFinite, shiftY.isFinite else { return }

        let scale = Float(accum.scale)
        let halfDrop = 0.5 * pixfrac * scale
        let outW = accum.outWidth
        let outH = accum.outHeight

        for yi in 0..<inputHeight {
            for xi in 0..<inputWidth {
                let v = input[yi * inputWidth + xi]
                if v == 0 { continue }   // skip empty samples (huge perf win for sparse inputs)

                // Drop centre in output coords.
                let cx = (Float(xi) + 0.5 + shiftX) * scale
                let cy = (Float(yi) + 0.5 + shiftY) * scale
                let dropMinX = cx - halfDrop
                let dropMaxX = cx + halfDrop
                let dropMinY = cy - halfDrop
                let dropMaxY = cy + halfDrop

                // Output pixel range that could overlap.
                let xLo = Swift.max(0, Int(floor(dropMinX)))
                let xHi = Swift.min(outW - 1, Int(floor(dropMaxX)))
                let yLo = Swift.max(0, Int(floor(dropMinY)))
                let yHi = Swift.min(outH - 1, Int(floor(dropMaxY)))
                guard xLo <= xHi, yLo <= yHi else { continue }

                for yo in yLo...yHi {
                    let pixelMinY = Float(yo)
                    let pixelMaxY = Float(yo) + 1
                    let yOverlap = Swift.max(0, Swift.min(dropMaxY, pixelMaxY) - Swift.max(dropMinY, pixelMinY))
                    if yOverlap <= 0 { continue }
                    let yOff = yo * outW
                    for xo in xLo...xHi {
                        let pixelMinX = Float(xo)
                        let pixelMaxX = Float(xo) + 1
                        let xOverlap = Swift.max(0, Swift.min(dropMaxX, pixelMaxX) - Swift.max(dropMinX, pixelMinX))
                        if xOverlap <= 0 { continue }
                        let area = xOverlap * yOverlap
                        accum.sum[yOff + xo]    += v * area
                        accum.weight[yOff + xo] += area
                    }
                }
            }
        }
    }

    /// Resolve the accumulator: `output = sum / weight`. Pixels with
    /// weight 0 (no drop ever covered them) come back as 0 — the
    /// caller can fill them with neighbour-average / background later.
    static func finalize(_ accum: DrizzleAccumulator) -> [Float] {
        var out = [Float](repeating: 0, count: accum.sum.count)
        for i in 0..<accum.sum.count {
            let w = accum.weight[i]
            out[i] = w > 0 ? accum.sum[i] / w : 0
        }
        return out
    }
}
