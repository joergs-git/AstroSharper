// Auto-skip calibration policy.
//
// Pre-stack calibration (master dark / flat / bias) is the deep-sky
// reflex but planetary / lunar / solar lucky imaging often skips it:
// short exposures generate negligible thermal noise, vignetting is
// minor on the small ROIs typical for planetary work, and recapturing
// the master frames per session burns time the user could spend
// gathering more frames. BiggSky's documentation calls this out
// explicitly — "automatic flat/dark frame handling" is an upcoming
// feature, not a default.
//
// We encode the heuristic here so the H.5 automation block can read
// off a sensible default without re-implementing the rule each time.
// User always retains the manual override; this just sets the toggle's
// initial state on import + preset switch.
import Foundation

enum CalibrationPolicy {

    /// Per BiggSky guidance: ≤15 ms exposures on Moon / Sun / Jupiter
    /// produce no measurable improvement from calibration frames. The
    /// boundary is the same atmospheric coherence-time threshold the
    /// CaptureValidator uses (`maxExposureMs`); above that we assume
    /// the capture was long enough for thermal noise + vignetting to
    /// matter.
    static let shortExposureThresholdMs: Double = 15.0

    /// Recommend whether pre-stack calibration should be ON by default
    /// for a given capture.
    ///
    /// Defaults conservative: when target or exposure are unknown we
    /// recommend ON (slower, but correct). The caller can flip the UI
    /// toggle off manually any time.
    ///
    /// - Parameters:
    ///   - target: detected or user-picked target for this capture.
    ///   - exposureMs: exposure per frame, when known (SER doesn't
    ///     carry it; SharpCap / FireCapture sidecar .txt usually does).
    /// - Returns: true → calibration recommended ON; false → recommended
    ///   skipped.
    static func recommendsOnByDefault(
        target: PresetTarget?,
        exposureMs: Double?
    ) -> Bool {
        // Without exposure data we can't be confident — default to the
        // safe path (ON).
        guard let ms = exposureMs else { return true }

        switch target {
        case .moon, .sun, .jupiter:
            // Bright + short: skip when exposure is below the threshold.
            return ms > shortExposureThresholdMs
        case .mars, .saturn:
            // Dimmer / longer captures benefit from calibration.
            return true
        case .other, .none:
            // Anything we don't recognise — conservative ON.
            return true
        }
    }

    /// Human-readable rationale string useful for the UI tooltip when
    /// the auto-rule turns calibration OFF unexpectedly.
    static func explainRecommendation(
        target: PresetTarget?,
        exposureMs: Double?,
        on: Bool
    ) -> String {
        if on {
            if exposureMs == nil {
                return "Calibration default: ON (no exposure metadata available — safer to apply darks / flats)."
            }
            switch target {
            case .mars, .saturn:
                return "Calibration default: ON for \(target?.rawValue ?? "this target") — long-exposure capture benefits."
            case .moon, .sun, .jupiter:
                let ms = exposureMs ?? 0
                return String(
                    format: "Calibration default: ON — exposure %.1f ms is past the %.0f ms short-exposure threshold.",
                    ms, shortExposureThresholdMs
                )
            default:
                return "Calibration default: ON — conservative default for unknown target."
            }
        } else {
            let ms = exposureMs ?? 0
            return String(
                format: "Calibration default: OFF — short-exposure (%.1f ms) bright target benefits little from calibration frames per BiggSky guidance.",
                ms
            )
        }
    }
}
