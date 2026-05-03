// Capture-geometry derived quantities: tile size for blind / tiled
// deconvolution, image-scale arithmetic, sampling regime decisions.
//
// All inputs are user-supplied at preset / target level (focal length,
// pixel pitch, Barlow) — SER headers don't carry them, so a sensible
// default is mandatory. The CLI's `analyze` subcommand will eventually
// surface these values back so the regression harness can verify the
// formulas on real captures (BiggSky's example: 2000 mm + 5 µm = 400 px
// tile, exactly what the doc prescribes).
import Foundation

enum CaptureGeometry {

    /// Tile size in pixels for blind / tiled deconvolution.
    ///
    /// BiggSky's documented formula (David Biggs Google Doc 1):
    ///
    ///     tileSize = round(focalLengthMM / pixelPitchUm × barlowMag, 100)
    ///
    /// with a minimum of 200 pixels and an overlap of 10–20% (smaller
    /// tiles use a larger overlap fraction). Returns the
    /// `defaultFallback` when any required input is missing or invalid.
    static let minimumTileSize = 200
    static let defaultFallback = 500
    static let roundingStep = 100

    static func tileSize(
        focalLengthMM: Double?,
        pixelPitchUm: Double?,
        barlowMagnification: Double = 1.0
    ) -> Int {
        guard
            let f = focalLengthMM,
            let p = pixelPitchUm,
            f.isFinite, p.isFinite,
            f > 0, p > 0
        else {
            return defaultFallback
        }
        let mag = barlowMagnification.isFinite && barlowMagnification > 0
            ? barlowMagnification
            : 1.0
        let raw = (f / p) * mag
        let stepped = (raw / Double(roundingStep)).rounded() * Double(roundingStep)
        let asInt = Int(stepped.rounded())
        return max(minimumTileSize, asInt)
    }

    /// Recommended overlap (in pixels) between adjacent deconv tiles.
    /// Per BiggSky: 10–20% of tile size, more overlap for smaller tiles.
    /// Floored at 20 pixels so even the minimum 200-px tile retains a
    /// meaningful blend zone.
    static func tileOverlap(tileSize: Int) -> Int {
        guard tileSize > 0 else { return 0 }
        let fraction: Double = tileSize <= 200 ? 0.20 : 0.10
        let raw = (Double(tileSize) * fraction).rounded()
        return max(20, Int(raw))
    }

    /// Pixel scale (arc-seconds per pixel) for a focal length / pixel
    /// pitch combination. Used by the under-sampling detector that
    /// decides whether drizzle is worth applying. Returns nil when
    /// inputs are missing or non-positive.
    ///
    /// Formula: arcsecPerPixel = 206.265 × pixelPitchUm / focalLengthMM
    /// (the 206.265 constant converts radians to arc-seconds).
    static func arcsecPerPixel(
        focalLengthMM: Double?,
        pixelPitchUm: Double?,
        barlowMagnification: Double = 1.0
    ) -> Double? {
        guard
            let f = focalLengthMM,
            let p = pixelPitchUm,
            f.isFinite, p.isFinite,
            f > 0, p > 0
        else { return nil }
        let mag = barlowMagnification.isFinite && barlowMagnification > 0
            ? barlowMagnification
            : 1.0
        return 206.265 * p / (f * mag)
    }
}
