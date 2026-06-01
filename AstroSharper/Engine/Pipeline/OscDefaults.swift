// One-shot-color (OSC) auto-defaults (Block D.3).
//
// When a user opens a Bayer SER (or any AVI — AVFoundation pre-debayers
// to RGB regardless of the camera's native pattern) the live-preview
// tone-curve stage benefits from a default-on auto white balance pass.
// Mono captures never need WB — gray-world collapses to identity on a
// single channel anyway, but skipping the GPU pass altogether is
// cheaper and keeps the preview HUD's `colourLevels` indicator off
// when there's nothing to do.
//
// This module isolates the "is this source OSC?" detection plus the
// minimal mutation that turns autoWB on. It's CPU-only (SerReader does
// the read) and keeps AppModel free of SER-format awareness.
//
// Pure Foundation; the SerReader peek is sub-millisecond on Apple
// Silicon (memory-mapped 178-byte header read).
import Foundation

enum OscDefaults {

    /// Returns true when the given URL points to a one-shot-color
    /// source (Bayer SER, RGB SER, or AVI). Mono SER returns false.
    /// Failure to open (corrupt header, unreadable file) returns
    /// false — the caller falls back to mono-style defaults rather
    /// than blindly enabling colour correction on something we can't
    /// classify.
    static func isOSC(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ser":
            guard let reader = try? SerReader(url: url) else { return false }
            return reader.colorID.isBayer || reader.colorID.isRGB
        case "avi", "mov", "mp4", "m4v":
            // AVFoundation hands us pre-debayered RGB regardless of the
            // source camera's native Bayer pattern. Treat as OSC.
            return true
        default:
            return false
        }
    }

    /// Applies OSC-friendly defaults to the passed-in tone-curve
    /// settings: turns `autoWB` on (gray-world mean align) AND
    /// `channelNormalize` on (LSW 7.2.1 per-channel histogram stretch
    /// to align p1/p99 windows). The two compose — auto-WB neutralises
    /// the green cast first, the normalize pass handles any remaining
    /// histogram spread that gray-world leaves behind. Idempotent: a
    /// no-op when the source is mono or both flags are already enabled.
    ///
    /// `channelNormalize` itself has an internal auto-engage gate (p99
    /// spread > 30%) so flipping the toggle on isn't a commitment to
    /// always processing — it's "engage when there's a real skew to
    /// fix". Auto-WB has no such gate; it always runs when the toggle
    /// is on (the gray-world correction collapses to identity on
    /// already-balanced sources anyway).
    ///
    /// Returns true iff a change was made (the caller can use the
    /// signal to log the auto-engagement, or skip a redundant settings
    /// publish).
    @discardableResult
    static func applyDefaults(to tone: inout ToneCurveSettings, for url: URL) -> Bool {
        guard isOSC(url: url) else { return false }
        var changed = false
        if !tone.autoWB {
            tone.autoWB = true
            changed = true
        }
        if !tone.channelNormalize {
            tone.channelNormalize = true
            changed = true
        }
        // Purple-fringe reduction also gets the default-on treatment
        // on OSC sources. The GPU kernel itself short-circuits on
        // pixels outside the purple band, so mono / already-clean
        // OSC sources pay only the per-pixel saturation + hue test
        // (no expensive blend). LSW 7.1 calls this out as a typical
        // OSC-only post-processing step.
        if !tone.reducePurpleFringe {
            tone.reducePurpleFringe = true
            changed = true
        }
        return changed
    }
}
