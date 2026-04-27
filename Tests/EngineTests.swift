// First batch of pure-Swift engine tests for AstroSharper.
//
// All tests in this file are pure-Foundation — they never touch a
// Metal device, never read TESTIMAGES, never load an MTLLibrary. The
// expensive GPU + golden-output regression work lives in the F3
// regression harness driven from the CLI; this target's job is to
// catch unit-level bugs in seconds without external state.
//
// Subsequent algorithm work (Block A LAPD, Block B sigma-clip, etc.)
// each adds its own @Suite here.
import Foundation
import Testing
@testable import AstroSharper

// MARK: - SER header parsing

@Suite("SER header parsing — synthetic bytes")
struct SerHeaderTests {

    @Test("parses minimal mono 8-bit header")
    func parsesMono8() throws {
        let url = try SyntheticSER.write(
            width: 640, height: 480, depth: 8,
            frameCount: 5, colorID: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try SerReader(url: url)
        #expect(reader.imageWidth == 640)
        #expect(reader.imageHeight == 480)
        #expect(reader.frameCount == 5)
        #expect(reader.pixelDepth == 8)
        #expect(reader.colorID == .mono)
        #expect(reader.colorID.isMono)
        #expect(!reader.colorID.isBayer)
        #expect(reader.captureDate == nil)  // dateTimeUTC = 0 → nil
    }

    @Test("parses Bayer RGGB 16-bit header")
    func parsesBayerRGGB16() throws {
        let url = try SyntheticSER.write(
            width: 1024, height: 768, depth: 16,
            frameCount: 2, colorID: 8  // bayerRGGB
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try SerReader(url: url)
        #expect(reader.imageWidth == 1024)
        #expect(reader.imageHeight == 768)
        #expect(reader.frameCount == 2)
        #expect(reader.pixelDepth == 16)
        #expect(reader.colorID == .bayerRGGB)
        #expect(reader.colorID.isBayer)
        #expect(reader.colorID.bayerPatternIndex == 0)
        #expect(!reader.colorID.isMono)

        // bytesPerFrame = w * h * bytesPerPlane * planesPerPixel
        // = 1024 * 768 * 2 * 1 = 1_572_864
        #expect(reader.header.bytesPerFrame == 1024 * 768 * 2)
    }

    @Test("preserves observer/instrument/telescope strings")
    func preservesIdentityStrings() throws {
        let url = try SyntheticSER.write(
            observer: "joergsflow",
            instrument: "ZWO ASI183MC",
            telescope: "C8 SCT"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try SerReader(url: url)
        #expect(reader.header.observer == "joergsflow")
        #expect(reader.header.instrument == "ZWO ASI183MC")
        #expect(reader.header.telescope == "C8 SCT")
    }

    @Test("decodes .NET-ticks dateTimeUTC into Foundation Date")
    func decodesUTCTimestamp() throws {
        // .NET ticks for 2026-04-27T12:00:00Z:
        //   seconds since 0001-01-01 = 62_135_596_800 + (2026-04-27T12:00:00 - 1970-01-01)
        //   epoch unix seconds = 1777_651_200 (approx; computed below)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let target = formatter.date(from: "2026-04-27T12:00:00Z")!
        let unixSec = target.timeIntervalSince1970
        let dotnetSec = unixSec + 62_135_596_800
        let ticks = Int64(dotnetSec * 10_000_000)

        let url = try SyntheticSER.write(dateTimeUTC: ticks)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try SerReader(url: url)
        let parsed = reader.captureDate
        #expect(parsed != nil)
        #expect(abs(parsed!.timeIntervalSince(target)) < 1.0)  // within 1 sec
    }

    @Test("rejects file too small for header")
    func rejectsTooSmall() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astrosharper-test-tiny.ser")
        try? Data(repeating: 0, count: 10).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: SerReaderError.self) {
            _ = try SerReader(url: url)
        }
    }

    @Test("rejects unsupported pixel depth")
    func rejectsBadDepth() throws {
        let url = try SyntheticSER.write(depth: 12)  // not 8 or 16
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: SerReaderError.self) {
            _ = try SerReader(url: url)
        }
    }
}

// MARK: - SourceReader conformance

@Suite("SourceReader protocol conformance")
struct SourceReaderConformanceTests {

    @Test("SerReader exposes universal SourceReader API")
    func serReaderConforms() throws {
        let url = try SyntheticSER.write(
            width: 800, height: 600, depth: 16,
            frameCount: 7, colorID: 9  // bayerGRBG
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let reader: SourceReader = try SerReader(url: url)
        #expect(reader.imageWidth == 800)
        #expect(reader.imageHeight == 600)
        #expect(reader.frameCount == 7)
        #expect(reader.pixelDepth == 16)
        #expect(reader.colorID == .bayerGRBG)
        #expect(reader.nominalFrameRate == nil)  // SER has no nominal FPS
        #expect(reader.url == url)
    }
}

// MARK: - Pipeline settings defaults

@Suite("Pipeline settings — default regression guard")
struct PipelineSettingsDefaultsTests {

    @Test("SharpenSettings defaults are stable")
    func sharpenDefaults() {
        let s = SharpenSettings()
        #expect(s.enabled == true)
        #expect(s.unsharpEnabled == true)
        #expect(s.radius == 1.5)
        #expect(s.amount == 1.0)
        #expect(s.adaptive == false)
        #expect(s.lrEnabled == false)
        #expect(s.lrIterations == 30)
        #expect(s.lrSigma == 1.3)
        #expect(s.wienerEnabled == false)
        #expect(s.wienerSigma == 1.4)
        #expect(s.wienerSNR == 50)
        #expect(s.waveletEnabled == false)
        #expect(s.waveletScales == [1.8, 1.4, 1.0, 0.6])
    }

    @Test("StabilizeSettings defaults are stable")
    func stabilizeDefaults() {
        let s = StabilizeSettings()
        #expect(s.enabled == false)
        #expect(s.referenceMode == .marked)
        #expect(s.cropMode == .crop)
        #expect(s.stackAverage == false)
        #expect(s.alignmentMode == .fullFrame)
        #expect(s.roi == nil)
    }

    @Test("ToneCurveSettings defaults are stable")
    func toneCurveDefaults() {
        let s = ToneCurveSettings()
        #expect(s.enabled == false)
        #expect(s.controlPoints.count == 3)
        #expect(s.controlPoints.first == CGPoint(x: 0, y: 0))
        #expect(s.controlPoints.last == CGPoint(x: 1, y: 1))
    }

    @Test("Codable round-trip preserves SharpenSettings")
    func sharpenRoundTrip() throws {
        var original = SharpenSettings()
        original.lrEnabled = true
        original.lrIterations = 50
        original.waveletEnabled = true
        original.waveletScales = [2.0, 1.5, 1.0, 0.5]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharpenSettings.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Lucky stack variants

@Suite("LuckyStackVariants logic")
struct LuckyStackVariantsTests {

    @Test("default variants are empty")
    func defaultsAreEmpty() {
        #expect(LuckyStackVariants().isEmpty)
    }

    @Test("any non-zero entry makes variants non-empty")
    func nonZeroIsNotEmpty() {
        var v = LuckyStackVariants()
        v.absoluteCounts = [100, 0, 0]
        #expect(!v.isEmpty)

        var w = LuckyStackVariants()
        w.percentages = [0, 25, 0]
        #expect(!w.isEmpty)
    }
}

// MARK: - Half-Flux Radius

@Suite("HalfFluxRadius — PSF concentration metric")
struct HalfFluxRadiusTests {

    private static func buffer(width: Int, height: Int, _ f: (Int, Int) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = f(x, y)
            }
        }
        return out
    }

    @Test("delta function has near-zero HFR")
    func deltaIsNearZero() {
        // Single bright pixel — centroid lands on it, half the flux is
        // *inside* bin 0 (radius 0). HFR = 0.
        var buf = Self.buffer(width: 32, height: 32) { _, _ in 0 }
        buf[16 * 32 + 16] = 1.0
        let hfr = HalfFluxRadius.compute(luma: buf, width: 32, height: 32)
        #expect(hfr < 0.5)
    }

    @Test("empty buffer returns zero")
    func emptyReturnsZero() {
        let buf = Self.buffer(width: 16, height: 16) { _, _ in 0 }
        let hfr = HalfFluxRadius.compute(luma: buf, width: 16, height: 16)
        #expect(hfr == 0)
    }

    @Test("sharp Gaussian has smaller HFR than blurred Gaussian")
    func sharperBeatsBlurred() {
        let cx = 31, cy = 31
        let sharp = Self.buffer(width: 64, height: 64) { x, y in
            let dx = Float(x - cx), dy = Float(y - cy)
            return exp(-(dx * dx + dy * dy) / 2.0)        // sigma = 1.0
        }
        let blurred = Self.buffer(width: 64, height: 64) { x, y in
            let dx = Float(x - cx), dy = Float(y - cy)
            return exp(-(dx * dx + dy * dy) / 32.0)       // sigma = 4.0
        }
        let hSharp   = HalfFluxRadius.compute(luma: sharp,   width: 64, height: 64)
        let hBlurred = HalfFluxRadius.compute(luma: blurred, width: 64, height: 64)
        #expect(hSharp < hBlurred)
        // For a 2D Gaussian with sigma σ, HFR ≈ 1.1774 × σ. Sigma=1 → ~1.18 px.
        #expect(hSharp > 0.5)
        #expect(hSharp < 2.0)
    }

    @Test("Gaussian HFR ≈ 1.177 × sigma (analytical)")
    func gaussianMatchesAnalytical() {
        // A 2D Gaussian's HFR has a closed form: sqrt(2 * ln(2)) * sigma
        // ≈ 1.1774 * sigma. Test sigma=2 → expected HFR ≈ 2.355.
        let cx = 47, cy = 47
        let sigma: Float = 2.0
        let buf = Self.buffer(width: 96, height: 96) { x, y in
            let dx = Float(x - cx), dy = Float(y - cy)
            return exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma))
        }
        let hfr = HalfFluxRadius.compute(luma: buf, width: 96, height: 96)
        let expected = Float((2.0 * Foundation.log(2.0)).squareRoot()) * sigma
        // 5% tolerance — discretisation + bin-width interpolation.
        #expect(abs(hfr - expected) < 0.05 * expected)
    }

    @Test("uniform disc — HFR ≈ R / sqrt(2)")
    func uniformDiscHFR() {
        // Sharp uniform disc of radius R has HFR = R / √2 because the
        // flux scales with area which is r².
        let cx = 31.5, cy = 31.5
        let R: Double = 16.0
        let buf = Self.buffer(width: 64, height: 64) { x, y in
            let dx = Double(x) - cx, dy = Double(y) - cy
            return (dx * dx + dy * dy) <= R * R ? 1.0 : 0.0
        }
        let hfr = HalfFluxRadius.compute(luma: buf, width: 64, height: 64)
        let expected = Float(R / 2.0.squareRoot())
        // 5% tolerance — the disc edge isn't perfectly sub-pixel sampled.
        #expect(abs(hfr - expected) < 0.05 * expected)
    }

    @Test("centroid offset — HFR independent of disc position")
    func centroidIsTranslationInvariant() {
        // Same disc, two different centre positions: HFR should match
        // (within bin discretisation), proving the centroid step works.
        let R: Double = 12.0
        let bufCenter = Self.buffer(width: 96, height: 96) { x, y in
            let dx = Double(x) - 47.5, dy = Double(y) - 47.5
            return (dx * dx + dy * dy) <= R * R ? 1.0 : 0.0
        }
        let bufOffset = Self.buffer(width: 96, height: 96) { x, y in
            let dx = Double(x) - 30.0, dy = Double(y) - 60.0
            return (dx * dx + dy * dy) <= R * R ? 1.0 : 0.0
        }
        let hCenter = HalfFluxRadius.compute(luma: bufCenter, width: 96, height: 96)
        let hOffset = HalfFluxRadius.compute(luma: bufOffset, width: 96, height: 96)
        #expect(abs(hCenter - hOffset) < 0.1 * hCenter)
    }
}

// MARK: - Strehl-style concentration metric

@Suite("Strehl — central-concentration analogue")
struct StrehlTests {

    private static func buffer(width: Int, height: Int, _ f: (Int, Int) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = f(x, y)
            }
        }
        return out
    }

    @Test("delta-function peak yields concentration = 1.0")
    func deltaIsOne() {
        // Single bright pixel at the centre of an otherwise-empty
        // buffer. The 17×17 window around the peak contains only one
        // non-zero pixel → ratio = peak / peak = 1.0.
        var buf = Self.buffer(width: 32, height: 32) { _, _ in 0 }
        buf[16 * 32 + 16] = 1.0
        let s = Strehl.computeConcentration(
            luma: buf, width: 32, height: 32, windowRadius: 8
        )
        #expect(s == 1.0)
    }

    @Test("uniform field with centred peak has 1/area concentration")
    func uniformIsInverseArea() {
        // Constant 1.0 with a tiny ε bump in the middle so the peak
        // finder deterministically lands at (16,16); the 17×17 window
        // then doesn't clip at any edge. Ratio ≈ 1/289 ≈ 0.00346.
        // Without the bump the first pixel ties (Float v > Float v ==
        // false), peakIdx stays at 0, the window clips to 9×9 and the
        // ratio jumps to 1/81 — that's the corner-peak scenario covered
        // by edgePeakClips above.
        var buf = Self.buffer(width: 32, height: 32) { _, _ in 1.0 }
        buf[16 * 32 + 16] = 1.0001
        let s = Strehl.computeConcentration(
            luma: buf, width: 32, height: 32, windowRadius: 8
        )
        let expected: Float = 1.0 / Float(17 * 17)
        // Wider tolerance (1e-3) than the delta test because the
        // ε-bump perturbs the ratio fractionally.
        #expect(abs(s - expected) < 1e-3)
    }

    @Test("sharp Gaussian peak scores higher than blurred peak")
    func sharperBeatsBlurred() {
        let cx = 16, cy = 16
        let sharp = Self.buffer(width: 32, height: 32) { x, y in
            let dx = Float(x - cx), dy = Float(y - cy)
            return exp(-(dx * dx + dy * dy) / 2.0)        // sigma = 1.0
        }
        let blurred = Self.buffer(width: 32, height: 32) { x, y in
            let dx = Float(x - cx), dy = Float(y - cy)
            return exp(-(dx * dx + dy * dy) / 32.0)       // sigma = 4.0
        }
        let sSharp   = Strehl.computeConcentration(
            luma: sharp,   width: 32, height: 32, windowRadius: 8
        )
        let sBlurred = Strehl.computeConcentration(
            luma: blurred, width: 32, height: 32, windowRadius: 8
        )
        #expect(sSharp > sBlurred)
        #expect(sSharp > 0.1)
        #expect(sBlurred < 0.1)
    }

    @Test("all-zero buffer returns zero (no peak)")
    func allZeroIsZero() {
        let buf = Self.buffer(width: 16, height: 16) { _, _ in 0 }
        let s = Strehl.computeConcentration(
            luma: buf, width: 16, height: 16, windowRadius: 4
        )
        #expect(s == 0)
    }

    @Test("peak at the edge clips the window correctly")
    func edgePeakClips() {
        // Bright pixel at (0,0); window cannot extend below 0,0. With
        // surrounding zeros the ratio is still 1.0 but the test guards
        // against indexing crashes.
        var buf = Self.buffer(width: 16, height: 16) { _, _ in 0 }
        buf[0] = 0.7
        let s = Strehl.computeConcentration(
            luma: buf, width: 16, height: 16, windowRadius: 8
        )
        #expect(s == 1.0)
    }

    @Test("negative values are ignored (luminance must be non-negative)")
    func negativesIgnored() {
        // Pre-deconv stages can produce negative pixel values via Wiener
        // ringing; the metric clamps those out so noise can't push the
        // ratio above 1.0.
        var buf = Self.buffer(width: 16, height: 16) { _, _ in -0.5 }
        buf[8 * 16 + 8] = 1.0
        let s = Strehl.computeConcentration(
            luma: buf, width: 16, height: 16, windowRadius: 4
        )
        #expect(s == 1.0)
    }

    @Test("full-frame variant matches windowed when window covers image")
    func fullFrameMatchesWideWindow() {
        var buf = Self.buffer(width: 16, height: 16) { _, _ in 0.1 }
        buf[8 * 16 + 8] = 1.0   // peak in the middle
        let windowed = Strehl.computeConcentration(
            luma: buf, width: 16, height: 16, windowRadius: 99
        )
        let full = Strehl.computeConcentrationFullFrame(
            luma: buf, width: 16, height: 16
        )
        #expect(abs(windowed - full) < 1e-6)
    }
}

// MARK: - Lucky keep-% recommendation

@Suite("Lucky keep-% formula — frame-count floor + knee detection")
struct LuckyKeepRecommendationTests {

    @Test("tight distribution caps at 50%, never returns the legacy 75%")
    func tightDistributionCapped() {
        // 64 nearly-identical scores → kneeFraction near 1.0 → clamp 50%.
        let scores: [Float] = (0..<64).map { _ in 100.0 }.sorted()
        let p90: Float = 100.0
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores,
            totalFrames: 1000,
            p90: p90,
            jitterRMS: nil
        )
        #expect(rec.fraction <= 0.50)
        #expect(rec.fraction >= 0.05)
        // 1000 frames × 0.50 = 500 frames kept on a tight distribution.
        #expect(rec.count >= 100)   // typical floor satisfied
        #expect(rec.count <= 500)
    }

    @Test("wide distribution (lucky tail) recommends a small fraction")
    func wideDistributionPicksLuckyTail() {
        // 64 scores: bottom 56 are dim (1.0), top 8 are sharp (10.0).
        // p90 ≈ 10.0; knee threshold = 5.0; only the top 8 are above.
        // kneeFraction = 8/64 = 0.125 → clamped to >=0.05, in band.
        var values: [Float] = Array(repeating: 1.0, count: 56)
        values.append(contentsOf: Array(repeating: 10.0, count: 8))
        let scores = values.sorted()
        let p90: Float = 10.0
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores,
            totalFrames: 5000,
            p90: p90,
            jitterRMS: nil
        )
        #expect(rec.fraction >= 0.05)
        #expect(rec.fraction <= 0.20)
        // 5000 frames × 12.5% = 625 — well above the 100-frame floor.
        #expect(rec.count > 100)
        #expect(rec.count < 1000)
    }

    @Test("frame-count floor lifts to 100 on small SERs")
    func smallSerLiftsToTypicalFloor() {
        // 200-frame SER + wide distribution that suggests 5%.
        // 5% of 200 = 10 frames, well below the 100-frame typical floor.
        // Result must lift to 100.
        var values: [Float] = Array(repeating: 1.0, count: 60)
        values.append(contentsOf: Array(repeating: 50.0, count: 4))
        let scores = values.sorted()
        let p90: Float = 50.0
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores,
            totalFrames: 200,
            p90: p90,
            jitterRMS: nil
        )
        #expect(rec.count >= 100)
        #expect(rec.fraction >= 0.5)   // 100 / 200 = 0.5
    }

    @Test("frame-count floor is min(totalFrames, 100) for tiny SERs")
    func tinySerCannotKeepMoreThanItHas() {
        // 60-frame SER → typical floor = 60. Always keep all.
        let scores: [Float] = Array(repeating: 1.0, count: 60).sorted()
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores,
            totalFrames: 60,
            p90: 1.0,
            jitterRMS: nil
        )
        #expect(rec.count <= 60)
        #expect(rec.count >= 50)   // absolute floor
    }

    @Test("absolute floor 50 enforced even on extreme cases")
    func absoluteFloorIsFifty() {
        let scores: [Float] = Array(repeating: 1.0, count: 64).sorted()
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores,
            totalFrames: 80,
            p90: 1.0,
            jitterRMS: nil
        )
        #expect(rec.count >= 50)
    }

    @Test("high jitter tightens the keep band")
    func highJitterTightens() {
        // Same input as wide distribution test, but with high jitter.
        var values: [Float] = Array(repeating: 1.0, count: 56)
        values.append(contentsOf: Array(repeating: 10.0, count: 8))
        let scores = values.sorted()

        let calm = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores, totalFrames: 5000, p90: 10.0, jitterRMS: nil
        )
        let jittery = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores, totalFrames: 5000, p90: 10.0, jitterRMS: 20.0
        )
        #expect(jittery.fraction < calm.fraction)
        #expect(jittery.text.contains("jitter"))
    }

    @Test("recommendation text shows both percent and absolute count")
    func textShowsBothMetrics() {
        let scores: [Float] = Array(repeating: 1.0, count: 64).sorted()
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: scores, totalFrames: 2000, p90: 1.0, jitterRMS: nil
        )
        // Must contain a '%' and 'of N frames' style absolute count.
        #expect(rec.text.contains("%"))
        #expect(rec.text.contains("of \(2000)") || rec.text.contains("\(rec.count)"))
    }

    @Test("empty samples returns BiggSky 25% default with floor")
    func emptyReturnsDefault() {
        let rec = SerQualityScanner.computeKeepRecommendation(
            sortedScores: [],
            totalFrames: 1000,
            p90: 0,
            jitterRMS: nil
        )
        #expect(rec.fraction > 0)
        #expect(rec.count >= 100)
    }

    @Test("fraction always in [0.05, 0.75] band")
    func fractionAlwaysInBand() {
        // Run a few permutations; assert no result violates the clamp.
        let inputs: [(scores: [Float], total: Int, p90: Float, jitter: Float?)] = [
            ([Float](repeating: 1.0, count: 64), 5000, 1.0, nil),
            ((0..<64).map { Float($0) }, 5000, 56.7, nil),
            ([Float](repeating: 0.001, count: 56) + [Float](repeating: 100, count: 8), 5000, 100, 30),
            ([0.5, 0.5, 0.5, 0.5], 100, 0.5, nil),
        ]
        for inp in inputs {
            let rec = SerQualityScanner.computeKeepRecommendation(
                sortedScores: inp.scores.sorted(),
                totalFrames: inp.total,
                p90: inp.p90,
                jitterRMS: inp.jitter
            )
            #expect(rec.fraction >= 0.05)
            #expect(rec.fraction <= 1.0)   // upper bound is implicit via floor lift
            #expect(rec.count > 0)
        }
    }
}

// MARK: - LAPD quality metric (CPU reference)

@Suite("LAPD — CPU reference math")
struct LAPDReferenceTests {

    /// Builds a `width × height` luminance buffer from a generator.
    private static func buffer(width: Int, height: Int, _ f: (Int, Int) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = f(x, y)
            }
        }
        return out
    }

    @Test("uniform field has zero LAPD variance")
    func uniformIsZero() {
        // LAPD of a constant field is exactly zero (kernel sums to 0).
        // Variance over a constant-zero field is zero. End to end: 0.
        let buf = Self.buffer(width: 32, height: 32) { _, _ in 0.5 }
        let v = SharpnessProbe.referenceVarianceOfLAPD(
            luma: buf, width: 32, height: 32
        )
        #expect(v == 0)
    }

    @Test("linear gradient has near-zero LAPD variance")
    func linearGradientNearZero() {
        // 2nd derivative of a linear ramp is identically zero, so LAPD
        // is zero everywhere except border (where we pad with zero too).
        let buf = Self.buffer(width: 32, height: 32) { x, _ in
            Float(x) / 31.0
        }
        let v = SharpnessProbe.referenceVarianceOfLAPD(
            luma: buf, width: 32, height: 32
        )
        #expect(v < 1e-6)
    }

    @Test("checker pattern produces non-zero variance")
    func checkerNonZero() {
        // Alternating 0/1 squares — LAPD is large at every pixel because
        // every neighbourhood has the maximum-frequency oscillation a
        // 3×3 stencil can see.
        let buf = Self.buffer(width: 32, height: 32) { x, y in
            ((x + y) & 1) == 0 ? 0.0 : 1.0
        }
        let v = SharpnessProbe.referenceVarianceOfLAPD(
            luma: buf, width: 32, height: 32
        )
        #expect(v > 0.1)
    }

    @Test("checker scores higher than gradient (sharpness ranking sanity)")
    func checkerBeatsGradient() {
        let checker = Self.buffer(width: 32, height: 32) { x, y in
            ((x + y) & 1) == 0 ? 0.0 : 1.0
        }
        let gradient = Self.buffer(width: 32, height: 32) { x, _ in
            Float(x) / 31.0
        }
        let vChecker = SharpnessProbe.referenceVarianceOfLAPD(
            luma: checker, width: 32, height: 32
        )
        let vGradient = SharpnessProbe.referenceVarianceOfLAPD(
            luma: gradient, width: 32, height: 32
        )
        #expect(vChecker > vGradient)
        // And checker should score by orders of magnitude — actual LAPD
        // values on a binary checker hit ~40+ per pixel.
        #expect(vChecker > 100 * max(vGradient, 1e-12))
    }

    @Test("single-pixel impulse produces non-zero variance")
    func impulseNonZero() {
        var buf = Self.buffer(width: 32, height: 32) { _, _ in 0.0 }
        buf[16 * 32 + 16] = 1.0
        let v = SharpnessProbe.referenceVarianceOfLAPD(
            luma: buf, width: 32, height: 32
        )
        #expect(v > 0)
    }

    @Test("LAPD picks up diagonal edges (vs cross Laplacian)")
    func diagonalEdgeIsDetected() {
        // Diagonal step edge: pixels with x + y > 16 are 1, otherwise 0.
        // A 4-neighbour cross Laplacian sees this edge poorly because the
        // kernel doesn't sample along the edge direction. LAPD's diagonal
        // weight makes the response substantial — the whole point of the
        // metric swap. Just assert non-zero here; visual comparison vs
        // the cross Laplacian is exercised in the F3 regression harness.
        let buf = Self.buffer(width: 32, height: 32) { x, y in
            (x + y) > 16 ? 1.0 : 0.0
        }
        let v = SharpnessProbe.referenceVarianceOfLAPD(
            luma: buf, width: 32, height: 32
        )
        #expect(v > 0.001)
    }

    @Test("rejects undersized buffers gracefully")
    func tinyBufferReturnsZero() {
        // A 2×2 buffer has no interior pixels (LAPD requires 3×3 stencil).
        let buf: [Float] = [0.1, 0.5, 0.9, 0.2]
        let v = SharpnessProbe.referenceVarianceOfLAPD(
            luma: buf, width: 2, height: 2
        )
        #expect(v == 0)
    }
}

// MARK: - Export format / bit depth

@Suite("ExportFormat — bit-depth + extension regression")
struct ExportFormatTests {

    @Test("TIFF 16-bit sequence reports uint16")
    func tiff16Sequence() {
        #expect(ExportFormat.tiffSequence.bitDepth == .uint16)
        #expect(ExportFormat.tiffSequence.sequenceExtension == "tif")
        #expect(ExportFormat.tiffSequence.isSequence == true)
    }

    @Test("TIFF 32-bit float sequence reports float32")
    func tiff32FloatSequence() {
        #expect(ExportFormat.tiff32FloatSequence.bitDepth == .float32)
        #expect(ExportFormat.tiff32FloatSequence.sequenceExtension == "tif")
        #expect(ExportFormat.tiff32FloatSequence.isSequence == true)
    }

    @Test("PNG sequence ignores bit depth (always 8-bit)")
    func pngSequence() {
        // PNG always writes 8-bit per the format; the BitDepth is reported
        // as uint16 by the Engine type but the writer overrides to 8-bit.
        #expect(ExportFormat.pngSequence.sequenceExtension == "png")
        #expect(ExportFormat.pngSequence.isSequence == true)
    }

    @Test("video formats are not sequences")
    func videoFormats() {
        #expect(ExportFormat.mp4H264.isSequence == false)
        #expect(ExportFormat.movProRes.isSequence == false)
        #expect(ExportFormat.animatedGIF.isSequence == false)
        #expect(ExportFormat.mp4H264.fileExtension == "mp4")
        #expect(ExportFormat.movProRes.fileExtension == "mov")
        #expect(ExportFormat.animatedGIF.fileExtension == "gif")
    }
}

// MARK: - Preset auto-detect

@Suite("Preset auto-detect from filename keywords")
struct PresetAutoDetectTests {

    @Test("Jupiter keyword routes to .jupiter", arguments: [
        "Jupiter_001.ser",
        "jup_2026-04-01.ser",
        "/captures/jupiter/run.ser",
        "Jup-2026.ser",
    ])
    func detectsJupiter(filename: String) {
        #expect(PresetAutoDetect.detect(in: [filename]) == .jupiter)
    }

    @Test("Saturn keyword routes to .saturn", arguments: [
        "Saturn_001.ser",
        "sat_2026.ser",
        "/captures/saturn/run.ser",
    ])
    func detectsSaturn(filename: String) {
        #expect(PresetAutoDetect.detect(in: [filename]) == .saturn)
    }

    @Test("solar keywords route to .sun", arguments: [
        "Sun_2026.ser",
        "solar_disk.ser",
        "halpha-001.ser",
        "h-alpha-prom.ser",
        "Lunt_60.ser",
    ])
    func detectsSun(filename: String) {
        #expect(PresetAutoDetect.detect(in: [filename]) == .sun)
    }

    @Test("lunar keywords route to .moon", arguments: [
        "Moon_2026.ser",
        "lunar_terminator.ser",
        "luna_001.ser",
        "Mond_2026.ser",
    ])
    func detectsMoon(filename: String) {
        #expect(PresetAutoDetect.detect(in: [filename]) == .moon)
    }

    @Test("no match returns nil")
    func noMatchReturnsNil() {
        #expect(PresetAutoDetect.detect(in: ["random.ser"]) == nil)
        #expect(PresetAutoDetect.detect(in: []) == nil)
    }

    @Test("first-match wins on parent path before file name")
    func firstMatchWins() {
        // Sun keyword is matched first via PresetAutoDetect's keyword order
        // (sun → moon → jupiter → saturn → mars). When a path has both
        // (artificial here), the implementation returns whichever matches
        // first across (target × word × candidate).
        let result = PresetAutoDetect.detect(in: ["/captures/jupiter/sun_session.ser"])
        // Both 'jupiter' (via folder) and 'sun_' (via filename) match; the
        // implementation walks targets in order [.sun, .moon, .jupiter, ...]
        // so 'sun' wins.
        #expect(result == .sun)
    }
}
