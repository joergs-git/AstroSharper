// TransitResult — the decision + measurement(s) produced by TransitDetector for
// a single .ser capture. It mirrors the JSON of the validated Python reference
// `ser_transit.py` for the PRIMARY (strongest) event so the two can be diffed
// field-for-field on the acceptance captures, and extends it in two ways the
// real captures demand:
//
//   • MULTIPLE transits per video — two objects can cross while the recording
//     runs (e.g. one silhouetted on the lunar disc, one passing off to the
//     side). `transits` holds every event, strongest first; the flat top-level
//     JSON fields echo `transits[0]` for reference parity.
//   • MOON mode — geometrically identical to Sun (dark silhouette on a bright
//     disc) but with the Moon's angular diameter for the plate scale.
//
// The JSON uses snake_case keys and OMITS absent fields, matching the Python
// (which builds a dict and only inserts keys that apply). We encode with
// `.convertToSnakeCase` and hand-written containers that use `encodeIfPresent`.
import Foundation

/// Which imaging geometry the detector classified the capture as. `sun` and
/// `moon` share all detection math (bright disc, dark silhouette); they differ
/// only in the angular diameter used for the plate scale and in the label.
enum TransitMode: String, Codable {
    case starfield   // bright transient against a dark sky (ISS crossing a star)
    case sun         // dark silhouette against the bright solar disc/surface
    case moon        // dark silhouette against the bright lunar disc

    /// Angular diameter (degrees) of the disc, used for disc-fit plate scale.
    /// Mean values are fine — the detector reports separation, not ephemeris.
    var discDiameterDeg: Double? {
        switch self {
        case .sun:  return 0.5334   // reference constant (SOLAR_DIAMETER_DEG)
        case .moon: return 0.5181   // mean lunar angular diameter
        case .starfield: return nil
        }
    }

    /// True for the bright-disc geometries that run silhouette detection.
    var isDisc: Bool { self == .sun || self == .moon }
}

/// Where the disc-fit plate scale came from — surfaced so the caller can tell a
/// trustworthy disc-fit from a bailed one (Barlow full-frame / partial disc).
enum PlateScaleSource: String, Codable {
    case discFit        // fitted from the visible disc radius (reference path)
    case focalLength    // computed from supplied focal length + pixel pitch
    case crossCheck     // both available and in agreement
    case none           // no reliable source — degrees are null
}

/// One detected object crossing. A moving track carries full line geometry; a
/// single-frame blob carries only its position and strength.
struct TransitEvent: Codable, Equatable {
    var moving: Bool
    var nActive: Int
    var activeFrames: [Int]           // [start, end] for a track; [frame] for a blob

    // Track geometry (moving == true). FULL-resolution pixels.
    var entryPx: [Int]?               // [x, y]
    var exitPx: [Int]?
    var trackLenPx: Double?
    var speedPxPerFrame: Double?
    var directionDeg: Double?
    var straightnessR2: Double?

    // Separation from the target (Vega for star-field, disc centre for disc modes).
    var separationPx: Double
    var peakZAtObject: Double?         // single-blob case: strength in sigma units
    var separationDeg: Double?         // disc modes only, when a plate scale exists

    // Disc modes: was the object a silhouette ON the disc, or a bright transient
    // passing OFF to the side? Drives the dual-polarity search. nil in star-field.
    var onDisc: Bool?
}

struct TransitResult: Codable, Equatable {
    var mode: TransitMode
    var frames: Int
    var detected: Bool

    /// Every detected event, strongest first. Empty when `detected == false`.
    var transits: [TransitEvent]

    // Capture-level plate scale (disc modes).
    var plateScaleArcsecPx: Double?
    var plateScaleSource: PlateScaleSource?
    var discReliable: Bool?            // false when disc-fit bailed (Barlow / partial disc)

    init(mode: TransitMode, frames: Int, detected: Bool, transits: [TransitEvent] = []) {
        self.mode = mode
        self.frames = frames
        self.detected = detected
        self.transits = transits
    }

    // MARK: - Convenience for the GUI

    /// The strongest event, if any.
    var primary: TransitEvent? { transits.first }

    /// True when there's at least one measured, time-contiguous moving track
    /// worth exporting — the signal that drives the filename icon and auto-trim.
    var hasMovingTransit: Bool { detected && transits.contains { $0.moving } }

    /// The [start, end] frame range to auto-set as export trim marks: the union
    /// span of all moving transits (so a two-object pass captures both).
    var trimFrameRange: (Int, Int)? {
        let ranges = transits.filter { $0.moving && $0.activeFrames.count >= 2 }
        guard !ranges.isEmpty else { return nil }
        let lo = ranges.map { min($0.activeFrames[0], $0.activeFrames[1]) }.min()!
        let hi = ranges.map { max($0.activeFrames[0], $0.activeFrames[1]) }.max()!
        return (lo, hi)
    }

    // MARK: - Reference-compatible JSON

    /// Pretty JSON matching the Python reference: the primary event's fields are
    /// flattened at the top level (so acceptance diffs line up), plus a
    /// `transits` array carrying every event for the multi-object captures.
    func jsonString() -> String {
        var obj: [String: Any] = [
            "mode": mode.rawValue,
            "frames": frames,
            "detected": detected,
        ]
        if let p = primary {
            flatten(event: p, into: &obj)
        }
        if let s = plateScaleArcsecPx { obj["plate_scale_arcsec_px"] = s }
        if let src = plateScaleSource { obj["plate_scale_source"] = src.rawValue }
        if let dr = discReliable { obj["disc_reliable"] = dr }
        if transits.count > 1 {
            obj["transits"] = transits.map { event -> [String: Any] in
                var e: [String: Any] = [:]
                flatten(event: event, into: &e)
                return e
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func flatten(event e: TransitEvent, into obj: inout [String: Any]) {
        obj["moving"] = e.moving
        obj["n_active"] = e.nActive
        obj["active_frames"] = e.activeFrames
        if let v = e.entryPx { obj["entry_px"] = v }
        if let v = e.exitPx { obj["exit_px"] = v }
        if let v = e.trackLenPx { obj["track_len_px"] = v }
        if let v = e.speedPxPerFrame { obj["speed_px_per_frame"] = v }
        if let v = e.directionDeg { obj["direction_deg"] = v }
        if let v = e.straightnessR2 { obj["straightness_r2"] = v }
        obj["separation_px"] = e.separationPx
        if let v = e.peakZAtObject { obj["peak_z_at_object"] = v }
        if let v = e.separationDeg { obj["separation_deg"] = v }
        if let v = e.onDisc { obj["on_disc"] = v }
    }
}
