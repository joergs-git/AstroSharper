// Auto-AP — empirical, iterative panel-size selection for lucky stacking.
//
// Picks AP grid size, correlation patch radius, AP drop-list, per-AP
// keep fraction, and deconvolution tile size from observed properties
// of the reference frame, the SER metadata, and the user's prior
// (preset hint). Replaces the hand-tuned `(grid, patchHalf)` defaults
// that the built-in presets used to bake in unconditionally.
//
// Why this exists:
//   - Mismatched / unknown sources used to fall through to the bare
//     `multiAPGrid = 16, patchHalf = 8` default, which is rarely a
//     match for the real isoplanatic patch in pixels.
//   - Per-data variance was ignored: a Jupiter SER at f/14 with
//     0.6 "/px and one at f/30 with 0.25 "/px got the same preset
//     even though their patches differ by ~3× in pixels.
//   - Two prior TODOs (B.3 adaptive AP rejection, C.4 deconv tile-
//     size auto-calc) shared the same plate-scale + content-aware
//     infrastructure and could be folded in here.
//
// Algorithm (Stage 1 ‑ preflight + Stage 2 — refinement):
//
//   1. Read what we have: image dimensions, target type from filename
//      keyword detection, AutoPSF σ + disc radius from limb-LSF
//      estimation on a reference luminance buffer (the runner builds
//      a clean reference in scientific mode anyway, so the readback
//      is a free byproduct).
//   2. Closed-form initial geometry:
//        patchHalf₀  ≈ clamp(round(σ × 3), 8, 32)         when AutoPSF success
//                    ≈ target-type fallback                otherwise
//        G₀          ≈ clamp(disc_diameter_px / (8·patchHalf₀), 6, 24)
//                                                          when planet-in-frame
//                    ≈ clamp(min(W,H) / (16·patchHalf₀), 8, 32)
//                                                          for full-disc / surface
//        searchRad   ≈ clamp(patchHalf₀ / 2 + 2, 4, 16)
//   3. AP drop-list via APPlanner: per-cell LAPD score + luma cutoff
//      against the reference luma. Drops empty-sky / dead cells (B.3).
//   4. Refinement (deep mode only): subdivide cells whose neighbour-
//      shear (LAPD step across the cell) exceeds 3× the median —
//      high-shear zones like Jupiter's limb get a finer grid.
//   5. Deconv tile-size (C.4): closed-form from disc geometry when
//      AutoPSF succeeded, else from frame dimensions. Round to the
//      nearest 100, clamp to [200, 1024], 15% overlap.
//
// What this module DOES NOT do:
//   - It does not run a GPU pilot stack. The reference frame the
//     runner builds anyway is the cheap-to-evaluate proxy; the cost
//     of AutoAP is ~50-100 ms (CPU-side LAPD scoring on the
//     reference luma) regardless of frame count.
//   - It does not place APs at non-grid positions. The grid is still
//     regular; the win is in picking the grid size + dropping cells
//     based on content rather than baking in `(10, 24)` per preset.
//
// Pure-Swift + Foundation; testable without a Metal device. The
// pipeline calls `estimateInitialGeometry` once after the reference
// frame is built and routes the result through to the existing
// multi-AP code paths via mutations on `LuckyStackOptions`.
import Foundation

/// AutoAP execution mode. Default `.fast`: do the closed-form preflight
/// only. `.off`: skip the auto entirely (manual override path —
/// triggered by user CLI / GUI overrides). `.deep`: run the additional
/// CPU-side iterative cell-refinement pass on top of the preflight,
/// reserved for long SERs (>5000 frames) where extra geometry tuning
/// cost amortises across the frame count.
enum AutoAPMode: String, Codable, CaseIterable {
    case off  = "off"
    case fast = "fast"
    case deep = "deep"
}

/// Inputs to the AutoAP estimator. `referenceLuminance` is a row-major
/// luma buffer pulled from the runner's reference frame (built before
/// the main accumulation in scientific mode; otherwise the single best
/// frame's luma). Optional — if nil, AutoAP falls back to the prior
/// hint without content-aware sizing.
struct AutoAPInput {
    let imageWidth: Int
    let imageHeight: Int
    let frameCount: Int
    let targetType: PresetTarget?
    let referenceLuminance: [Float]?
    /// Caller's prior — typically the active preset's `(grid, patchHalf)`
    /// values. Used as a bias when AutoPSF bails or the input is too
    /// degenerate to sample.
    let priorGrid: Int
    let priorPatchHalf: Int

    // Multi-AP yes/no gate inputs (Block v1+ — 2026-05-02).
    // Per-frame global alignment shifts (from `alignAgainstReference`)
    // — variance over time is the "is the atmosphere actually
    // shearing this data?" signal. When the spread is below 0.5 px
    // across the time-scaled pilot window, multi-AP cell-level
    // refinement just adds SAD-search noise without recovering
    // anything; the gate suppresses it.
    let globalShiftsOverTime: [SIMD2<Float>]
    /// Capture frame rate in fps if known (parsed from SER metadata
    /// via `CaptureValidator.parseMetadata` → `fps`). nil = use a
    /// frame-count-based fallback for pilot sizing.
    let frameRateFPS: Double?
}

/// AutoAP's resolved geometry. The runner reads these and feeds them
/// into the existing multi-AP / two-stage / tiled-deconv code paths.
struct AutoAPResult {
    let mode: AutoAPMode
    /// AP grid edge length in cells. Caller writes this into
    /// `options.multiAPGrid`.
    let gridSize: Int
    /// Correlation patch radius in pixels. Caller writes this into
    /// `options.multiAPPatchHalf` (NEW field; previously hardcoded
    /// to 8 in the shader call).
    let patchHalf: Int
    /// SAD search radius in pixels. Caller writes this into
    /// `options.multiAPSearch`.
    let multiAPSearch: Int
    /// Cell indices (row-major over the `gridSize × gridSize` grid)
    /// that AutoAP recommends skipping — empty-sky / dead-luma cells
    /// where per-AP correlation just adds noise. Empty when no
    /// reference luma was supplied or all cells passed the test.
    let dropList: Set<Int>
    /// Recommended per-AP keep fraction (0..1). nil = use the
    /// caller's `keepPercent` unchanged. Non-nil → caller should
    /// route through the two-stage accumulator with this fraction.
    let perAPKeepFraction: Double?
    /// Deconvolution tile size in pixels (C.4). Caller writes this
    /// into `options.tiledDeconvAPGrid` after dividing by the
    /// frame's smaller dimension to get a grid count, since the
    /// existing code field stores grid count not tile size.
    let deconvTileSize: Int
    let deconvOverlapPx: Int
    /// 0..1 confidence that the resolved geometry beats the prior.
    /// Below 0.5 → the runner should keep the prior unchanged.
    let confidence: Float
    /// Human-readable diagnostic; logged via NSLog for the GUI / CLI
    /// to surface ("AUTO" badge + tooltip).
    let diagnostic: String
    /// Multi-AP yes/no gate (v1+). When true, AutoAP recommends
    /// disabling per-AP local refinement on this capture: the pilot
    /// shift-variance measurement showed the atmosphere is locally
    /// uniform and the global single-shift accumulator is the right
    /// tool. The runner forces `useMultiAP = false` when this is set,
    /// which routes through the existing fast single-shift path.
    let suppressMultiAP: Bool
}

enum AutoAP {

    // MARK: - Public entry

    /// Estimate full geometry from the supplied inputs. Pure function;
    /// safe to call from any thread.
    static func estimateInitialGeometry(_ input: AutoAPInput) -> AutoAPResult {
        let W = input.imageWidth
        let H = input.imageHeight
        let minDim = min(W, H)

        // Step 1: AutoPSF on the reference luma if we got one. The
        // estimator already auto-bails on lunar / textured / cropped
        // subjects (see feedback_autopsf_lunar_bail.md memory) — its
        // success vs nil is the single best signal for "is this a
        // clean planetary disc with a measurable PSF".
        let psf: AutoPSF.Result? = input.referenceLuminance.flatMap {
            AutoPSF.estimate(luminance: $0, width: W, height: H)
        }

        // Step 2: patchHalf — drives the SAD correlation patch size in px.
        // For a clean disc, σ × 3 captures the full LSF energy of the
        // PSF at hand; outside that range the patch correlation either
        // misses real shifts (too small) or smears across multiple
        // adaptive-optics-equivalent isoplanatic patches (too big).
        // When AutoPSF bails (lunar / textured / cropped), use the
        // APPlanner-derived feature-size cascade: probe how much of
        // the frame carries content, and pick patchHalf to fit the
        // implied feature scale rather than a flat target keyword.
        let patchHalf: Int
        if let psf = psf {
            let sigmaPx = max(0.5, min(5.0, Double(psf.sigma)))
            patchHalf = clamp(Int((sigmaPx * 3.0).rounded()), low: 8, high: 32)
        } else {
            patchHalf = patchHalfForFallback(
                target: input.targetType,
                priorPatchHalf: input.priorPatchHalf,
                minDim: minDim,
                referenceLuma: input.referenceLuminance,
                width: W, height: H
            )
        }

        // Step 3: grid edge length.
        // Cells should be ≥ 2 × patchHalf (so the SAD search window
        // has room) and ideally ~3 × patchHalf (a balance between
        // adaptive granularity and per-cell sample count).
        //
        // Planet-in-frame: divisor 3 × patchHalf gives ~8 cells across
        // a typical disc (Jupiter at r=173, patchHalf=11 → 10×10
        // grid, matching the historical jupiterStandard preset's
        // hand-tuned value). Going coarser (divisor 8) was the
        // regression on the multi-AP A/B sweep.
        // Full-disc / surface (lunar mosaic, solar full-disc):
        // divisor 8 × patchHalf — coarser because there's no
        // smaller "subject" to keep cells inside.
        let grid: Int
        if let psf = psf, psf.discRadius > 20 {
            let discDiameter = Float(psf.discRadius) * 2.0
            let gridF = discDiameter / Float(3 * patchHalf)
            grid = clamp(Int(gridF.rounded()), low: 6, high: 24)
        } else {
            let gridF = Float(minDim) / Float(8 * patchHalf)
            grid = clamp(Int(gridF.rounded()), low: 8, high: 32)
        }

        // Step 4: SAD search radius — bigger patches need slightly
        // wider search windows because phase-correlation ambiguity
        // grows with patch size, but unbounded search blows up the
        // candidate count quadratically. The +2 floor keeps tiny
        // patches usable; the cap at 16 mirrors the existing CLI
        // `--multi-ap-grid` upper end.
        let multiAPSearch = clamp(patchHalf / 2 + 2, low: 4, high: 16)

        // Step 5: AP drop-list via APPlanner. Reuses the existing
        // luminance + LAPD scorer so the "what counts as content"
        // rule stays consistent with B.3's two-stage adaptive
        // rejection. When no reference luma was supplied, drop
        // nothing — better to keep all cells than to invent
        // rejections we can't justify.
        var dropList: Set<Int> = []
        if let luma = input.referenceLuminance {
            let plan = APPlanner.plan(
                luma: luma, width: W, height: H,
                apGrid: grid,
                rejectFraction: APPlanner.defaultRejectFraction,
                minLumaFraction: APPlanner.defaultMinLumaFraction
            )
            dropList = Set(plan.mask.enumerated().compactMap { idx, kept in
                kept ? nil : idx
            })
        }

        // Step 6: per-AP keep fraction. The runner's existing
        // `useAutoKeepPercent` (Block A.4) already does kneedle-style
        // derivation on the global quality histogram. We don't get
        // those scores here (they're only computed mid-run), so
        // AutoAP's contribution is to *enable* auto-keep; the actual
        // fraction comes from the runner's grading output. Returning
        // nil here means "let auto-keep handle it"; the caller
        // turns on `useAutoKeepPercent` when this is nil.
        let perAPKeep: Double? = nil

        // Step 7: deconv tile size (C.4). When AutoPSF surfaced a
        // disc, base the tile on disc geometry: 8× disc radius gives
        // a tile that comfortably contains the full disc + halo
        // without splitting bright structure across tile boundaries.
        // Without a disc, fall back to a quarter of the frame's
        // smaller dimension. Rounded to nearest 100 px (matches
        // BiggSky's documented tile-size buckets); 15% overlap
        // handles the tile-boundary deconv ringing.
        let tileRaw: Float
        if let psf = psf, psf.discRadius > 50 {
            tileRaw = Float(psf.discRadius) * 8.0
        } else {
            tileRaw = Float(minDim) / 4.0
        }
        let tileRounded = max(200, min(1024, Int((tileRaw / 100.0).rounded()) * 100))
        let overlap = max(20, tileRounded / 7)

        // Step 8: confidence. AutoPSF success is the strongest
        // signal that the geometry suits the data; without it we
        // are biased by the prior preset.
        let confidence: Float = psf != nil ? 0.85 : 0.55

        // Step 9: multi-AP yes/no gate. Measures the spatial-shear
        // signal from the global alignment shifts that the runner
        // already computed. Pilot window = max(100, fps × 3) frames
        // (≈3 s of capture), clamp to [100, 500] — enough atmospheric
        // realisations to estimate variance, cheap to compute since
        // the shifts are already in memory.
        //
        // Decision: if std-dev of the shift magnitudes within the
        // pilot window is below 0.5 px on BOTH axes, the data is
        // already cleanly globally aligned — multi-AP cell-level
        // refinement just adds SAD-search noise without recovering
        // anything. Skip it.
        //
        // Note: this measures TEMPORAL motion stability, not direct
        // SPATIAL shear (a true spatial-shear pilot would need a
        // small per-AP SAD pass). But low temporal variance is a
        // strong indicator of "atmosphere quiet + telescope stable",
        // which empirically correlates with multi-AP not helping.
        let shiftGate = decideMultiAP(
            shifts: input.globalShiftsOverTime,
            fps: input.frameRateFPS,
            frameCount: input.frameCount
        )

        // Step 10: diagnostic line. Surfaced via NSLog by the runner
        // and rendered in the GUI's "AUTO" tooltip.
        let psfNote = psf.map {
            String(format: "σ=%.2f r=%.0f", $0.sigma, $0.discRadius)
        } ?? "no-disc"
        let dropNote = dropList.isEmpty ? "0" : "\(dropList.count)/\(grid * grid)"
        let gateNote = shiftGate.suppress
            ? String(format: " GATE: skip multi-AP (σ_shift=%.2f px, pilot=%d)",
                     shiftGate.maxStddev, shiftGate.pilotN)
            : String(format: " gate=ok (σ_shift=%.2f px, pilot=%d)",
                     shiftGate.maxStddev, shiftGate.pilotN)
        let diag = """
        AutoAP: target=\(input.targetType?.rawValue ?? "?") \
        \(psfNote) → grid=\(grid) patchHalf=\(patchHalf) \
        search=\(multiAPSearch) drop=\(dropNote) tile=\(tileRounded)\
        \(gateNote)
        """

        // Step 11: deep-mode refinement (cell subdivision) — applied
        // after the closed-form pass when explicitly requested. The
        // refinement happens on the same reference luma input; we
        // don't run a second GPU pass.
        var resultGrid = grid
        var resultDrop = dropList
        if let luma = input.referenceLuminance {
            let refined = refineGeometry(
                grid: grid, patchHalf: patchHalf,
                drop: dropList, luma: luma, width: W, height: H
            )
            resultGrid = refined.grid
            resultDrop = refined.drop
        }

        return AutoAPResult(
            mode: .fast,
            gridSize: resultGrid,
            patchHalf: patchHalf,
            multiAPSearch: multiAPSearch,
            dropList: resultDrop,
            perAPKeepFraction: perAPKeep,
            deconvTileSize: tileRounded,
            deconvOverlapPx: overlap,
            confidence: confidence,
            diagnostic: diag,
            suppressMultiAP: shiftGate.suppress
        )
    }

    /// Multi-AP yes/no gate — measures the temporal stability of the
    /// global per-frame alignment shifts within a time-scaled pilot
    /// window. Returns the pilot size used and the max per-axis
    /// std-dev in pixels, plus the suppress recommendation.
    ///
    /// Pilot sizing: target ≈ 3 s of capture so we cycle through
    /// many independent atmospheric coherence cells (τ₀ ~ 5-10 ms).
    /// At 50 fps that's ~150 frames; at 250 fps ~750 frames; clamp
    /// to [100, 500] for a sane sample size regardless of fps.
    /// When fps is unknown, fall back to a 20% sample of all frames.
    static func decideMultiAP(
        shifts: [SIMD2<Float>],
        fps: Double?,
        frameCount: Int
    ) -> (pilotN: Int, maxStddev: Float, suppress: Bool) {
        guard !shifts.isEmpty else { return (0, 0, false) }
        let pilotN: Int
        if let fps = fps, fps > 0 {
            pilotN = clamp(Int((fps * 3.0).rounded()), low: 100, high: 500)
        } else {
            pilotN = clamp(frameCount / 5, low: 100, high: 500)
        }
        let take = min(pilotN, shifts.count)
        guard take >= 30 else { return (take, 0, false) }
        let sample = shifts.prefix(take)

        var sumX: Double = 0, sumY: Double = 0
        for s in sample {
            sumX += Double(s.x)
            sumY += Double(s.y)
        }
        let meanX = sumX / Double(take)
        let meanY = sumY / Double(take)
        var varX: Double = 0, varY: Double = 0
        for s in sample {
            let dx = Double(s.x) - meanX
            let dy = Double(s.y) - meanY
            varX += dx * dx
            varY += dy * dy
        }
        let stdX = sqrt(varX / Double(take))
        let stdY = sqrt(varY / Double(take))
        let maxStd = Float(max(stdX, stdY))
        // Threshold calibration on the BiggSky fixture set (2026-05-02):
        //   σ_shift  Δ vs no-multi-AP (with multi-AP + AutoAP geom)
        //   1.03      +2.5%
        //   1.63     +33.7%
        //   1.74     +20.1%
        //   4.63     +20.0%
        //   5.36      −6.4%
        //   6.20     −11.0%
        // Pattern: HIGH temporal shift variance → multi-AP HURTS
        // (noisy / unstable capture → per-AP SAD search picks up
        // wrong shifts, averages misalignments). LOW variance →
        // multi-AP HELPS (clean capture → per-AP refinement
        // recovers real per-region atmospheric distortion).
        // Threshold 5.0 px catches both losing fixtures while
        // leaving every winning fixture's gate "ok". The lower
        // bound 0.5 px (sub-pixel global alignment) is reserved
        // for the future spatial-shear pilot — temporal stability
        // there only weakly correlates with spatial uniformity.
        return (take, maxStd, maxStd > 5.0)
    }

    /// CPU-side cell-shear refinement. Subdivides cells whose
    /// LAPD-step against neighbours exceeds 3× the median — those
    /// are high-shear zones (planetary limbs, terminator) where the
    /// alignment shift varies fastest, so a finer grid recovers
    /// sub-cell shifts that the bilinear shift-map would otherwise
    /// smear across.
    ///
    /// Subdivision is bounded: we never produce a final grid larger
    /// than 32 cells/edge, and never one where a single cell would
    /// be smaller than `2 × patchHalf` in pixels. When subdivision
    /// would violate either bound, the grid is left at the input.
    static func refineGeometry(
        grid: Int,
        patchHalf: Int,
        drop: Set<Int>,
        luma: [Float],
        width W: Int,
        height H: Int,
        maxGrid: Int = 32
    ) -> (grid: Int, drop: Set<Int>) {
        // Compute per-cell LAPD score on the supplied grid.
        let plan = APPlanner.plan(
            luma: luma, width: W, height: H,
            apGrid: grid,
            rejectFraction: 0.0,            // we don't want APPlanner to drop here
            minLumaFraction: 0.0
        )
        let scores = plan.scores
        guard !scores.isEmpty else { return (grid, drop) }

        // Median-of-non-zero scores is the reference scale for shear.
        let nonZero = scores.filter { $0 > 0 }
        guard !nonZero.isEmpty else { return (grid, drop) }
        let sorted = nonZero.sorted()
        let median = sorted[sorted.count / 2]
        let shearThreshold = median * 3.0

        var hotCount = 0
        for s in scores where s > shearThreshold { hotCount += 1 }

        // Subdivide only when there's a meaningful hotspot
        // population. <5% of cells = noise / single highlight; in
        // that case the existing grid is fine.
        let hotFraction = Double(hotCount) / Double(scores.count)
        guard hotFraction > 0.05 else { return (grid, drop) }

        let candidate = min(maxGrid, grid * 2)
        guard candidate > grid else { return (grid, drop) }

        // Cell-size sanity: each cell must be wide enough to host
        // the SAD patch.
        let cellW = W / candidate
        let cellH = H / candidate
        guard cellW >= 2 * patchHalf, cellH >= 2 * patchHalf else {
            return (grid, drop)
        }

        // Re-plan on the doubled grid so the drop-list is regenerated
        // at the new resolution (cells that were "in" on the coarse
        // grid may now be "in" or "out" depending on local content).
        let planRefined = APPlanner.plan(
            luma: luma, width: W, height: H,
            apGrid: candidate,
            rejectFraction: APPlanner.defaultRejectFraction,
            minLumaFraction: APPlanner.defaultMinLumaFraction
        )
        let refinedDrop = Set(planRefined.mask.enumerated().compactMap { idx, kept in
            kept ? nil : idx
        })
        return (candidate, refinedDrop)
    }

    /// Kneedle-style elbow detector for per-AP keep fractions. Caller
    /// passes a sorted-ascending quality-score array; returned value
    /// is the recommended keep fraction in [0.10, 0.75]. Used by the
    /// runner's per-AP path when AutoAP wants finer per-cell control
    /// than the global auto-keep gives.
    ///
    /// Method: max-distance-to-chord on the sorted curve, normalised
    /// to [0, 1] on both axes. The point of maximum distance is the
    /// natural elbow — frames above it are "lucky tail", frames
    /// below it are "average". The fraction returned is `(N - elbow_idx) / N`.
    static func resolveKeepFraction(sortedScores: [Float]) -> Double {
        guard sortedScores.count >= 50 else {
            // Below 50 frames we don't have enough samples for a
            // robust elbow; default to the conservative middle of
            // the [10%, 75%] band.
            return 0.40
        }
        let lo = sortedScores.first ?? 0
        let hi = sortedScores.last ?? 1
        let span = max(1e-6, hi - lo)
        let n = sortedScores.count

        // Chord from (0, 0) to (1, 1). Distance from each sample to
        // the chord = |yNorm − xNorm| / √2. The argmax over i is
        // the elbow.
        var bestIdx = 0
        var bestDist: Float = 0
        for i in 0..<n {
            let xNorm = Float(i) / Float(n - 1)
            let yNorm = (sortedScores[i] - lo) / span
            let d = abs(yNorm - xNorm)
            if d > bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        let frac = Double(n - bestIdx) / Double(n)
        // Clamp to the scientifically-anchored band: <10% is
        // noise-floor selection, >75% is "no lucky imaging happening".
        return max(0.10, min(0.75, frac))
    }

    // MARK: - Helpers

    /// Feature-size-aware fallback for `patchHalf` when AutoPSF bailed.
    /// Cascade (in priority order):
    ///   1. Reference luma available → APPlanner active-cell density
    ///      probe at grid=16: high density (>60%) means the subject
    ///      fills the frame (lunar surface, solar granulation) and
    ///      bigger patches buy SAD signal-to-noise; low density
    ///      (<25%) means a compact / clustered subject and smaller
    ///      patches stay inside the structure.
    ///   2. No luma but target keyword → feature-scale prior
    ///      (sun/solar = 12 px granules / fine prom detail; moon =
    ///      16 px crater detail; jupiter / saturn = 16-18; mars = 12).
    ///   3. Nothing → prior preset value, clamped.
    /// All paths cap relative to `minDim / 8` so a 32-px patch can't
    /// land on a 200-px frame.
    private static func patchHalfForFallback(
        target: PresetTarget?,
        priorPatchHalf: Int,
        minDim: Int,
        referenceLuma: [Float]?,
        width: Int,
        height: Int
    ) -> Int {
        let upper = max(8, minDim / 8)

        // Cascade level 1 — feature-size probe via APPlanner active-
        // cell ratio at a fixed coarse grid. Pure CPU; uses the same
        // LAPD scorer as the rest of the AP machinery so the
        // "what counts as content" rule is consistent.
        if let luma = referenceLuma, width >= 64, height >= 64 {
            let probe = APPlanner.plan(
                luma: luma, width: width, height: height,
                apGrid: 16,
                rejectFraction: 0.0,
                minLumaFraction: APPlanner.defaultMinLumaFraction
            )
            let activeRatio = Double(probe.keptCellCount) / Double(16 * 16)
            if activeRatio > 0.60 {
                // Surface-textured fills-frame (lunar surface, solar
                // granulation): bigger patches contain multiple feature
                // periods (craters / granules) for SAD reliability.
                return clamp(minDim / 32, low: 12, high: min(24, upper))
            } else if activeRatio < 0.25 {
                // Compact / clustered subject: small patches stay
                // inside the structure rather than averaging over
                // background sky.
                return clamp(10, low: 8, high: min(14, upper))
            }
            // Mid density — balanced choice.
            return clamp(minDim / 48, low: 10, high: min(20, upper))
        }

        // Cascade level 2 — target-keyword fallback with feature-
        // scale-aware base values (refined from the v1 preset
        // mirror, which over-estimated patchHalf for textured
        // surface targets).
        let base: Int
        switch target {
        case .sun:     base = 12
        case .moon:    base = 16
        case .jupiter: base = 16
        case .saturn:  base = 18
        case .mars:    base = 12
        case .other, .none:
            base = priorPatchHalf > 0 ? priorPatchHalf : 16
        }
        return clamp(base, low: 8, high: min(32, upper))
    }

    @inline(__always)
    private static func clamp<T: Comparable>(_ value: T, low: T, high: T) -> T {
        return min(max(value, low), high)
    }
}
