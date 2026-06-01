// Purple-fringe auto-suppression (LSW 7.1 "Reduce purple" parity).
//
// OSC (one-shot color) bayer cameras tend to produce purple fringes
// around bright planetary limbs / lunar terminators — a combination
// of atmospheric chromatic dispersion (blue and red shift in opposite
// directions) and the bayer demosaic introducing colour errors at
// high-contrast edges. After gray-world auto-WB centers the means
// and channel-normalize aligns the ranges, the purple cast often
// REMAINS because it's hue-specific noise, not a channel-wide bias.
//
// This module mixes pixels in the purple hue band (270°–310°) toward
// their per-pixel luma, leaving every other hue untouched. Strength
// controls how much of the luma the pixel gets — 1.0 = full
// desaturation to grayscale, 0.5 = halfway, 0.0 = pass-through.
//
// Auto-engagement (`shouldEngage`): trigger only when a sample of
// the input contains a non-trivial fraction of pixels in the purple
// hue band. Below that threshold the kernel is wasted GPU work.
//
// Hue formulation: classical HSV with R/G/B in [0, 1]. Saturation is
// (max - min) / max — chroma normalised by value. Both are checked
// because pure highlights at hue=290° are usually clipped white
// (saturation ≈ 0) and shouldn't be touched.
import Foundation

enum PurpleFringe {

    /// Compute the desaturation strength for an RGB triple. Returns
    /// a value in `[0, strength]`:
    ///   - 0 means hue is outside the purple band → leave pixel alone
    ///   - `strength` means pixel sits dead centre of the band → full mix
    /// Pure Swift so the Metal kernel's per-pixel result can be unit-
    /// tested against this reference implementation.
    static func desatFactor(r: Float, g: Float, b: Float, strength: Float) -> Float {
        let s = saturation(r: r, g: g, b: b)
        // Don't touch low-saturation pixels — they're highlights or
        // near-grey, not purple fringe. 5% saturation floor matches
        // LSW's "Reduce Purple" empirical sweet spot.
        if s < 0.05 { return 0 }
        let h = hueDegrees(r: r, g: g, b: b)
        // Distance from the purple band centre (290°), wrapped around
        // the colour wheel.
        var d = abs(h - 290.0)
        if d > 180.0 { d = 360.0 - d }
        // Bandwidth ±30° — covers indigo-blue (270°) through magenta
        // (320°). Cosine-squared falloff so the kernel is smooth at
        // the band edges (no visible boundary in the output).
        let bandwidth: Float = 30.0
        if d > bandwidth { return 0 }
        let t = cos((d / bandwidth) * .pi / 2.0)
        return strength * t * t
    }

    /// Apply the desat blend to a single RGB triple. Returns the
    /// modified (r, g, b). Pixels outside the purple band are returned
    /// unchanged.
    static func apply(r: Float, g: Float, b: Float, strength: Float) -> (r: Float, g: Float, b: Float) {
        let f = desatFactor(r: r, g: g, b: b, strength: strength)
        if f <= 0 { return (r, g, b) }
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (
            r * (1 - f) + luma * f,
            g * (1 - f) + luma * f,
            b * (1 - f) + luma * f
        )
    }

    /// Auto-engagement gate. Counts the fraction of pixels whose hue
    /// sits in the purple band AND has saturation ≥ 0.05. Returns true
    /// when ≥ 0.5% of the sample (typical OSC bayer planetary captures
    /// hit 1-3% near the limb when fringing is visible).
    static func shouldEngage(red: [Float], green: [Float], blue: [Float]) -> Bool {
        guard !red.isEmpty,
              red.count == green.count,
              red.count == blue.count
        else { return false }
        var purpleCount = 0
        for i in 0..<red.count {
            let r = red[i], g = green[i], b = blue[i]
            let s = saturation(r: r, g: g, b: b)
            if s < 0.05 { continue }
            let h = hueDegrees(r: r, g: g, b: b)
            var d = abs(h - 290.0)
            if d > 180.0 { d = 360.0 - d }
            if d <= 30.0 { purpleCount += 1 }
        }
        let frac = Double(purpleCount) / Double(red.count)
        return frac >= 0.005
    }

    // MARK: - Helpers

    /// HSV hue in degrees 0..360. Returns 0 for grayscale pixels
    /// (saturation = 0) because the hue is mathematically undefined.
    static func hueDegrees(r: Float, g: Float, b: Float) -> Float {
        let cmax = max(r, max(g, b))
        let cmin = min(r, min(g, b))
        let delta = cmax - cmin
        if delta < 1e-6 { return 0 }
        let h: Float
        if cmax == r {
            h = 60.0 * ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if cmax == g {
            h = 60.0 * ((b - r) / delta + 2.0)
        } else {
            h = 60.0 * ((r - g) / delta + 4.0)
        }
        return h < 0 ? h + 360.0 : h
    }

    static func saturation(r: Float, g: Float, b: Float) -> Float {
        let cmax = max(r, max(g, b))
        if cmax < 1e-6 { return 0 }
        let cmin = min(r, min(g, b))
        return (cmax - cmin) / cmax
    }
}
