// Adaptive alignment-point (AP) planner.
//
// PSS's `alignment_points.py` constructs a staggered mesh and drops
// cells with low contrast / dim luminance — there's no point running
// per-AP correlation on a featureless polar region or empty sky tile.
// AstroSharper's existing multi-AP grid is rectangular and
// unconditional; this planner adds the "auto-rejection" step:
//
//   1. Score every cell by local LAPD-magnitude sum (sharp features)
//      AND mean luma (foreground vs. sky).
//   2. Drop cells below the luma cutoff outright.
//   3. Drop the bottom `rejectFraction` of remaining cells by score.
//   4. Return a Bool mask the GPU accumulator honours per AP.
//
// Pure-CPU + Foundation. Output is a flat row-major Bool array of
// length `apGrid × apGrid`, indexed by `row * apGrid + col`. Falls
// back gracefully on degenerate inputs (uniform field → no APs;
// tiny image → no APs).
//
// The Metal accumulator lands C.3-style support for the sparse mask
// later; for now downstream code can call `keptCellCount` and
// `enabledAPCells` to drive its kernel dispatch.
import Foundation

struct APPlannerResult: Equatable {
    /// Edge length of the AP grid in cells. The mask has
    /// `apGrid × apGrid` entries.
    let apGrid: Int
    /// Mask: `mask[row * apGrid + col] == true` → AP enabled.
    let mask: [Bool]
    /// Per-cell LAPD-magnitude scores in the same indexing as `mask`.
    /// Useful for diagnostics and HUD heatmap overlays.
    let scores: [Float]

    /// Number of cells that passed the rejection rules.
    var keptCellCount: Int {
        mask.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    /// Indices (in `mask` order) of the cells that passed.
    var enabledAPCells: [Int] {
        mask.enumerated().compactMap { $1 ? $0 : nil }
    }
}

enum APPlanner {

    /// Default fraction of cells (after the luma cutoff) that get
    /// rejected as "dimmest contrast". 0.20 = bottom 20% dropped.
    /// Tunable per the user's preset; PSS's similar setting sits around
    /// 0.15–0.30 depending on subject type.
    static let defaultRejectFraction: Double = 0.20

    /// Default minimum mean-luma fraction (vs the per-frame max) for
    /// a cell to even be considered. 0.05 = "cell mean must be ≥ 5%
    /// of the brightest pixel in the frame". Below that we treat the
    /// cell as background sky / dark gap.
    static let defaultMinLumaFraction: Float = 0.05

    /// Build the AP mask for a reference frame.
    ///
    /// - Parameters:
    ///   - luma: row-major luminance buffer.
    ///   - width, height: image dimensions.
    ///   - apGrid: edge length of the AP grid (e.g. 8 → 8×8 = 64 cells).
    ///     Must be ≥ 1; the function returns an empty mask when it's 0.
    ///   - rejectFraction: 0…1 — drop the bottom-X% of remaining cells
    ///     by score. Default 0.20.
    ///   - minLumaFraction: 0…1 — cells whose mean luma is below this
    ///     fraction of the per-frame maximum are dropped before the
    ///     score-based rejection.
    /// - Returns: an `APPlannerResult` with mask + scores. When the
    ///   image is too small for the requested grid (< 1 px per cell on
    ///   either axis) the mask is all-false.
    static func plan(
        luma: [Float],
        width: Int,
        height: Int,
        apGrid: Int,
        rejectFraction: Double = defaultRejectFraction,
        minLumaFraction: Float = defaultMinLumaFraction
    ) -> APPlannerResult {
        precondition(luma.count == width * height, "buffer size mismatch")
        guard apGrid > 0 else {
            return APPlannerResult(apGrid: 0, mask: [], scores: [])
        }
        let totalCells = apGrid * apGrid

        // Cells smaller than 1 px on either axis are degenerate.
        let cellW = width  / apGrid
        let cellH = height / apGrid
        guard cellW >= 1, cellH >= 1 else {
            return APPlannerResult(
                apGrid: apGrid,
                mask: [Bool](repeating: false, count: totalCells),
                scores: [Float](repeating: 0, count: totalCells)
            )
        }

        // Per-frame peak for the luma cutoff.
        var peak: Float = 0
        for v in luma { if v > peak { peak = v } }
        let lumaCutoff = max(0, minLumaFraction) * peak

        // Score every cell.
        var scores = [Float](repeating: 0, count: totalCells)
        var lumaMeans = [Float](repeating: 0, count: totalCells)
        for row in 0..<apGrid {
            for col in 0..<apGrid {
                let x0 = col * cellW
                let y0 = row * cellH
                let cellResult = scoreCell(
                    luma: luma, width: width,
                    x0: x0, y0: y0, w: cellW, h: cellH
                )
                scores[row * apGrid + col]    = cellResult.score
                lumaMeans[row * apGrid + col] = cellResult.luma
            }
        }

        // Pass 1: luma cutoff.
        var mask = [Bool](repeating: false, count: totalCells)
        for i in 0..<totalCells {
            mask[i] = lumaMeans[i] >= lumaCutoff
        }

        // Pass 2: drop the bottom `rejectFraction` of the remaining
        // cells, by score. We rank only the cells that survived pass 1
        // so a dim background tile with high-LAPD noise doesn't
        // accidentally squeeze out a real surface tile.
        let surviving: [Int] = mask.enumerated().compactMap { $1 ? $0 : nil }
        if !surviving.isEmpty {
            let sortedByScore = surviving.sorted { scores[$0] < scores[$1] }
            let toDrop = max(0, min(sortedByScore.count, Int((rejectFraction * Double(sortedByScore.count)).rounded())))
            for k in 0..<toDrop {
                mask[sortedByScore[k]] = false
            }
        }

        return APPlannerResult(apGrid: apGrid, mask: mask, scores: scores)
    }

    // MARK: - Helpers

    /// Score one cell by sum of |LAPD| over its interior + report its
    /// mean luma. Mirrors the LAPD definition used elsewhere
    /// (Shaders.metal::laplacian_at, SharpnessProbe.referenceVarianceOfLAPD,
    /// AutoROI.scoreWindow) so all "what's contrasty?" decisions agree.
    private static func scoreCell(
        luma: [Float],
        width: Int,
        x0: Int,
        y0: Int,
        w: Int,
        h: Int
    ) -> (score: Float, luma: Float) {
        guard w >= 3, h >= 3 else {
            // Cell too small for the LAPD stencil — score 0 and report
            // the mean.
            var s: Double = 0
            for j in 0..<h {
                for i in 0..<w {
                    s += Double(luma[(y0 + j) * width + (x0 + i)])
                }
            }
            let m = w * h > 0 ? Float(s / Double(w * h)) : 0
            return (0, m)
        }

        var lapdSum: Double = 0
        var lumaSum: Double = 0
        for j in 0..<h {
            let row = y0 + j
            let rowOff = row * width
            for i in 0..<w {
                let col = x0 + i
                lumaSum += Double(luma[rowOff + col])
                guard i >= 1, j >= 1, i < w - 1, j < h - 1 else {
                    continue
                }
                let v  = luma[rowOff + col]
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
                lapdSum += Double(abs(lap))
            }
        }
        let mean = Float(lumaSum / Double(w * h))
        return (Float(lapdSum), mean)
    }
}
