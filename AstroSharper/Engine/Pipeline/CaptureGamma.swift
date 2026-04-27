// Capture-gamma compensation. In-camera gamma boosts the brightness of
// dark features (good for capture monitoring, bad for deconvolution).
// Most planetary cameras (ZWO ASI series, SharpCap acquisition presets)
// apply gamma > 1 by default; values land in the SER non-linearly.
//
// Running deconvolution on a non-linear image produces edge-ringing
// artifacts at the planet limb because the deconvolution algorithm
// assumes a linear forward model. Pre-linearizing the data
// (`linear = encoded ^ gamma`) restores the linear assumption and
// removes the ringing.
//
// BiggSky's documentation accepts both representations:
//   * actual gamma exponent: 1.0, 1.5, 2.0, 2.2
//   * camera UI value: 50, 100, 200 (ZWO/SharpCap slider — 50 ≈ linear)
//
// We expose a small adapter for the UI slider convention; the engine-
// level functions all take the actual exponent so the rest of the
// pipeline doesn't need to know which UI dialect the value came from.
import Foundation

enum CaptureGamma {

    /// Convert a camera-UI gamma slider value to the equivalent exponent.
    ///
    /// ZWO ASI and SharpCap use a 0–200 slider where 50 represents the
    /// linear / neutral setting. Mapping: `gamma = sliderValue / 50`.
    /// So 50 → 1.0 (linear), 100 → 2.0, 200 → 4.0.
    ///
    /// Clamps the result into a sensible range to keep downstream
    /// `pow(x, gamma)` numerically tame.
    static func gamma(fromCameraSliderValue value: Double) -> Double {
        let raw = value / 50.0
        return clamp(raw)
    }

    /// Linearise a single sample. Encoded data assumed in [0, 1+]
    /// range; the function works for super-bright float samples too
    /// (deconvolution outputs can exceed 1 — see ImageTexture.BitDepth.float32).
    @inline(__always)
    static func linearize(_ encoded: Float, gamma: Double) -> Float {
        guard gamma.isFinite, gamma > 0 else { return encoded }
        // gamma == 1 → identity. Avoid pow() to keep rounding clean.
        if gamma == 1.0 { return encoded }
        // Negative samples (rare; e.g. Wiener residuals) pass through
        // unchanged — pow() of a negative is undefined for non-integer
        // exponents.
        if encoded < 0 { return encoded }
        return Float(Foundation.pow(Double(encoded), gamma))
    }

    /// Apply linearisation to a buffer in place. Returns a new array
    /// rather than mutating to keep the test target's value-semantics
    /// expectations clean. Callers in the GPU pipeline should use the
    /// equivalent Metal kernel (added when blind deconv lands —
    /// pow() per-pixel on the shader.) For now this is the CPU
    /// reference + small-buffer fast path.
    static func linearize(buffer: [Float], gamma: Double) -> [Float] {
        guard gamma.isFinite, gamma > 0, gamma != 1.0 else { return buffer }
        var out = buffer
        for i in 0..<out.count {
            out[i] = linearize(out[i], gamma: gamma)
        }
        return out
    }

    /// Detect whether a numeric input is more likely a camera UI value
    /// vs. an actual gamma exponent. The two domains overlap at small
    /// values, so we use the heuristic: `value > 4.5` is almost
    /// certainly a slider position (real gamma values rarely exceed
    /// 3.0 in any imaging pipeline).
    static func looksLikeCameraSlider(_ value: Double) -> Bool {
        value > 4.5
    }

    // MARK: - Internals

    /// Clamp gamma to the practical range [0.1, 4.0]. Outside this band
    /// pow() produces values that are either undetectable noise or
    /// overflow into the float-format ceiling.
    private static func clamp(_ gamma: Double) -> Double {
        guard gamma.isFinite else { return 1.0 }
        return Swift.max(0.1, Swift.min(4.0, gamma))
    }
}
