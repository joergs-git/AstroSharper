// Stable per-machine identifier for opt-out anonymous telemetry +
// community share.
//
// Stored in UserDefaults on first access; survives app updates and
// preset/data resets but resets if the user wipes their UserDefaults
// (or installs in a fresh sandbox container). NOT a persistent device
// identifier — it lives in the app's sandbox only.
//
// This is the ONLY identifying field sent in telemetry / community
// payloads. No IP geolocation, no email, no Apple ID, no hostname,
// no Mac model — by design, so the GDPR question stays "no personal
// data is being processed" without lawyer involvement.
import Foundation

enum MachineID {
    private static let key = "AstroSharper.machineUUID.v1"

    /// Returns the persistent random UUID for this install. Generates
    /// + writes a new one the first time it's called, then returns it
    /// unchanged on every subsequent call.
    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// First-8-chars short form for display (e.g. in About / status
    /// bar tooltip) so the user can see what's being sent without
    /// exposing the full UUID.
    static var shortDisplay: String {
        String(current.prefix(8))
    }
}
