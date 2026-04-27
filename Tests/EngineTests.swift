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
