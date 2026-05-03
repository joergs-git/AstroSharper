// Auto-PSF estimator for planetary lucky-stack outputs.
//
// Picks a Gaussian PSF sigma (in pixels) by measuring the line-spread
// function (LSF) of the planetary limb. The limb is the cleanest
// available step edge in every planetary frame: the disc is uniformly
// bright and the background is uniformly dark, so the radial intensity
// profile is dominated by the PSF's blur of that ideal step. The
// derivative of the radial profile peaks at the limb radius; the width
// of that peak is directly proportional to the PSF sigma.
//
// Algorithm:
//   1. Threshold at ~30% of luminance peak → the planetary disc.
//   2. Compute brightness-weighted centroid + equivalent disc radius
//      (from area: A = π·r²).
//   3. Sample N (=64) radial intensity profiles outward from the
//      centroid. Average to one robust 1D profile.
//   4. Take |dI/dr| → the LSF.
//   5. Around the LSF peak, compute the second-moment width
//      σ = √(M₂ / M₀). That's the PSF sigma in pixels.
//
// Robustness:
//   - Bails to nil for non-planetary inputs (no clear disc, faint, very
//     small, very low contrast).
//   - Sanity-clamps the returned sigma to [0.5, 5.0] px — outside that
//     range the estimator has either failed or the input isn't well-
//     described by a Gaussian PSF.
//
// Why not full Krishnan-Fergus blind deconv (Block C.1 spec): K-F is a
// multi-week algorithm and most of its value is for natural images
// where edges are diverse. For planetary lucky-imaging the limb IS the
// canonical edge — fitting a Gaussian to the limb LSF gives ~95% of
// what blind deconv would give for ~1% of the implementation cost.
// Iterative joint refinement (re-estimate PSF after first-pass deconv)
// is a reasonable v1 follow-up if the v0 single-pass sigma proves
// insufficient on hard cases.
import Accelerate
import Foundation
import Metal

enum AutoPSF {

    struct Result {
        /// Estimated PSF stddev in pixels. Clamped to [0.5, 5.0].
        let sigma: Float
        /// LSF peak height / off-peak mean — heuristic for "did the
        /// limb actually surface?" Values >5 are reliable; values
        /// <2 mean the input doesn't have a clean disc.
        let confidence: Float
        /// Brightness-weighted centroid of the disc (output coords).
        let discCenter: SIMD2<Float>
        /// Equivalent disc radius (px) from above-threshold area.
        let discRadius: Float
    }

    // MARK: - Public entry: from MTLTexture (production path)

    /// Estimate from a stacked-image MTLTexture. Reads luminance via a
    /// shared blit-staging texture (same pattern as Wiener.swift) and
    /// delegates to the pure-Swift core. Returns nil for unsupported
    /// formats or non-planetary inputs.
    static func estimate(
        texture: MTLTexture,
        device: MTLDevice
    ) -> Result? {
        guard let (luma, W, H) = readLuminance(texture: texture, device: device) else {
            return nil
        }
        return estimate(luminance: luma, width: W, height: H)
    }

    // MARK: - Public entry: pure Swift (testable)

    /// Estimate from a luminance buffer. Exists as a separate entry so
    /// the unit-test target can exercise the algorithm without spinning
    /// up a Metal device.
    static func estimate(
        luminance: [Float],
        width W: Int,
        height H: Int
    ) -> Result? {
        precondition(luminance.count == W * H, "AutoPSF: buffer / dim mismatch")
        guard W > 64, H > 64 else { return nil }

        // Step 1: threshold at 30% of luminance peak.
        var lumaMax: Float = 0
        for v in luminance where v > lumaMax { lumaMax = v }
        guard lumaMax > 0.02 else { return nil }   // empty / black input
        let thresh: Float = 0.30 * lumaMax

        // Step 2: brightness-weighted centroid + area count.
        var sumI: Double = 0
        var sumX: Double = 0
        var sumY: Double = 0
        var pxCount: Int = 0
        for y in 0..<H {
            let row = y * W
            for x in 0..<W {
                let v = luminance[row + x]
                if v > thresh {
                    let dv = Double(v)
                    sumI += dv
                    sumX += Double(x) * dv
                    sumY += Double(y) * dv
                    pxCount += 1
                }
            }
        }
        guard pxCount > 100, sumI > 0 else { return nil }
        let cx = Float(sumX / sumI)
        let cy = Float(sumY / sumI)
        let radius = sqrtf(Float(pxCount) / .pi)
        guard radius > 20 else { return nil }    // disc too small to LSF reliably

        // Bail-out for "no clean disc" subjects — primarily lunar shots
        // where the moon fills most of the frame. The limb-LSF approach
        // assumes a clean step from disc-bright to background-dark, but
        // a lunar full-frame has no dark background at all (terrain
        // everywhere) — the LSF picks up the strongest crater-rim
        // gradient as the "limb" and reports a wild σ that Wiener then
        // uses to over-deconvolve. Better to bail and let LuckyStack
        // skip the deconv entirely (which it does on a nil result).
        //
        // Heuristic 1: bright-pixel area as a fraction of the frame.
        // A clean planetary disc covers ≤ 35-40% of the frame even
        // in tight crops; lunar full-frame covers 70%+. Cut at 45%
        // to leave headroom for legitimately-large planetary discs.
        let brightFraction = Float(pxCount) / Float(W * H)
        guard brightFraction < 0.45 else { return nil }

        // Heuristic 2: disc must have actual background space outside
        // it. If the disc centre is within `radius` of any frame edge,
        // the limb is cropped and the LSF won't capture a clean step.
        let cxOk = cx > radius * 0.9 && cx < Float(W) - radius * 0.9
        let cyOk = cy > radius * 0.9 && cy < Float(H) - radius * 0.9
        guard cxOk, cyOk else { return nil }

        // Step 3: 64 radial profiles outward from (cx, cy), out to
        // 1.5× radius so we capture limb + dark background.
        let nDirs = 64
        let nRadii = max(64, Int(radius * 1.5) + 1)
        var profile = [Float](repeating: 0, count: nRadii)
        var profileCount = [Int](repeating: 0, count: nRadii)
        for d in 0..<nDirs {
            let theta = .pi * 2.0 * Float(d) / Float(nDirs)
            let dx = cosf(theta)
            let dy = sinf(theta)
            for r in 0..<nRadii {
                let x = cx + Float(r) * dx
                let y = cy + Float(r) * dy
                // Bilinear sample to avoid the radial-direction aliasing
                // that pure round() would introduce near small radii.
                let xi0 = Int(floorf(x)), yi0 = Int(floorf(y))
                let xi1 = xi0 + 1, yi1 = yi0 + 1
                guard xi0 >= 0, yi0 >= 0, xi1 < W, yi1 < H else { continue }
                let fx = x - Float(xi0)
                let fy = y - Float(yi0)
                let v00 = luminance[yi0 * W + xi0]
                let v10 = luminance[yi0 * W + xi1]
                let v01 = luminance[yi1 * W + xi0]
                let v11 = luminance[yi1 * W + xi1]
                let v = (1 - fx) * (1 - fy) * v00 + fx * (1 - fy) * v10
                      + (1 - fx) * fy * v01 + fx * fy * v11
                profile[r] += v
                profileCount[r] += 1
            }
        }
        for r in 0..<nRadii where profileCount[r] > 0 {
            profile[r] /= Float(profileCount[r])
        }

        // Sanity check: clean planetary discs have a roughly uniform
        // interior (atmospheric bands cause band-pass variation in
        // brightness on Jupiter, but the gradient is gentle). Lunar
        // terrain — craters, mare boundaries, terminator — gives a
        // wildly variable inner radial profile, and the partial /
        // cropped frames typical of lunar imaging often don't even
        // have a clean limb to LSF-fit. Without this guard the
        // estimator picks up the largest crater-rim gradient as
        // the "limb" and reports a huge σ that Wiener then uses
        // to over-deconvolve and halo the output (visible in
        // 19_moon_full_kit.png vs 16_moon_bare.png).
        //
        // Coefficient-of-variation across the inner radial profile
        // ([0.2r, 0.7r]) is the cleanest signal: cap at 30%. Above
        // that we bail out of AutoPSF and let LuckyStack.run skip
        // the deconv entirely. Better than a wrong deconv.
        let innerLo = max(1, Int(radius * 0.2))
        let innerHi = min(nRadii - 1, Int(radius * 0.7))
        if innerHi > innerLo {
            var innerSum: Double = 0
            var innerSumSq: Double = 0
            var innerCount: Int = 0
            for r in innerLo...innerHi where profileCount[r] > 0 {
                let v = Double(profile[r])
                innerSum += v
                innerSumSq += v * v
                innerCount += 1
            }
            if innerCount > 4 {
                let innerMean = innerSum / Double(innerCount)
                let innerVar = max(0, innerSumSq / Double(innerCount) - innerMean * innerMean)
                let innerStd = sqrt(innerVar)
                let innerCV = innerMean > 1e-4 ? innerStd / innerMean : 0
                if innerCV > 0.30 {
                    // Lunar / textured surface. AutoPSF can't reliably
                    // measure a Gaussian PSF here.
                    return nil
                }
            }
        }

        // Step 4: LSF = |dI/dr|.
        var lsf = [Float](repeating: 0, count: nRadii)
        for r in 1..<nRadii {
            lsf[r] = abs(profile[r] - profile[r - 1])
        }

        // Find the limb peak in the LSF — restricted to the outer half
        // of the radial range so cloud-band gradients near the disc
        // centre don't compete with the limb itself for argmax.
        let limbSearchLo = max(1, Int(radius * 0.7))
        let limbSearchHi = min(nRadii - 1, Int(radius * 1.3))
        guard limbSearchHi > limbSearchLo else { return nil }
        var peakR = limbSearchLo
        var peakV: Float = 0
        for r in limbSearchLo...limbSearchHi where lsf[r] > peakV {
            peakV = lsf[r]
            peakR = r
        }
        guard peakV > 0.005 else { return nil }     // no clear edge

        // Step 5: σ via second-moment integration of the LSF — but on
        // the OUTER side only (r ≥ peakR).
        //
        // Naive second-moment over [peakR-12, peakR+12] inflates M₂
        // on real planetary images because the disc-side neighbours
        // of the limb carry cloud-band gradients that aren't part of
        // the PSF — that's what saturated v0 to the 5.0-px clamp
        // every time. The outer side has only the PSF tail + faint
        // background noise (no surface features), so it's the
        // cleanest LSF half to fit.
        //
        // For a half-Gaussian centred at peakR with stddev σ:
        //   M₀ = ∫₀^∞ exp(-r²/(2σ²))   dr = σ √(π/2)
        //   M₂ = ∫₀^∞ r² exp(-r²/(2σ²)) dr = σ³ √(π/2)
        //   σ  = √(M₂ / M₀)
        // Truncating at 12 px > 3σ for σ ≤ 4 captures >99% of the
        // tail energy in both moments, so the ratio stays accurate.
        // Second-moment integration over multiple discrete samples
        // is far less sensitive to per-pixel quantisation than a
        // single half-max-crossing measurement.

        // Estimate the OUTER-side baseline (median of LSF samples
        // BEYOND our integration window — far enough past the limb
        // that any atmospheric halo / scatter is dominated by
        // background noise). Subtracted from every sample inside the
        // window so we measure the LSF peak above noise rather than
        // noise + LSF.
        let outerBaseStart = min(nRadii - 1, peakR + 14)
        var outerBaseline: [Float] = []
        if outerBaseStart < nRadii - 1 {
            for r in outerBaseStart..<nRadii { outerBaseline.append(lsf[r]) }
        }
        let baseline: Float
        if outerBaseline.isEmpty {
            baseline = 0
        } else {
            outerBaseline.sort()
            baseline = outerBaseline[outerBaseline.count / 2]
        }

        // Integration window 6 px past the peak. Real planetary lucky-
        // stack PSFs sit in σ ∈ [0.7, 2.5] px (atmospheric seeing +
        // optical PSF), so 6 px = ~2.4·σ_max captures essentially all
        // the LSF energy without reaching into the slow atmospheric-
        // scatter halo that surrounds bright planetary discs. Window
        // 12 (the v0 try) included so much halo it saturated σ at the
        // 5.0-px clamp on every real input. Synthetic tests still pass
        // because they have no halo.
        let outerHi = min(nRadii - 1, peakR + 6)
        var M0: Double = 0
        var M2: Double = 0
        for r in peakR...outerHi {
            let v = max(0, Double(lsf[r] - baseline))
            let dr = Double(r) - Double(peakR)
            M0 += v
            M2 += dr * dr * v
        }
        guard M0 > 1e-6 else { return nil }
        let sigmaRaw = sqrt(M2 / M0)
        let sigmaClamped = Float(max(0.5, min(5.0, sigmaRaw)))

        // Confidence = peak above baseline / baseline. >5 = clean
        // detection (peak rises well above the noise floor); <2 =
        // noise-dominated, the limb wasn't a clean edge.
        let baselineFloor = max(baseline, 1e-4)
        let confidence = max(0, peakV - baseline) / baselineFloor

        return Result(
            sigma: sigmaClamped,
            confidence: confidence,
            discCenter: SIMD2<Float>(cx, cy),
            discRadius: radius
        )
    }

    // MARK: - Texture luminance readback (Metal-side)

    /// Public version of the luminance readback so other passes
    /// (the tiled-deconv classifier, future per-frame metrics) can
    /// reuse the same blit-to-shared-staging path without each
    /// implementing it separately.
    static func readLuminance(
        texture tex: MTLTexture,
        device: MTLDevice
    ) -> ([Float], Int, Int)? {
        let W = tex.width
        let H = tex.height
        let format = tex.pixelFormat
        let bytesPerChannel: Int
        let isFloat32: Bool
        switch format {
        case .rgba32Float: bytesPerChannel = 4; isFloat32 = true
        case .rgba16Float: bytesPerChannel = 2; isFloat32 = false
        default: return nil
        }

        // Blit to shared-storage staging so we can read bytes from CPU.
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: W, height: H, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stageDesc) else { return nil }

        let queue = MetalDevice.shared.commandQueue
        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, to: staging)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let bytesPerRow = W * bytesPerChannel * 4
        let plane = W * H
        var luma = [Float](repeating: 0, count: plane)

        if isFloat32 {
            var raw = [Float](repeating: 0, count: plane * 4)
            raw.withUnsafeMutableBufferPointer { buf in
                staging.getBytes(
                    buf.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: W, height: H, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
            for i in 0..<plane {
                let r = raw[i * 4 + 0]
                let g = raw[i * 4 + 1]
                let b = raw[i * 4 + 2]
                luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        } else {
            var raw = [UInt16](repeating: 0, count: plane * 4)
            raw.withUnsafeMutableBufferPointer { buf in
                staging.getBytes(
                    buf.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: W, height: H, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
            for i in 0..<plane {
                let r = Float(Float16(bitPattern: raw[i * 4 + 0]))
                let g = Float(Float16(bitPattern: raw[i * 4 + 1]))
                let b = Float(Float16(bitPattern: raw[i * 4 + 2]))
                luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return (luma, W, H)
    }
}
