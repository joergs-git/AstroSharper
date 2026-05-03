// Supabase configuration for opt-out telemetry + community share.
//
// Shared with the AstroBlink / AstroTriage project — both apps write
// to the same Supabase database, distinguished by the `app` column on
// every table (see supabase/migrations/20260503_astrosharper_extension.sql).
//
// The anon key is a publishable identifier and is intentionally
// committed to the repo — it gates only INSERT operations on
// RLS-protected tables, never SELECT of personal data. Same posture
// as AstroTriage's BenchmarkConfig (visible in
// AstroTriage/Engine/BenchmarkSharing.swift).
//
// Endpoint URLs are derived from the project URL. Both edge functions
// are public-facing (no JWT required) — the rate-limit + payload
// validation happens server-side in each function.
import Foundation

enum SupabaseConfig {
    /// Project URL — same project as AstroBlink. Enables joint
    /// admin (one dashboard, one billing line) at the cost of
    /// shared rate limits across both apps.
    static let projectURL = URL(string: "https://bpngramreznwvtssrcbe.supabase.co")!

    /// Publishable anon key — INSERT-only against RLS-protected
    /// tables. Mirrors AstroTriage's BenchmarkConfig.supabaseAnonKey.
    static let anonKey = "sb_publishable_NROHg8DwJvvdfdyr7JIcog_nILiDe9U"

    /// Master kill-switch for all telemetry / community-share network
    /// traffic. Flipped to `true` on 2026-05-03 after the AstroBlink
    /// shared-DB migration landed and both edge functions
    /// (`stack-completed`, `community-thumbnail`) were end-to-end
    /// smoke-tested with HTTP 201 responses.
    /// Per-feature opt-out (status-bar icons) sits BELOW this gate —
    /// even with this `true` the user can disable telemetry +
    /// community share independently. The coffee popup is gated
    /// SEPARATELY by `coffeePromptEnabled` in `AstroSharperApp.swift`
    /// (still off until first public release).
    static let networkEnabled: Bool = true

    // MARK: - Endpoint URLs

    static var stackCompletedURL: URL {
        projectURL.appendingPathComponent("functions/v1/stack-completed")
    }

    static var communityThumbnailURL: URL {
        projectURL.appendingPathComponent("functions/v1/community-thumbnail")
    }

    /// Read endpoint for the "Show other peoples thumbs" window —
    /// returns the latest 50 thumbnails (max 3 per machine) with
    /// signed-URL TTL of 1h.
    static var communityFeedURL: URL {
        projectURL.appendingPathComponent("functions/v1/community-feed")
    }
}
