// AutoAP unit tests — pure Swift, no Metal device.
//
// Covers the closed-form preflight (target-aware fallback when AutoPSF
// can't fit a Gaussian PSF), the AutoPSF-driven path (synthetic disc
// luminance generates a clean σ → expected geometry), the cell-shear
// refinement (high-shear hotspots trigger 2× subdivision), the kneedle
// keep-fraction picker, and edge cases (empty buffer, tiny frames).
//
// Why these matter: AutoAP runs by default on every stack; a bug here
// silently shifts what the user actually got from "their preset" to
// "AutoAP's pick". The tests anchor the contract:
//   1. Closed-form ranges respect the bounds in the documented formula.
//   2. AutoPSF success → patchHalf scales with σ × 3 (clamped 8..32).
//   3. AutoPSF bail → target-aware fallback, never below 8 px.
//   4. Refinement subdivides only on real hotspot population.
//   5. Kneedle returns a fraction in [0.10, 0.75].
import Foundation
import Testing
@testable import AstroSharper

@Suite("AutoAP — closed-form preflight ranges")
struct AutoAPClosedFormTests {

    @Test("AutoPSF bail — Jupiter target, no luminance → fallback prior")
    func jupiterFallbackToPrior() {
        let input = AutoAPInput(
            imageWidth: 800, imageHeight: 600,
            frameCount: 1500,
            targetType: .jupiter,
            referenceLuminance: nil,
            priorGrid: 10,
            priorPatchHalf: 24,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        // Without AutoPSF success, feature-size cascade falls through
        // to target-keyword level: jupiter base = 16 (refined from
        // v1's 24 to better match small-feature scale).
        #expect(r.patchHalf >= 8)
        #expect(r.patchHalf <= 32)
        // Grid uses the full-disc/surface formula since no disc was
        // detected: minDim / (8 * patchHalf), clamped up to 8.
        #expect(r.gridSize >= 8)
        #expect(r.gridSize <= 32)
        // Confidence is "moderate" without an AutoPSF disc.
        #expect(r.confidence >= 0.5)
        #expect(r.confidence < 0.85)
        // No drop list without luma.
        #expect(r.dropList.isEmpty)
    }

    @Test("AutoPSF bail — unknown target, no luminance → uses prior patchHalf")
    func unknownTargetUsesPrior() {
        let input = AutoAPInput(
            imageWidth: 1024, imageHeight: 1024,
            frameCount: 500,
            targetType: nil,
            referenceLuminance: nil,
            priorGrid: 8,
            priorPatchHalf: 12,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        // Without any signal AutoAP must respect the prior, clamped to
        // [8, min(32, minDim/8 = 128)] = [8, 32].
        #expect(r.patchHalf == 12)
    }

    @Test("Tile size always rounds to a 100-px multiple in [200, 1024]")
    func tileSizeRange() {
        for minDim in [256, 512, 800, 1280, 2048] {
            let input = AutoAPInput(
                imageWidth: minDim, imageHeight: minDim,
                frameCount: 1000,
                targetType: .moon,
                referenceLuminance: nil,
                priorGrid: 8, priorPatchHalf: 16,
                globalShiftsOverTime: [],
                frameRateFPS: nil
            )
            let r = AutoAP.estimateInitialGeometry(input)
            #expect(r.deconvTileSize >= 200)
            #expect(r.deconvTileSize <= 1024)
            #expect(r.deconvTileSize % 100 == 0,
                    "tile must round to 100 px, got \(r.deconvTileSize) for minDim=\(minDim)")
        }
    }

    @Test("Search radius derived from patchHalf (patchHalf/2 + 2, clamped 4..16)")
    func searchRadiusDerived() {
        let input = AutoAPInput(
            imageWidth: 1024, imageHeight: 1024,
            frameCount: 500,
            targetType: .saturn,
            referenceLuminance: nil,
            priorGrid: 12,
            priorPatchHalf: 24,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        let expected = max(4, min(16, r.patchHalf / 2 + 2))
        #expect(r.multiAPSearch == expected)
    }
}

@Suite("AutoAP — AutoPSF-driven path with synthetic disc")
struct AutoAPSyntheticDiscTests {

    /// Build a synthetic luminance buffer with a Gaussian-blurred disc
    /// at the centre. Returns the buffer + the σ that the limb-LSF
    /// estimator should recover.
    private static func makeDisc(
        width W: Int, height H: Int,
        radius: Float, sigma: Float
    ) -> [Float] {
        var luma = [Float](repeating: 0, count: W * H)
        let cx = Float(W) * 0.5
        let cy = Float(H) * 0.5
        // Simple analytic profile: smoothstep over [r-3σ, r+3σ] from
        // 1.0 inside to 0.05 outside. Approximates a step convolved
        // with a Gaussian closely enough for AutoPSF to recover σ.
        for y in 0..<H {
            for x in 0..<W {
                let dx = Float(x) - cx
                let dy = Float(y) - cy
                let d = sqrtf(dx * dx + dy * dy)
                let edge = (d - radius) / sigma
                // Erf-like fall-off: tanh as a cheap approximation.
                let inside = (1.0 - tanhf(edge)) * 0.5
                luma[y * W + x] = 0.05 + 0.9 * inside
            }
        }
        return luma
    }

    @Test("Synthetic disc yields planet-in-frame grid + patchHalf in band")
    func syntheticDiscPicksPlanetGrid() {
        let W = 800, H = 600
        let luma = Self.makeDisc(width: W, height: H, radius: 80, sigma: 1.5)
        let input = AutoAPInput(
            imageWidth: W, imageHeight: H,
            frameCount: 2000,
            targetType: .jupiter,
            referenceLuminance: luma,
            priorGrid: 10, priorPatchHalf: 24,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        // patchHalf = round(σ × 3), clamped 8..32. σ ≈ 1.5 → ≈ 5,
        // clamped up to 8.
        #expect(r.patchHalf >= 8)
        #expect(r.patchHalf <= 32)
        // Grid for planet-in-frame: discDiameter / (3 * patchHalf)
        //   = 160 / (3 * 8) = 6.7 → ~7.
        #expect(r.gridSize >= 6)
        #expect(r.gridSize <= 24)
        // High confidence when AutoPSF succeeded.
        #expect(r.confidence >= 0.85)
    }

    @Test("Synthetic disc yields non-empty drop list when there's empty sky")
    func syntheticDiscDropsEmptySky() {
        // Tight crop with a small centred disc — most cells are
        // background sky and should be dropped.
        let W = 800, H = 600
        let luma = Self.makeDisc(width: W, height: H, radius: 50, sigma: 1.2)
        let input = AutoAPInput(
            imageWidth: W, imageHeight: H,
            frameCount: 2000,
            targetType: .saturn,
            referenceLuminance: luma,
            priorGrid: 10, priorPatchHalf: 24,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        #expect(!r.dropList.isEmpty,
                "small centred disc should leave most cells as empty sky → drop list")
        // Some cells must remain (the disc itself).
        let total = r.gridSize * r.gridSize
        #expect(r.dropList.count < total,
                "drop list shouldn't kill every cell")
    }
}

@Suite("AutoAP — refinement (cell shear)")
struct AutoAPRefinementTests {

    @Test("Uniform luma → no subdivision")
    func uniformLumaNoSubdivision() {
        let W = 512, H = 512
        let luma = [Float](repeating: 0.5, count: W * H)
        let result = AutoAP.refineGeometry(
            grid: 8, patchHalf: 16,
            drop: [], luma: luma, width: W, height: H
        )
        #expect(result.grid == 8, "uniform field → no hotspots → no subdivision")
    }

    @Test("Single localised hotspot does NOT trigger subdivision (<5%)")
    func singleHotspotIgnored() {
        let W = 512, H = 512
        var luma = [Float](repeating: 0.1, count: W * H)
        // Plant one bright 16×16 patch — at 8×8 grid that's a single
        // cell, well below the 5%-of-cells subdivision threshold.
        for y in 240..<256 {
            for x in 240..<256 {
                luma[y * W + x] = 1.0
            }
        }
        let result = AutoAP.refineGeometry(
            grid: 8, patchHalf: 16,
            drop: [], luma: luma, width: W, height: H
        )
        #expect(result.grid == 8)
    }

    @Test("Cell-size guard: refusal when refined cells would be < 2 × patchHalf")
    func cellSizeGuard() {
        let W = 256, H = 256
        // Pattern that would normally trigger subdivision: alternating
        // bright / dark stripes give every cell strong LAPD content.
        var luma = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                luma[y * W + x] = (x / 8) % 2 == 0 ? 1.0 : 0.0
            }
        }
        // Try to refine 16×16 grid with patchHalf=12. Refined cells
        // would be 256/32 = 8 px wide < 24 (= 2 × patchHalf), so the
        // guard must keep the original grid.
        let result = AutoAP.refineGeometry(
            grid: 16, patchHalf: 12,
            drop: [], luma: luma, width: W, height: H
        )
        #expect(result.grid == 16, "refusal expected because refined cell would be too small")
    }
}

@Suite("AutoAP — kneedle keep-fraction")
struct AutoAPKneedleTests {

    @Test("Few-frame fallback returns 0.40")
    func tooFewFrames() {
        let scores: [Float] = [0.1, 0.2, 0.3]
        #expect(AutoAP.resolveKeepFraction(sortedScores: scores) == 0.40)
    }

    @Test("Linear distribution → fraction near upper cap (no obvious knee)")
    func linearDistribution() {
        // Linear scores from 0..1: chord and curve coincide → kneedle
        // distance is ~0 everywhere; the loop returns idx=0 (no
        // distinguishable knee) and the fraction = N/N = 1.0,
        // clamped to 0.75.
        let scores = (0..<100).map { Float($0) / 99.0 }
        let f = AutoAP.resolveKeepFraction(sortedScores: scores)
        #expect(f >= 0.10)
        #expect(f <= 0.75)
    }

    @Test("Hockey-stick distribution → smaller fraction (top tail dominates)")
    func hockeyStickDistribution() {
        // 90 mediocre + 10 great frames, sorted ascending.
        var scores = [Float](repeating: 0.1, count: 90)
        scores.append(contentsOf: (0..<10).map { 0.5 + Float($0) * 0.05 })
        let f = AutoAP.resolveKeepFraction(sortedScores: scores)
        // Elbow should be near idx=90 → fraction ≈ 10/100 = 0.10,
        // clamped to the [0.10, 0.75] band.
        #expect(f >= 0.10)
        #expect(f <= 0.40)
    }
}

@Suite("AutoAP — multi-AP yes/no gate (decideMultiAP)")
struct AutoAPGateTests {

    @Test("Empty shifts → no decision, suppress=false")
    func emptyShifts() {
        let r = AutoAP.decideMultiAP(shifts: [], fps: 50, frameCount: 1000)
        #expect(r.suppress == false)
        #expect(r.pilotN == 0)
    }

    @Test("All-zero shifts → stddev=0 → multi-AP allowed (clean capture)")
    func zeroShiftsKeepMultiAP() {
        // 200 frames worth of perfectly-stable global shifts.
        // Calibrated threshold (2026-05-02): low temporal variance
        // empirically correlates with multi-AP HELPING, so the gate
        // only suppresses on HIGH variance (>5 px). σ=0 → keep.
        let shifts = [SIMD2<Float>](repeating: .zero, count: 200)
        let r = AutoAP.decideMultiAP(shifts: shifts, fps: 50, frameCount: 1000)
        #expect(r.suppress == false)
        #expect(r.maxStddev == 0)
        #expect(r.pilotN == 150)   // fps × 3 = 150, within [100, 500]
    }

    @Test("High-variance shifts (>5 px) → suppress multi-AP")
    func highVarianceSuppressMultiAP() {
        // Shifts ranging ±15 px with uniform distribution → stddev
        // ~8.7 px, above the 5.0 px gate threshold (calibrated
        // against the BiggSky fixture set: losses had σ_shift 5.36
        // and 6.20, wins had σ_shift ≤ 4.63).
        var shifts: [SIMD2<Float>] = []
        for i in 0..<200 {
            let s = Float(i % 31) - 15.0
            shifts.append(SIMD2<Float>(s, s))
        }
        let r = AutoAP.decideMultiAP(shifts: shifts, fps: 50, frameCount: 1000)
        #expect(r.suppress == true)
        #expect(r.maxStddev > 5.0)
    }

    @Test("Moderate-variance shifts (1..3 px) → multi-AP allowed")
    func moderateVarianceKeepMultiAP() {
        // Shifts ranging ±2 px → stddev ~1.4 px, well below the
        // 5 px threshold. Matches the "winning" BiggSky fixtures.
        var shifts: [SIMD2<Float>] = []
        for i in 0..<200 {
            let s = Float(i % 5) - 2.0
            shifts.append(SIMD2<Float>(s, s))
        }
        let r = AutoAP.decideMultiAP(shifts: shifts, fps: 50, frameCount: 1000)
        #expect(r.suppress == false)
        #expect(r.maxStddev < 5.0)
    }

    @Test("Pilot size scales with fps (3-second window, clamped 100..500)")
    func pilotSizeFromFPS() {
        let shifts = [SIMD2<Float>](repeating: .zero, count: 2000)
        // 50 fps → 150 frames
        let r50 = AutoAP.decideMultiAP(shifts: shifts, fps: 50, frameCount: 2000)
        #expect(r50.pilotN == 150)
        // 250 fps → 750 → clamped to 500
        let r250 = AutoAP.decideMultiAP(shifts: shifts, fps: 250, frameCount: 2000)
        #expect(r250.pilotN == 500)
        // 20 fps → 60 → clamped up to 100
        let r20 = AutoAP.decideMultiAP(shifts: shifts, fps: 20, frameCount: 2000)
        #expect(r20.pilotN == 100)
    }

    @Test("Pilot size falls back to 20% of frameCount when fps unknown")
    func pilotSizeFallbackNoFPS() {
        let shifts = [SIMD2<Float>](repeating: .zero, count: 2000)
        let r = AutoAP.decideMultiAP(shifts: shifts, fps: nil, frameCount: 1500)
        // 1500 / 5 = 300, within [100, 500]
        #expect(r.pilotN == 300)
    }

    @Test("Below 30 sample frames → no decision, suppress=false")
    func tooFewSamples() {
        let shifts = [SIMD2<Float>](repeating: .zero, count: 20)
        let r = AutoAP.decideMultiAP(shifts: shifts, fps: 50, frameCount: 100)
        #expect(r.suppress == false)
    }
}

@Suite("AutoAP — feature-size cascade (no-AutoPSF fallback)")
struct AutoAPFeatureSizeTests {

    /// Build a luma buffer where features fill almost the whole
    /// frame — bright textured pattern everywhere. Mimics a lunar
    /// surface fills-frame capture.
    private static func makeFillsFrame(W: Int, H: Int) -> [Float] {
        var luma = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                // Repeating bright pattern with no large dark areas.
                let v = 0.4 + 0.5 * sinf(Float(x + y) * 0.5)
                luma[y * W + x] = v
            }
        }
        return luma
    }

    /// Build a luma buffer with a small bright cluster in the centre
    /// and dark sky everywhere else — mimics a small planetary disc
    /// where AutoPSF would normally measure σ but here we pretend it
    /// bailed (e.g. the disc is too small / textured / cropped).
    private static func makeCompactSubject(W: Int, H: Int) -> [Float] {
        var luma = [Float](repeating: 0, count: W * H)
        let cx = W / 2, cy = H / 2
        let r = 30
        for y in (cy - r)..<(cy + r) {
            for x in (cx - r)..<(cx + r) {
                guard x >= 0, x < W, y >= 0, y < H else { continue }
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy < r * r {
                    luma[y * W + x] = 0.9
                }
            }
        }
        return luma
    }

    @Test("Fills-frame texture (lunar/solar surface) → cascade picks bigger patches")
    func fillsFramePicksBigPatches() {
        let W = 800, H = 600
        let luma = Self.makeFillsFrame(W: W, H: H)
        let input = AutoAPInput(
            imageWidth: W, imageHeight: H,
            frameCount: 1000,
            targetType: .moon,
            referenceLuminance: luma,
            priorGrid: 8, priorPatchHalf: 16,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        // Active-cell ratio should be high → cascade picks
        // clamp(minDim/32, 12, 24) = clamp(18, 12, 24) = 18.
        #expect(r.patchHalf >= 12,
                "fills-frame texture should pick patchHalf in the upper band")
        #expect(r.patchHalf <= 24)
    }

    @Test("Compact subject (disc cluster on dark sky) → cascade picks smaller patches")
    func compactSubjectPicksSmallPatches() {
        let W = 800, H = 600
        let luma = Self.makeCompactSubject(W: W, H: H)
        let input = AutoAPInput(
            imageWidth: W, imageHeight: H,
            frameCount: 1000,
            targetType: nil,
            referenceLuminance: luma,
            priorGrid: 8, priorPatchHalf: 16,
            globalShiftsOverTime: [],
            frameRateFPS: nil
        )
        let r = AutoAP.estimateInitialGeometry(input)
        // Tight disc / sky → APPlanner active ratio low → cascade
        // picks 8..14 px patches that stay inside the subject.
        // Note: AutoPSF may also succeed here on the synthetic disc;
        // either way patchHalf must remain in the small band for a
        // compact subject.
        #expect(r.patchHalf >= 8)
        #expect(r.patchHalf <= 16,
                "compact subject should pick patchHalf in the lower band, got \(r.patchHalf)")
    }
}
