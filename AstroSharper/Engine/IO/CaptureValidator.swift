// SER capture-side header validator. Produces a non-modal list of
// warnings + suggestions about a capture's parameters so the user
// catches a bad recording before they spend a quarter-hour stacking
// it. No competitor surfaces these inline — distinctive UX win.
//
// Required inputs come straight from the SER header. Optional inputs
// (exposure, frame rate, gain, target) are user-supplied where the
// capture-app sidecar (.txt) didn't make it into the file: SER itself
// doesn't carry exposure or fps fields, so callers thread them through
// when available.
//
// All findings are non-blocking. The HUD layer turns them into
// inline yellow chips next to the relevant HUD field. None of the
// downstream pipeline acts on them — they exist purely for UX.
import Foundation

/// One actionable finding produced by `CaptureValidator.validate`.
struct CaptureWarning: Equatable {
    enum Severity: String, Codable {
        case info       // worth knowing, no immediate action
        case warning    // actively recommend a different setting
        case advisory   // cross-cutting suggestion (e.g. derotation)
    }

    /// Stable identifier so UI can suppress / re-order findings without
    /// matching on display strings. Free-form lowercase-with-dots.
    let code: String
    let severity: Severity
    let message: String
    /// Concrete remediation line ("Recapture at 60 fps" / "Switch to
    /// 16-bit"). nil when the warning is purely informational.
    let suggestion: String?
}

enum CaptureValidator {

    // MARK: - Thresholds (BiggSky / lucky-imaging norms)

    /// Atmospheric coherence time τ₀ practically caps planetary exposure
    /// at ~10 ms; we warn above 15 ms (with margin for solar Hα).
    static let maxExposureMs: Double = 15.0

    /// Frame rates below 30 fps starve the lucky-tail selection process.
    static let minFrameRateFPS: Double = 30.0

    /// Below 100 kept frames the SNR floor (`SNR ∝ √N`) is the limiting
    /// factor regardless of seeing — see SerQualityScanner.
    static let minFrameCount: Int = 100

    /// Past this point capture windows on Jupiter / Saturn introduce
    /// rotational blur faster than lucky imaging can compensate;
    /// derotation becomes mandatory.
    static let derotationCaptureWindowSeconds: Double = 180

    /// Tiled deconvolution requires a 200-px tile minimum (BiggSky).
    static let minTileSize: Int = 200

    // MARK: - Public API

    /// Run all rules against a SER header + optional user metadata.
    /// Returns findings in stable order (header rules first, then
    /// per-target advisories) so the UI can render them deterministically.
    static func validate(
        header: SerHeader,
        target: PresetTarget? = nil,
        exposureMs: Double? = nil,
        frameRateFPS: Double? = nil
    ) -> [CaptureWarning] {
        var out: [CaptureWarning] = []

        // 1. Bit depth.
        if header.pixelDepthPerPlane <= 8 {
            switch target {
            case .sun, .moon:
                out.append(CaptureWarning(
                    code: "bitdepth.low",
                    severity: .warning,
                    message: "Capture is 8-bit on a high-dynamic-range target.",
                    suggestion: "Recapture at 16-bit to preserve detail in dark and bright regions."
                ))
            case .jupiter, .saturn, .mars, .other:
                out.append(CaptureWarning(
                    code: "bitdepth.low.planetary",
                    severity: .info,
                    message: "Capture is 8-bit. Planetary targets work but lose deconv headroom.",
                    suggestion: "Consider 16-bit on next session for cleaner sharpening."
                ))
            case .none:
                out.append(CaptureWarning(
                    code: "bitdepth.low.unknown",
                    severity: .info,
                    message: "Capture is 8-bit.",
                    suggestion: "Switch to 16-bit if your camera supports it."
                ))
            }
        }

        // 2. Frame count.
        if header.frameCount < minFrameCount {
            out.append(CaptureWarning(
                code: "frames.few",
                severity: .warning,
                message: "Only \(header.frameCount) frames — lucky imaging needs many shots to find the sharp tail.",
                suggestion: "Recapture with at least \(minFrameCount * 10) frames; SNR scales with √N."
            ))
        }

        // 3. Image dimensions.
        if header.imageWidth < minTileSize || header.imageHeight < minTileSize {
            out.append(CaptureWarning(
                code: "frame.small",
                severity: .info,
                message: "Frame is \(header.imageWidth)×\(header.imageHeight); tiled deconv needs ≥ \(minTileSize) px on each side.",
                suggestion: "Use single-PSF deconv mode for crops smaller than \(minTileSize) px."
            ))
        }

        // 4. Capture timestamp.
        if header.dateUTC == nil {
            out.append(CaptureWarning(
                code: "timestamp.missing",
                severity: .info,
                message: "Capture has no UTC timestamp.",
                suggestion: "Derotation needs the capture mid-time; you'll have to enter it manually."
            ))
        }

        // 5. Exposure (optional input).
        if let ms = exposureMs, ms > maxExposureMs {
            out.append(CaptureWarning(
                code: "exposure.long",
                severity: .warning,
                message: String(format: "Exposure %.1f ms exceeds atmospheric coherence τ₀ (~5–10 ms).",
                                ms),
                suggestion: "Drop to ≤ 10 ms to freeze atmospheric turbulence."
            ))
        }

        // 6. Frame rate (optional input).
        if let fps = frameRateFPS, fps > 0, fps < minFrameRateFPS {
            out.append(CaptureWarning(
                code: "fps.low",
                severity: .warning,
                message: String(format: "Capture rate %.0f fps is below the 30 fps lucky-imaging floor.",
                                fps),
                suggestion: "Smaller ROI / shorter exposure / higher gain typically lifts capture rate."
            ))
        }

        // 7. Capture window vs derotation (only when fps is supplied).
        if let fps = frameRateFPS, fps > 0 {
            let windowSec = Double(header.frameCount) / fps
            if windowSec > derotationCaptureWindowSeconds,
               target == .jupiter || target == .saturn {
                out.append(CaptureWarning(
                    code: "derotation.advisory",
                    severity: .advisory,
                    message: String(format: "Capture window is %.0f s on a fast-rotating planet.", windowSec),
                    suggestion: "Run derotation when stacking — rotational blur dominates past ~180 s."
                ))
            }
        }

        return out
    }
}
