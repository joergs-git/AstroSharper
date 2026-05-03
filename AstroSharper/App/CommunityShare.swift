// Community thumbnail share — opt-out (default ON).
//
// After a successful stack the user is asked once per session
// whether to upload the just-stacked thumbnail to the community
// feed. The bottom-bar community icon controls the global default;
// disabling it suppresses the per-stack prompt entirely.
//
// Privacy contract:
//   - Only a downscaled JPEG thumbnail (max 800 px wide) is uploaded.
//   - machineUUID + target keyword + frameCount + timestamp travel
//     alongside as metadata for the feed listing.
//   - No filename, path, telescope/camera string, or focal length
//     leaves the device.
//   - User can hit "No" on the per-stack prompt OR disable the
//     feature globally via the status-bar icon — both routes
//     suppress upload silently from then on.
//
// The upload itself is a multipart-form POST to the
// `community-thumbnail` Supabase edge function (see
// supabase/functions/community-thumbnail/index.ts). Two parts:
//   * "metadata" — JSON-encoded CommunityShareMetadata
//   * "thumbnail" — JPEG bytes of the just-stacked output, downscaled
//                   to ≤ 800 px on the long edge.
// The edge function caps thumbnail size at 256 KB and rate-limits
// per machineUUID at 10/hour.
//
// Network failure NEVER blocks the user's workflow: URLSession task
// is detached, fire-and-forget, 8 s timeout. Failures are logged via
// NSLog but not retried in v1.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-stack metadata uploaded alongside the thumbnail. Same
/// privacy contract as TelemetryEvent — no identifying fields
/// beyond the random machineUUID.
///
/// Custom `encode(to:)` so optional keys (`target`, `elapsedSec`)
/// always emit as `null` when nil (server validator rejects missing
/// keys with HTTP 400).
struct CommunityShareMetadata: Codable {
    let machineUUID: String
    let target: String?
    let frameCount: Int
    let timestamp: String
    let appVersion: String
    let elapsedSec: Double?

    private enum CodingKeys: String, CodingKey {
        case machineUUID, target, frameCount, timestamp, appVersion, elapsedSec
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machineUUID, forKey: .machineUUID)
        try c.encode(target,      forKey: .target)        // emits null when nil
        try c.encode(frameCount,  forKey: .frameCount)
        try c.encode(timestamp,   forKey: .timestamp)
        try c.encode(appVersion,  forKey: .appVersion)
        try c.encode(elapsedSec,  forKey: .elapsedSec)    // emits null when nil
    }
}

/// One entry in the public community feed. Returned by the
/// `community-feed` edge function as part of `{ entries: [...] }`.
/// `signedUrl` is a 1-hour-TTL pre-signed Supabase storage URL the
/// client fetches directly via AsyncImage — no auth header needed.
struct CommunityFeedEntry: Decodable, Identifiable {
    let id: String
    let machineUuid: String
    let target: String?
    let frameCount: Int?
    let elapsedSec: Double?
    let createdAt: String
    let signedUrl: String

    /// True when this entry came from THIS machine — drives the
    /// "you" badge in the feed window. Comparison is to MachineID's
    /// random per-install UUID so it correctly groups all stacks
    /// from the same install regardless of how many a user uploads.
    var isMine: Bool {
        machineUuid == MachineID.current
    }

    /// Parsed Date from the ISO-8601 string the server returned.
    /// Falls back to .distantPast on a parse failure so feed sort
    /// ordering stays predictable.
    var createdAtDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: createdAt)
            ?? ISO8601DateFormatter().date(from: createdAt)
            ?? .distantPast
    }
}

private struct CommunityFeedResponse: Decodable {
    let entries: [CommunityFeedEntry]
}

enum CommunityShare {
    private static let optOutKey = "AstroSharper.communityOptedOut"

    /// User-controlled opt-out. Default false (community share on).
    /// The status-bar toggle sets / clears this — no app restart.
    static var userDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: optOutKey) }
        set { UserDefaults.standard.set(newValue, forKey: optOutKey) }
    }

    /// Should the per-stack prompt fire after this stack? Returns
    /// false when the global opt-out is set.
    static var shouldPromptAfterStack: Bool { !userDisabled }

    /// Upload the thumbnail + metadata via multipart-form-data POST
    /// to the Supabase `community-thumbnail` edge function. Logs
    /// intent via NSLog regardless (useful when the network call is
    /// gated off via `SupabaseConfig.networkEnabled`).
    /// `elapsedSec` is the wall-clock time the stack took on this
    /// machine — surfaced in the community feed window as a
    /// "duration" column.
    static func upload(
        stackedURL: URL,
        target: String?,
        frameCount: Int,
        elapsedSec: Double?
    ) {
        let metadata = CommunityShareMetadata(
            machineUUID: MachineID.current,
            target: target,
            frameCount: frameCount,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appVersion: AppVersion.shortString,
            elapsedSec: elapsedSec
        )
        guard let metadataData = try? JSONEncoder().encode(metadata),
              let metadataJSON = String(data: metadataData, encoding: .utf8) else {
            return
        }
        NSLog("CommunityShare: upload requested for %@ — metadata=%@",
              stackedURL.lastPathComponent, metadataJSON)

        guard SupabaseConfig.networkEnabled else { return }

        // Downscale the stacked TIFF to a ≤800 px JPEG. The edge
        // function caps at 256 KB; we aim for ~150 KB at quality 0.8.
        guard let jpegData = makeThumbnailJPEG(stackedURL: stackedURL,
                                               maxLongEdge: 800,
                                               quality: 0.8) else {
            NSLog("CommunityShare: could not build thumbnail from %@",
                  stackedURL.lastPathComponent)
            return
        }
        if jpegData.count > 256 * 1024 {
            NSLog("CommunityShare: thumbnail %d bytes exceeds 256KB cap, skipping",
                  jpegData.count)
            return
        }

        // Build the multipart body manually — Foundation has no
        // built-in multipart encoder. Two parts: metadata JSON +
        // thumbnail JPEG.
        let boundary = "AstroSharper-\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n"

        // metadata part
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"metadata\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: application/json\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(metadataJSON.data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)

        // thumbnail part
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"thumbnail\"; filename=\"thumb.jpg\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(jpegData)
        body.append(crlf.data(using: .utf8)!)

        // closing boundary
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

        var request = URLRequest(url: SupabaseConfig.communityThumbnailURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                NSLog("CommunityShare POST failed: %@", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 400 {
                    NSLog("CommunityShare POST returned HTTP %d", http.statusCode)
                } else {
                    NSLog("CommunityShare POST OK (HTTP %d, %d bytes uploaded)",
                          http.statusCode, jpegData.count)
                }
            }
        }.resume()
    }

    /// Downscale + JPEG-encode the stacked TIFF for upload — strictly
    /// no tone manipulation. The community thumbnail must look like
    /// what the user actually saved (whatever bake-in / auto-tone
    /// they chose); injecting our own auto-stretch here was wrong
    /// because it crushed midtones on properly-toned outputs (lunar
    /// surface stacks turned into high-contrast over-processed
    /// "negatives" in the feed — see 2026-05-03 user feedback).
    ///
    /// If the saved TIFF is dark (bare accumulator without bake-in),
    /// the thumbnail will be dark too. That's the truthful preview —
    /// the user can enable Bake-in or Auto-tone in the Lucky Stack
    /// section if they want a brighter saved file (and thus a
    /// brighter community thumbnail).
    private static func makeThumbnailJPEG(
        stackedURL: URL,
        maxLongEdge: Int,
        quality: CGFloat
    ) -> Data? {
        guard let src = CGImageSourceCreateWithURL(stackedURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, thumb, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    // MARK: - Feed read

    enum FeedError: Error, LocalizedError {
        case networkDisabled
        case http(Int, String?)
        case decode(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .networkDisabled:
                return "Telemetry / community share disabled in this build."
            case .http(let code, let body):
                return "Server returned HTTP \(code)\(body.map { " — \($0)" } ?? "")."
            case .decode(let msg):
                return "Could not parse server response: \(msg)"
            case .transport(let msg):
                return "Network error: \(msg)"
            }
        }
    }

    /// Fetches the latest N community thumbnails (server defaults to
    /// 50, max 200; the server also caps at 3 entries per machine_uuid
    /// so one prolific contributor can't dominate). Returns parsed
    /// entries with 1-hour-TTL signed URLs ready to fetch via
    /// AsyncImage.
    static func fetchFeed(limit: Int = 50) async throws -> [CommunityFeedEntry] {
        guard SupabaseConfig.networkEnabled else {
            throw FeedError.networkDisabled
        }

        var components = URLComponents(url: SupabaseConfig.communityFeedURL,
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "app",   value: "astrosharper"),
        ]
        guard let url = components?.url else {
            throw FeedError.transport("Could not build feed URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)",
                         forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FeedError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8)
            throw FeedError.http(http.statusCode, body)
        }

        do {
            let decoded = try JSONDecoder().decode(CommunityFeedResponse.self, from: data)
            return decoded.entries
        } catch {
            throw FeedError.decode(error.localizedDescription)
        }
    }
}
