// Auto-ROI PSF estimator (Block C.2).
//
// Extends AutoPSF beyond planetary discs by finding the strongest
// robust step edge anywhere in the frame and measuring its
// perpendicular line-spread function (LSF). Designed as a fallback
// for `AutoPSF.estimate`, which bails on lunar / textured / cropped
// subjects per `feedback_autopsf_lunar_bail.md`.
//
// Algorithm:
//   1. Sobel gradient → magnitude + direction.
//   2. Top-K candidate pixels by gradient magnitude (95th percentile
//      threshold + non-max suppression along the gradient direction).
//      Reject candidates that are too close to the frame edge or
//      adjacent to saturated highlights.
//   3. Score each candidate for edge cleanliness — circular-std of
//      gradient direction across a 9×9 patch + step contrast across
//      the edge. Pick the highest-scoring candidate.
//   4. Slanted-edge LSF measurement at the winning ROI: 21 parallel
//      sample lines along the edge tangent, each ±6 px in the
//      perpendicular direction. First-difference of the perpendicular
//      profile gives a 1D LSF; averaging across the parallel lines
//      delivers a sub-pixel-robust estimate via the same bilinear-
//      interpolation trick the slanted-edge MTF (ISO 12233) uses.
//   5. σ via second-moment integration of the averaged LSF, with the
//      tail median subtracted as a baseline (same trick as the
//      planetary `AutoPSF` path).
//   6. Conservative bail-outs: peak contrast, direction stability,
//      single-peak alignment with the candidate, σ inside [0.5, 5.0],
//      and confidence (peak above baseline / baseline floor) ≥ 3.
//
// Default OFF — opted into via `LuckyStackOptions.useAutoPSFAutoROI`
// (CLI `--auto-psf-roi`, GUI sub-toggle). The bail-out memory is
// unambiguous: a wrong σ is worse than nothing, so v0 leans hard on
// returning nil whenever the chosen ROI doesn't look like a clean
// step. Wiener post-pass with this σ runs WITHOUT the radial-fade
// filter (RFF) — RFF assumes planetary disc geometry and would
// over-fade an arbitrary interior edge.
import Foundation
import Metal

enum AutoPSFAutoROI {

    struct Result {
        /// Estimated PSF stddev in pixels. Clamped to [0.5, 5.0].
        let sigma: Float
        /// LSF peak-above-baseline / baseline. Same heuristic shape as
        /// `AutoPSF.Result.confidence`. >5 reliable; <2 is noise floor.
        let confidence: Float
        /// Edge ROI pixel center (image coords). Cosmetic — for logging.
        let edgePoint: SIMD2<Float>
        /// Unit normal pointing toward the bright side. Cosmetic — for
        /// logging and for any future per-edge geometry-aware deconv.
        let edgeNormal: SIMD2<Float>
        /// Direction stability of the chosen ROI (degrees). <12° passes
        /// the gate; surfaced for diagnostic logging.
        let dirStdDeg: Float
        /// Step contrast across the chosen edge (linear luminance units).
        /// >0.05 passes the gate.
        let stepContrast: Float
    }

    /// Estimate from a luminance buffer. Pure Swift so the unit-test
    /// target can exercise the algorithm without spinning up a Metal
    /// device. Returns nil when no ROI passes the cleanliness gates —
    /// callers should preserve the bare stack on nil rather than
    /// running Wiener with a wrong σ.
    static func estimate(
        luminance: [Float],
        width W: Int,
        height H: Int
    ) -> Result? {
        precondition(luminance.count == W * H, "AutoPSFAutoROI: buffer / dim mismatch")
        // Need enough room for the LSF window (±6 px perpendicular,
        // ±10 px along the edge tangent) plus a safety margin from
        // the frame edge.
        let border = 16
        guard W >= 2 * border + 32, H >= 2 * border + 32 else { return nil }

        // Reject pure-empty / pure-black inputs early.
        var lumaMax: Float = 0
        for v in luminance where v > lumaMax { lumaMax = v }
        guard lumaMax > 0.02 else { return nil }

        // Saturation cap: anything within 2% of the per-frame max is
        // treated as potentially clipped. Edges adjacent to clipped
        // pixels break the Gaussian-fit assumption (the bright side
        // is missing its true peak amplitude).
        let saturationThreshold = max(0.95, lumaMax * 0.98)

        // Step 1: Sobel gradient over the whole frame. Margins of 1 px
        // on each side are unwritten (Sobel kernel is 3×3); the later
        // candidate scan respects `border` so this doesn't matter.
        var gradMag = [Float](repeating: 0, count: W * H)
        var gradX = [Float](repeating: 0, count: W * H)
        var gradY = [Float](repeating: 0, count: W * H)
        for y in 1..<(H - 1) {
            let rowM = (y - 1) * W
            let row0 = y * W
            let rowP = (y + 1) * W
            for x in 1..<(W - 1) {
                let p00 = luminance[rowM + x - 1]
                let p10 = luminance[rowM + x]
                let p20 = luminance[rowM + x + 1]
                let p01 = luminance[row0 + x - 1]
                let p21 = luminance[row0 + x + 1]
                let p02 = luminance[rowP + x - 1]
                let p12 = luminance[rowP + x]
                let p22 = luminance[rowP + x + 1]
                let gx = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02)
                let gy = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20)
                let mag = sqrtf(gx * gx + gy * gy)
                let idx = row0 + x
                gradX[idx] = gx
                gradY[idx] = gy
                gradMag[idx] = mag
            }
        }

        // Step 2: candidate threshold = 30% of peak gradient (with an
        // absolute floor of 0.01 to reject pure-noise frames). Using
        // a percentile here was wrong: for thin edges (a single
        // horizontal line in a 200×200 frame) only ~5% of pixels have
        // non-zero gradient, so the 95th percentile falls into the
        // FP-noise floor (~3e-4) rather than picking out the edge
        // band. Anchoring on the peak gradient lets a single strong
        // edge surface no matter how small a fraction of the frame
        // it occupies.
        var pMax: Float = 0
        for y in border..<(H - border) {
            let row = y * W
            for x in border..<(W - border) {
                let m = gradMag[row + x]
                if m > pMax { pMax = m }
            }
        }
        guard pMax > 0.01 else { return nil }
        let edgeThreshold = max(pMax * 0.3, 0.01)

        // Build candidate list with non-max suppression along the
        // gradient direction. Cap the post-NMS list at top 50 so the
        // scoring loop stays bounded — the strongest 50 edges across
        // any reasonable astronomical frame include every plausible
        // PSF-fitting candidate.
        struct Candidate {
            let x: Int
            let y: Int
            let mag: Float
            let nx: Float    // unit normal (gradient direction)
            let ny: Float
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(256)
        for y in border..<(H - border) {
            let row = y * W
            for x in border..<(W - border) {
                let m = gradMag[row + x]
                if m < edgeThreshold { continue }
                let gx = gradX[row + x]
                let gy = gradY[row + x]
                let inv = 1.0 / max(m, 1e-6)
                let nx = gx * inv
                let ny = gy * inv

                // Non-max suppression — sample neighbours at ±1 along
                // the gradient direction; if either is stronger this
                // pixel isn't the local edge peak.
                let xa = Float(x) + nx
                let ya = Float(y) + ny
                let xb = Float(x) - nx
                let yb = Float(y) - ny
                let ma = bilinearSample(gradMag, W, H, xa, ya)
                let mb = bilinearSample(gradMag, W, H, xb, yb)
                if ma > m || mb > m { continue }

                // Reject if any pixel within a 5×5 neighbourhood is
                // saturation-clipped — would break the Gaussian fit.
                if hasSaturatedNeighbor(luminance, W, H, x, y, threshold: saturationThreshold) {
                    continue
                }

                candidates.append(Candidate(x: x, y: y, mag: m, nx: nx, ny: ny))
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.mag > $1.mag }
        let topK = Array(candidates.prefix(50))

        // Step 3: score each top-K candidate. Score combines magnitude-
        // weighted gradient-direction stability across a 9×9 patch
        // (low std = a single dominant edge orientation, not a corner /
        // junction / texture noise) with the across-edge step contrast
        // (high = a clean dark/bright transition, not a faint ramp).
        struct Scored {
            let cand: Candidate
            let dirStdDeg: Float
            let stepContrast: Float
            let score: Float
        }
        var bestScored: Scored? = nil
        for c in topK {
            let (dirStd, stepC) = scoreCandidate(
                gradMag: gradMag, gradX: gradX, gradY: gradY,
                luma: luminance, W: W, H: H,
                cx: c.x, cy: c.y, nx: c.nx, ny: c.ny
            )
            // Score: stepContrast / (1 + dirStdDeg / 10). High contrast
            // wins; >10° direction wobble rolls off the score linearly.
            let s = stepC / (1.0 + dirStd / 10.0)
            if bestScored == nil || s > bestScored!.score {
                bestScored = Scored(cand: c, dirStdDeg: dirStd, stepContrast: stepC, score: s)
            }
        }
        guard let best = bestScored else { return nil }

        // Cleanliness gates:
        //   - direction stability < 12° (single dominant edge orientation)
        //   - step contrast > 0.05 (real bright/dark transition)
        if best.dirStdDeg > 12 { return nil }
        if best.stepContrast < 0.05 { return nil }

        // Step 4: slanted-edge LSF — sample 21 parallel lines along the
        // edge tangent, each spanning ±6 px in the perpendicular
        // direction (the gradient normal). The geometry:
        //
        //          tangent (k changes)
        //         ─┼─┼─┼─┼─┼─┼─►
        //          .  edge (k=0)  .
        //          ▼ normal (j changes)
        //
        // A perfectly axis-aligned edge produces no sub-pixel
        // averaging benefit, but the per-line averaging still kills
        // measurement noise. Slightly-skewed edges deliver the full
        // ISO-12233 sub-pixel benefit because the bilinear samples
        // along each line are at slightly different sub-pixel phases.
        let nx = best.cand.nx
        let ny = best.cand.ny
        let tx = -ny       // edge tangent (90° rotation of normal)
        let ty = nx
        let cx = Float(best.cand.x)
        let cy = Float(best.cand.y)

        // halfWindow=10 covers σ up to ~5.0 (the upper clamp) at >2σ
        // outside the LSF peak — i.e., the integration captures the
        // full Gaussian energy without truncation. Keeping the window
        // tight (was 6) underestimated soft (σ=3.5) edges by ~30 %.
        let nLines = 21
        let halfWindow = 10
        let nSamples = halfWindow * 2 + 1
        var lsfSum = [Float](repeating: 0, count: nSamples)
        var lsfCount = [Int](repeating: 0, count: nSamples)

        for k in 0..<nLines {
            let tOffset = Float(k - nLines / 2)
            // Sample the perpendicular profile.
            var prof = [Float](repeating: 0, count: nSamples)
            var profOK = true
            for j in 0..<nSamples {
                let pOffset = Float(j - halfWindow)
                let sx = cx + tOffset * tx + pOffset * nx
                let sy = cy + tOffset * ty + pOffset * ny
                if sx < 1 || sx >= Float(W - 2) || sy < 1 || sy >= Float(H - 2) {
                    profOK = false
                    break
                }
                prof[j] = bilinearSample(luminance, W, H, sx, sy)
            }
            guard profOK else { continue }
            // First-difference → LSF magnitude. Center-difference would
            // be more accurate but the j-1 offset is consistent across
            // lines, so the second-moment integration absorbs the
            // half-pixel shift.
            for j in 1..<nSamples {
                lsfSum[j] += abs(prof[j] - prof[j - 1])
                lsfCount[j] += 1
            }
        }

        var lsf = [Float](repeating: 0, count: nSamples)
        for j in 0..<nSamples where lsfCount[j] > 0 {
            lsf[j] = lsfSum[j] / Float(lsfCount[j])
        }

        // Locate the LSF peak. Should sit close to the geometric center
        // (j = halfWindow) since the candidate IS the edge pixel; an
        // offset > 2 px means the gradient direction estimate was off
        // and the perpendicular sweep didn't actually cross the edge
        // at the expected phase — bail.
        var peakJ = halfWindow
        var peakV: Float = 0
        for j in 1..<nSamples where lsf[j] > peakV {
            peakV = lsf[j]
            peakJ = j
        }
        guard peakV > 0.005 else { return nil }
        if abs(peakJ - halfWindow) > 2 { return nil }

        // Step 5: σ via second-moment integration. Symmetric ±8 window
        // around the peak (covers σ up to ~5.0 — the upper clamp —
        // with >2σ tail capture). Tail median (samples beyond ±8 from
        // the peak) used as the baseline subtraction so the moment
        // ratio measures peak-above-noise rather than peak+noise.
        let intHalf = 8
        var tail: [Float] = []
        for j in 0..<nSamples where lsfCount[j] > 0 {
            if abs(j - peakJ) > intHalf { tail.append(lsf[j]) }
        }
        var baseline: Float = 0
        if !tail.isEmpty {
            tail.sort()
            baseline = tail[tail.count / 2]
        }

        let lo = max(1, peakJ - intHalf)
        let hi = min(nSamples - 1, peakJ + intHalf)
        var M0: Double = 0
        var M2: Double = 0
        for j in lo...hi {
            let v = max(0, Double(lsf[j] - baseline))
            let dr = Double(j - peakJ)
            M0 += v
            M2 += dr * dr * v
        }
        guard M0 > 1e-6 else { return nil }
        let sigmaRaw = sqrt(M2 / M0)
        let sigmaClamped = Float(max(0.5, min(5.0, sigmaRaw)))

        // Step 6: confidence — same shape as the planetary AutoPSF
        // path, so users see one consistent number across estimators.
        let baselineFloor = max(baseline, 1e-4)
        let confidence = max(0, peakV - baseline) / baselineFloor
        if confidence < 3 { return nil }

        return Result(
            sigma: sigmaClamped,
            confidence: confidence,
            edgePoint: SIMD2<Float>(cx, cy),
            edgeNormal: SIMD2<Float>(nx, ny),
            dirStdDeg: best.dirStdDeg,
            stepContrast: best.stepContrast
        )
    }

    // MARK: - private helpers

    private static func bilinearSample(
        _ buf: [Float], _ W: Int, _ H: Int,
        _ x: Float, _ y: Float
    ) -> Float {
        let xi0 = Int(floorf(x))
        let yi0 = Int(floorf(y))
        let xi1 = xi0 + 1
        let yi1 = yi0 + 1
        guard xi0 >= 0, yi0 >= 0, xi1 < W, yi1 < H else { return 0 }
        let fx = x - Float(xi0)
        let fy = y - Float(yi0)
        let v00 = buf[yi0 * W + xi0]
        let v10 = buf[yi0 * W + xi1]
        let v01 = buf[yi1 * W + xi0]
        let v11 = buf[yi1 * W + xi1]
        return (1 - fx) * (1 - fy) * v00
            + fx * (1 - fy) * v10
            + (1 - fx) * fy * v01
            + fx * fy * v11
    }

    private static func hasSaturatedNeighbor(
        _ buf: [Float], _ W: Int, _ H: Int,
        _ x: Int, _ y: Int, threshold: Float
    ) -> Bool {
        for dy in -2...2 {
            let yy = y + dy
            if yy < 0 || yy >= H { continue }
            let row = yy * W
            for dx in -2...2 {
                let xx = x + dx
                if xx < 0 || xx >= W { continue }
                if buf[row + xx] >= threshold { return true }
            }
        }
        return false
    }

    /// Returns (direction-stability std in degrees, step contrast).
    ///
    /// Direction stability uses **unsigned-axis** circular statistics
    /// (the doubling trick): for an edge, gradient vectors on either
    /// side of the candidate may point along (+nx, +ny) OR (-nx, -ny)
    /// depending on which side of the edge they sample. Doubling the
    /// angle (φ = 2θ) folds opposite directions onto the same value,
    /// so the magnitude-weighted resultant length R measures axis
    /// stability rather than direction stability. Single-θ averaging
    /// would get confused on the negative side of the edge.
    ///
    /// Step contrast = mean luma 4 px on the +n side vs -n side. 4 px
    /// is far enough outside any plausible PSF (σ ≤ 5 → 1σ at 5 px;
    /// for a clipped step both ends get ~84% of full contrast at 1σ,
    /// so the 0.05 threshold still triggers at any realistic real-
    /// world contrast).
    private static func scoreCandidate(
        gradMag: [Float], gradX: [Float], gradY: [Float],
        luma: [Float], W: Int, H: Int,
        cx: Int, cy: Int, nx: Float, ny: Float
    ) -> (dirStdDeg: Float, stepContrast: Float) {
        var sumSin: Double = 0
        var sumCos: Double = 0
        var sumW: Double = 0
        let refTheta = 2.0 * Double(atan2f(ny, nx))
        for dy in -4...4 {
            let yy = cy + dy
            if yy < 0 || yy >= H { continue }
            let row = yy * W
            for dx in -4...4 {
                let xx = cx + dx
                if xx < 0 || xx >= W { continue }
                let m = gradMag[row + xx]
                if m < 1e-6 { continue }
                let gx = gradX[row + xx]
                let gy = gradY[row + xx]
                let theta = 2.0 * Double(atan2f(gy, gx))
                let dTheta = theta - refTheta
                sumSin += Double(m) * sin(dTheta)
                sumCos += Double(m) * cos(dTheta)
                sumW += Double(m)
            }
        }
        let dirStdDeg: Float
        if sumW < 1e-6 {
            dirStdDeg = 90
        } else {
            let mSin = sumSin / sumW
            let mCos = sumCos / sumW
            let r = sqrt(mSin * mSin + mCos * mCos)
            // Circular std (radians) ≈ √(-2·ln R). Halve because we
            // doubled the angle. Convert to degrees.
            let rClamped = max(min(r, 0.999), 1e-3)
            let stdDoubled = sqrt(max(0, -2.0 * log(rClamped)))
            dirStdDeg = Float(stdDoubled * 0.5 * 180.0 / .pi)
        }

        let plusX = Float(cx) + 4 * nx
        let plusY = Float(cy) + 4 * ny
        let minusX = Float(cx) - 4 * nx
        let minusY = Float(cy) - 4 * ny
        let lp = bilinearSample(luma, W, H, plusX, plusY)
        let lm = bilinearSample(luma, W, H, minusX, minusY)
        let stepContrast = abs(lp - lm)

        return (dirStdDeg, stepContrast)
    }
}

// MARK: - cascade entry point

/// Unified result from the planetary → auto-ROI cascade. LuckyStack
/// branches on the case to decide whether to apply the radial-fade
/// filter (planetary only — RFF assumes disc geometry that doesn't
/// exist for an arbitrary interior edge).
enum AutoPSFEstimate {
    case planetary(AutoPSF.Result)
    case autoROI(AutoPSFAutoROI.Result)

    var sigma: Float {
        switch self {
        case .planetary(let r): return r.sigma
        case .autoROI(let r):   return r.sigma
        }
    }

    var confidence: Float {
        switch self {
        case .planetary(let r): return r.confidence
        case .autoROI(let r):   return r.confidence
        }
    }
}

extension AutoPSF {
    /// Try the planetary limb-LSF estimator first; on bail, optionally
    /// fall through to the auto-ROI estimator. Returns nil when
    /// neither produces a clean σ.
    ///
    /// The fallback is gated by `autoROIFallback` because the auto-ROI
    /// estimator is conservatively designed but still less robust than
    /// the planetary path on planetary inputs (which the planetary
    /// path catches first anyway). Default OFF; opted in by callers
    /// that have validated their pipeline against `feedback_autopsf_lunar_bail.md`.
    static func estimateCascade(
        texture: MTLTexture,
        device: MTLDevice,
        autoROIFallback: Bool
    ) -> AutoPSFEstimate? {
        if let planetary = estimate(texture: texture, device: device) {
            return .planetary(planetary)
        }
        guard autoROIFallback else { return nil }
        guard let (luma, W, H) = readLuminance(texture: texture, device: device) else {
            return nil
        }
        if let roi = AutoPSFAutoROI.estimate(luminance: luma, width: W, height: H) {
            return .autoROI(roi)
        }
        return nil
    }
}
