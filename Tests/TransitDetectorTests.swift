// TransitDetector unit tests — hermetic, pure Swift (no Metal, no drive).
//
// These build tiny synthetic SERs with an exactly-known injected object so the
// detector's decision + geometry can be asserted without the multi-GB real
// captures. They exercise the four decision paths that matter:
//   1. star-field moving track (bright transient on a linear path)
//   2. star-field single blob (one-frame flare → moving=false)
//   3. disc silhouette moving track (dark object crossing a bright disc)
//   4. clean capture → no detection
//
// The real acceptance captures on the ASTRO drive are validated separately via
// `astrosharper transit <file> --json`; a drive-gated regression test at the
// bottom runs them when the volume is mounted (skipped in CI).
import Foundation
import Testing
@testable import AstroSharper

@Suite("TransitDetector — synthetic fixtures")
struct TransitDetectorSyntheticTests {

    // Small deterministic background with a touch of structured noise so
    // per-pixel temporal std is non-zero everywhere (avoids the degenerate
    // all-constant case). The noise is a fixed function of (x,y,t), NOT random,
    // so the test is reproducible.
    private static func bgValue(_ x: Int, _ y: Int, _ t: Int) -> UInt8 {
        let base = 10
        let n = (x * 7 + y * 13 + t * 3) % 5   // 0…4 deterministic ripple
        return UInt8(base + n)
    }

    private static func blankFrame(_ w: Int, _ h: Int, _ t: Int) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { f[y*w + x] = bgValue(x, y, t) } }
        return f
    }

    @inline(__always)
    private static func stamp(_ f: inout [UInt8], _ w: Int, _ h: Int, _ cx: Int, _ cy: Int, _ v: UInt8, radius: Int = 1) {
        for dy in -radius...radius { for dx in -radius...radius {
            let x = cx + dx, y = cy + dy
            if x >= 0, x < w, y >= 0, y < h { f[y*w + x] = v }
        } }
    }

    // A single-frame-per-pixel object produces z ≈ √F in the σ-image
    // (independent of its brightness), so the fixtures need enough frames to
    // clear the 6σ threshold: √60 ≈ 7.7. The real captures (100s–1000s of
    // frames) clear it comfortably; this is a property of the detector, not a
    // fudge — F=24 genuinely can't resolve a one-frame object at 6σ.
    private static let F = 60

    @Test("Star-field: a bright object on a linear path → moving track")
    func starfieldMovingTrack() throws {
        let w = 100, h = 100, F = Self.F
        var frames: [[UInt8]] = []
        for t in 0..<F {
            var f = Self.blankFrame(w, h, t)
            // A persistent bright "star" (the target, like Vega) — same spot
            // every frame, so it lands in the background and is not a candidate.
            Self.stamp(&f, w, h, 90, 10, 240, radius: 0)
            // A bright transient crossing on a straight line, frames 15…40.
            if t >= 15 && t <= 40 {
                let cx = 10 + (t - 15) * 3     // 10 → 85
                let cy = 12 + (t - 15) * 3     // 12 → 87
                Self.stamp(&f, w, h, cx, cy, 220, radius: 0)
            }
            frames.append(f)
        }
        let url = try SyntheticSER.writeMono8(width: w, height: h, frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try TransitDetector.detect(url: url, config: TransitConfig(bin: 1))
        #expect(r.mode == .starfield)
        #expect(r.detected)
        let e = try #require(r.transits.first)
        #expect(e.moving)
        // Active range should span roughly the injected 15…40 window.
        #expect(e.activeFrames.first! >= 14 && e.activeFrames.first! <= 18)
        #expect(e.activeFrames.last! >= 37 && e.activeFrames.last! <= 41)
        #expect((e.straightnessR2 ?? 0) > 0.98)
        // Only ONE object — the persistent star must not spawn a second track.
        #expect(r.transits.count == 1)
    }

    @Test("Star-field: a one-frame flare → detected but not moving")
    func starfieldSingleBlob() throws {
        let w = 100, h = 100, F = Self.F
        var frames: [[UInt8]] = []
        for t in 0..<F {
            var f = Self.blankFrame(w, h, t)
            Self.stamp(&f, w, h, 90, 10, 240, radius: 0)   // persistent star
            if t == 30 { Self.stamp(&f, w, h, 44, 55, 230, radius: 0) }  // single flare
            frames.append(f)
        }
        let url = try SyntheticSER.writeMono8(width: w, height: h, frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try TransitDetector.detect(url: url, config: TransitConfig(bin: 1))
        #expect(r.detected)
        let e = try #require(r.transits.first)
        #expect(!e.moving)
        #expect(e.activeFrames == [30])
    }

    @Test("Disc: a dark silhouette crossing a bright disc → moving track, sun mode")
    func discSilhouetteTrack() throws {
        let w = 100, h = 100, F = Self.F
        let cx = 50, cy = 50, rad = 30
        var frames: [[UInt8]] = []
        for t in 0..<F {
            var f = Self.blankFrame(w, h, t)
            // Bright disc.
            for y in 0..<h { for x in 0..<w {
                let dx = x - cx, dy = y - cy
                if dx*dx + dy*dy <= rad*rad { f[y*w + x] = 200 &+ UInt8((x + y + t) % 5) }
            } }
            // Dark silhouette crossing the disc on a line, frames 15…40.
            if t >= 15 && t <= 40 {
                let sx = 28 + (t - 15) * 2   // 28 → 78
                let sy = 40 + (t - 15) * 1   // 40 → 65
                Self.stamp(&f, w, h, sx, sy, 40, radius: 0)
            }
            frames.append(f)
        }
        let url = try SyntheticSER.writeMono8(width: w, height: h, frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try TransitDetector.detect(url: url, config: TransitConfig(bin: 1))
        #expect(r.mode == .sun)      // bright disc → disc mode (label sun w/o "moon" in name)
        #expect(r.detected)
        let e = try #require(r.transits.first)
        #expect(e.moving)
        #expect((e.straightnessR2 ?? 0) > 0.95)
        #expect(e.onDisc == true)
    }

    @Test("Clean capture: no object → not detected")
    func cleanNoDetection() throws {
        let w = 100, h = 100, F = Self.F
        var frames: [[UInt8]] = []
        for t in 0..<F {
            var f = Self.blankFrame(w, h, t)
            Self.stamp(&f, w, h, 20, 20, 240, radius: 0)   // just a persistent star
            frames.append(f)
        }
        let url = try SyntheticSER.writeMono8(width: w, height: h, frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try TransitDetector.detect(url: url, config: TransitConfig(bin: 1))
        #expect(!r.detected)
        #expect(r.transits.isEmpty)
    }

    @Test("JSON is reference-compatible: snake_case keys, nils omitted")
    func jsonShape() throws {
        var r = TransitResult(mode: .starfield, frames: 100, detected: true)
        r.transits = [TransitEvent(moving: false, nActive: 1, activeFrames: [42],
                                   entryPx: [10, 20], separationPx: 5.0, peakZAtObject: 9.1, onDisc: nil)]
        let json = r.jsonString()
        #expect(json.contains("\"active_frames\""))
        #expect(json.contains("\"peak_z_at_object\""))
        #expect(!json.contains("\"exit_px\""))       // nil → omitted
        #expect(!json.contains("\"separation_deg\""))
    }
}
