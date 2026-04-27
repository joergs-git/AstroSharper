// PSF auto-ROI detection for blind / tiled deconvolution.
//
// BiggSky's "Auto ROI" finds a high-contrast region with stable image
// structure (a lunar crater interior, a planetary surface band) and
// avoids:
//   * the image border (frequency-domain edge artefacts contaminate
//     the PSF estimate)
//   * saturated regions (planetary limb glare, solar limb darkening)
//
// We score candidate square windows by the sum of LAPD-magnitudes
// inside — same "diagonal Laplacian" operator the quality probe and
// LuckyStack grader use, so the metric is consistent across the app.
// The best-scoring window that doesn't violate the border / saturation
// constraints wins.
//
// Pure-CPU + Foundation. Inputs are typically downsampled (256² or so)
// to keep the search cheap; the chosen ROI gets scaled back up to the
// full-resolution coordinates by the caller.
import Foundation

/// Top-left + size of an auto-detected ROI in pixels.
struct ROIRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    /// Convenience for callers needing a CGRect for CIImage / SwiftUI
    /// drawing. Same semantics — top-left origin, pixel coordinates.
    var asCGRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum AutoROI {

    /// Find the best square ROI of side length `roiSize` in `luma`.
    ///
    /// - Parameters:
    ///   - luma: row-major luminance buffer (`width * height` Floats).
    ///   - width, height: image dimensions.
    ///   - roiSize: edge length of the candidate windows. The returned
    ///     ROI is always exactly `roiSize × roiSize` if non-nil.
    ///   - borderInset: pixels of border to exclude from the search.
    ///     Default 0 — caller can request e.g. 16 px to avoid the
    ///     ringing edge a deconvolved input would carry.
    ///   - saturationThreshold: pixel value above which the window is
    ///     rejected (limb glare etc.). 0.95 = "any pixel ≥ 95 % of full
    ///     scale disqualifies this window". Set to a value > 1 to
    ///     disable.
    ///   - stride: how far apart candidate top-left positions are
    ///     spaced. 1 = exhaustive (slow on big inputs); 8 or 16 = fast
    ///     for the typical 256² downsampled probe.
    /// - Returns: `ROIRect` for the best window, or nil when no window
    ///   fits the constraints (image too small, all-uniform, every
    ///   candidate saturates).
    static func bestROI(
        luma: [Float],
        width: Int,
        height: Int,
        roiSize: Int,
        borderInset: Int = 0,
        saturationThreshold: Float = 0.95,
        stride: Int = 1
    ) -> ROIRect? {
        precondition(luma.count == width * height, "buffer size mismatch")
        guard roiSize > 0, stride > 0 else { return nil }
        guard width >= roiSize + 2 * borderInset,
              height >= roiSize + 2 * borderInset
        else { return nil }

        let xMin = borderInset
        let yMin = borderInset
        let xMax = width  - roiSize - borderInset
        let yMax = height - roiSize - borderInset
        guard xMax >= xMin, yMax >= yMin else { return nil }

        // bestScore starts at 0 so a uniform-flat input (every window
        // scores LAPD = 0) returns nil rather than (0, 0). Caller can
        // fall back to the image centre when no contrasty window
        // exists.
        var bestScore: Double = 0
        var bestX = -1
        var bestY = -1

        var y = yMin
        while y <= yMax {
            var x = xMin
            while x <= xMax {
                let result = scoreWindow(
                    luma: luma, width: width,
                    x: x, y: y, size: roiSize,
                    saturationThreshold: saturationThreshold
                )
                if let score = result, score > bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
                x += stride
            }
            y += stride
        }

        guard bestX >= 0, bestY >= 0 else { return nil }
        return ROIRect(x: bestX, y: bestY, width: roiSize, height: roiSize)
    }

    /// Score one window by sum of |LAPD| over its interior.
    ///
    /// Returns nil when the window contains a saturated pixel; the
    /// caller treats that as a disqualified window.
    private static func scoreWindow(
        luma: [Float],
        width: Int,
        x: Int,
        y: Int,
        size: Int,
        saturationThreshold: Float
    ) -> Double? {
        var score: Double = 0
        for j in 1..<(size - 1) {
            let row = y + j
            let rowOff = row * width
            for i in 1..<(size - 1) {
                let col = x + i
                let v = luma[rowOff + col]
                if v >= saturationThreshold {
                    return nil
                }
                // LAPD: same kernel as the quality probe. Reused so
                // ROI selection and frame ranking agree on "what is a
                // contrasty pixel."
                let l  = luma[rowOff + (col - 1)]
                let r  = luma[rowOff + (col + 1)]
                let t  = luma[(row - 1) * width + col]
                let b  = luma[(row + 1) * width + col]
                let tl = luma[(row - 1) * width + (col - 1)]
                let tr = luma[(row - 1) * width + (col + 1)]
                let bl = luma[(row + 1) * width + (col - 1)]
                let br = luma[(row + 1) * width + (col + 1)]
                let lap = (l + r + t + b)
                        + 0.5 * (tl + tr + bl + br)
                        - 6.0 * v
                score += Double(abs(lap))
            }
        }
        return score
    }
}
