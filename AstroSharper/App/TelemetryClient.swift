// Anonymous telemetry client for AstroSharper.
//
// Why this exists: AutoAP's defaults (patchHalf coefficient, RFF knee,
// gate threshold) are currently hand-tuned against ~6 BiggSky fixtures.
// With opt-out anonymous telemetry from the actual user fleet, the
// defaults can converge on what works empirically across hundreds of
// captures and dozens of telescope / camera combos. Every other lucky-
// imaging app guesses; this is the only path to data-backed defaults.
//
// Privacy contract (the entire payload):
//   - machineUUID  : random UUID generated locally, never derived from
//                    hardware. See MachineID.swift.
//   - schemaVersion: 1 (so future payload changes are routable)
//   - event        : "stack_completed" — only event for now
//   - target       : detected target keyword (sun/moon/jupiter/...) or null
//   - frameCount   : SER frame count (integer)
//   - imageWidth   : SER frame width (px)
//   - imageHeight  : SER frame height (px)
//   - autoPSFSigma : AutoPSF measured PSF σ in px, or null (bail)
//   - autoAPGrid   : AutoAP-resolved grid edge length
//   - autoAPPatch  : AutoAP-resolved patchHalf in px
//   - shiftSigma   : temporal shift std-dev (gate signal)
//   - elapsedSec   : wall-clock total
//   - autoNuke     : bool — whether AutoNuke was on
//   - appVersion   : marketing version string
//   - timestamp    : ISO-8601 UTC, second precision
//
// What's intentionally NOT sent: filenames, paths, telescope/camera
// strings, focal length, capture timestamps, IP, email, hostname,
// Mac model, Apple ID, presets the user saved. So the payload can't
// be linked back to the user even if the database leaks.
//
// Default OPT-OUT: telemetry is on by default. The user can disable
// it via the bottom-bar status icon at any time, which sets
// `userDisabled = true` in UserDefaults — every send becomes a no-op
// instantly, no app restart needed.
//
// Wiring TODO: this client batches events to NSLog only for now. A
// Supabase edge function endpoint will be wired in a follow-up
// session — the payload shape above is locked in so the function
// can be authored against it.
import Foundation

/// One stack-completed event payload. Shape is the public contract
/// with the Supabase edge function — fields are added at the end as
/// new schema versions, never renamed.
///
/// Custom `encode(to:)` is required so optional keys (`target`,
/// `autoPSFSigma`, `shiftSigma`) always appear in the JSON as `null`
/// when nil. Default synthesised `Codable` skips nil keys entirely;
/// the server's validator expects them present, so a missing key
/// returns HTTP 400 ("Payload shape mismatch").
struct TelemetryEvent: Codable {
    let machineUUID: String
    let schemaVersion: Int
    let event: String
    let target: String?
    let frameCount: Int
    let imageWidth: Int
    let imageHeight: Int
    let autoPSFSigma: Double?
    let autoAPGrid: Int
    let autoAPPatch: Int
    let shiftSigma: Double?
    let elapsedSec: Double
    let autoNuke: Bool
    let appVersion: String
    let timestamp: String

    private enum CodingKeys: String, CodingKey {
        case machineUUID, schemaVersion, event, target,
             frameCount, imageWidth, imageHeight,
             autoPSFSigma, autoAPGrid, autoAPPatch,
             shiftSigma, elapsedSec, autoNuke,
             appVersion, timestamp
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machineUUID,   forKey: .machineUUID)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(event,         forKey: .event)
        try c.encode(target,        forKey: .target)         // emits null when nil
        try c.encode(frameCount,    forKey: .frameCount)
        try c.encode(imageWidth,    forKey: .imageWidth)
        try c.encode(imageHeight,   forKey: .imageHeight)
        try c.encode(autoPSFSigma,  forKey: .autoPSFSigma)   // emits null when nil
        try c.encode(autoAPGrid,    forKey: .autoAPGrid)
        try c.encode(autoAPPatch,   forKey: .autoAPPatch)
        try c.encode(shiftSigma,    forKey: .shiftSigma)     // emits null when nil
        try c.encode(elapsedSec,    forKey: .elapsedSec)
        try c.encode(autoNuke,      forKey: .autoNuke)
        try c.encode(appVersion,    forKey: .appVersion)
        try c.encode(timestamp,     forKey: .timestamp)
    }
}

enum TelemetryClient {
    private static let optOutKey = "AstroSharper.telemetryOptedOut"

    /// User-controlled opt-out. Default false (telemetry on). The
    /// status-bar toggle sets / clears this — no app restart needed.
    static var userDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: optOutKey) }
        set { UserDefaults.standard.set(newValue, forKey: optOutKey) }
    }

    /// Build + send a stack-completed event. No-op when the user has
    /// opted out. All inputs come from the runner's already-computed
    /// state, so no extra measurement work happens here.
    static func recordStackCompleted(
        target: String?,
        frameCount: Int,
        imageWidth: Int,
        imageHeight: Int,
        autoPSFSigma: Double?,
        autoAPGrid: Int,
        autoAPPatch: Int,
        shiftSigma: Double?,
        elapsedSec: Double,
        autoNuke: Bool
    ) {
        guard !userDisabled else { return }
        let event = TelemetryEvent(
            machineUUID: MachineID.current,
            schemaVersion: 1,
            event: "stack_completed",
            target: target,
            frameCount: frameCount,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            autoPSFSigma: autoPSFSigma,
            autoAPGrid: autoAPGrid,
            autoAPPatch: autoAPPatch,
            shiftSigma: shiftSigma,
            elapsedSec: elapsedSec,
            autoNuke: autoNuke,
            appVersion: AppVersion.shortString,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        send(event)
    }

    /// Sends an event to the Supabase `stack-completed` edge function.
    /// Logs the JSON payload via NSLog regardless (useful for
    /// debugging when the network call is gated off via
    /// `SupabaseConfig.networkEnabled`).
    ///
    /// Network failure must NEVER affect the user's stack workflow —
    /// the URLSession task is detached, fire-and-forget, with a 5 s
    /// timeout. Failures are logged but not retried (the user
    /// population is large enough that drops don't bias the data;
    /// adding a disk-backed retry queue can come later if real
    /// telemetry shows lossy networks dominating).
    private static func send(_ event: TelemetryEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        NSLog("Telemetry: %@", json)

        guard SupabaseConfig.networkEnabled else { return }

        var request = URLRequest(url: SupabaseConfig.stackCompletedURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                NSLog("Telemetry POST failed: %@", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                NSLog("Telemetry POST returned HTTP %d", http.statusCode)
            }
        }.resume()
    }
}
