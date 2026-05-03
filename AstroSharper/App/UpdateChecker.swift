// Update checker — fetches a small JSON manifest from the public
// GitHub repo on every launch and compares against the running
// app's CFBundleShortVersionString. Surfaces an alert with
// Download / Later / Skip-this-version when a newer release exists.
//
// Privacy contract: this is a one-way GET to a public URL. No
// machine UUID, no headers beyond the default URLSession ones, no
// telemetry event recorded. The user can still suppress all future
// prompts for a specific version via "Skip this version" — that
// preference lives in UserDefaults and is never sent anywhere.
//
// Why a JSON manifest instead of GitHub's Releases API: the API
// imposes a 60-req/hour unauthenticated rate limit and forces auth
// for higher quotas. A static JSON in `main` has no rate limit, no
// auth, and is trivially editable as part of the release procedure.
//
// Release procedure (also in memory/project_release_workflow.md):
//   1. Bump MARKETING_VERSION in project.yml.
//   2. Build + notarize + upload DMG to a GitHub release.
//   3. Edit latest-release.json: latestVersion, releaseDate,
//      releaseNotesURL, downloadURL.
//   4. Commit + push to main → manifest is immediately live for
//      the next launch on every existing user's machine.
import Foundation

/// Shape of the JSON hosted at
/// https://raw.githubusercontent.com/joergs-git/AstroSharper/main/latest-release.json
struct LatestReleaseInfo: Decodable {
    let latestVersion: String
    let releaseDate: String
    let releaseNotesURL: String
    let downloadURL: String
    /// Minimum version that should still keep working. Currently
    /// informational only — could later drive a "your version is
    /// no longer supported" hard gate, but the friendly default is
    /// just "you should update".
    let minVersion: String?
}

/// Result of one update check. `.upToDate` and `.skipped` both
/// mean "don't show a prompt"; the only state that surfaces UI is
/// `.available`.
enum UpdateCheckResult {
    case upToDate
    case available(LatestReleaseInfo)
    case skipped(LatestReleaseInfo)   // user previously hit "Skip this version"
    case fetchFailed(String)
}

enum UpdateChecker {

    /// Manifest URL on the main branch of the public repo. Hard-coded
    /// because there's no point making it configurable — if the repo
    /// ever moves the new app version's binary will ship with the new
    /// URL and old versions will keep checking the old URL (which
    /// would still serve the redirect).
    private static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/joergs-git/AstroSharper/main/latest-release.json"
    )!

    /// UserDefaults key remembering the version the user explicitly
    /// chose to skip. When the manifest's latestVersion equals this
    /// value, the alert stays suppressed. A NEWER version unblocks
    /// the prompt automatically.
    private static let skippedVersionKey = "AstroSharper.updateSkippedVersion"

    static var skippedVersion: String? {
        UserDefaults.standard.string(forKey: skippedVersionKey)
    }

    static func recordSkipped(_ version: String) {
        UserDefaults.standard.set(version, forKey: skippedVersionKey)
    }

    /// One-shot async check. Safe to call from `.onAppear`; throws
    /// nothing — failures fold into `.fetchFailed`. 5 s timeout so
    /// a flaky network can't delay the splash dismissal.
    static func checkForUpdate() async -> UpdateCheckResult {
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .fetchFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return .fetchFailed("HTTP \(http.statusCode) from manifest")
        }

        let info: LatestReleaseInfo
        do {
            info = try JSONDecoder().decode(LatestReleaseInfo.self, from: data)
        } catch {
            return .fetchFailed("Manifest decode failed: \(error.localizedDescription)")
        }

        // Compare against the running version. Semver-style
        // (MAJOR.MINOR.PATCH); compareSemver returns true if
        // `info.latestVersion` is strictly newer than ours.
        guard compareSemver(info.latestVersion, isNewerThan: AppVersion.marketing) else {
            return .upToDate
        }

        // User explicitly skipped this exact version → suppress. A
        // newer manifest entry would unblock again automatically.
        if info.latestVersion == skippedVersion {
            return .skipped(info)
        }

        return .available(info)
    }

    /// True iff `lhs` parses as strictly greater than `rhs` under a
    /// 3-component MAJOR.MINOR.PATCH comparison. Missing components
    /// default to 0; non-numeric components compare as 0 (so e.g.
    /// "0.4.0-beta" parses as 0.4.0).
    static func compareSemver(_ lhs: String, isNewerThan rhs: String) -> Bool {
        func parse(_ s: String) -> (Int, Int, Int) {
            let parts = s.split(separator: ".").map { String($0) }
            func intAt(_ i: Int) -> Int {
                guard i < parts.count else { return 0 }
                // strip non-digit suffix (e.g. "0-beta" → "0")
                let stripped = parts[i].prefix { $0.isNumber }
                return Int(stripped) ?? 0
            }
            return (intAt(0), intAt(1), intAt(2))
        }
        let (a1, b1, c1) = parse(lhs)
        let (a2, b2, c2) = parse(rhs)
        if a1 != a2 { return a1 > a2 }
        if b1 != b2 { return b1 > b2 }
        return c1 > c2
    }
}
