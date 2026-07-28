// SER (Solar/Lunar/Planetary video) format reader.
//
// SER is the de-facto raw-video container in planetary astrophotography
// (SharpCap, FireCapture, AutoStakkert workflow). 178-byte header + tightly
// packed frames + optional UTC timestamp trailer.
//
// We memory-map the file so 5000-frame, multi-GB SERs cost nothing extra in
// RAM — the OS pages frame data on demand. Every frame access yields a raw
// pointer into the mapped region; the upload kernel takes it from there.
//
// >4 GB SER safety (F.2 audit, 2026-04-29): all offset arithmetic uses
// Swift `Int`, which is 64-bit on Apple Silicon (every supported Mac).
// `Data(.alwaysMapped)` on Darwin wraps real `mmap`, which supports
// multi-GB files on 64-bit. Empirically validated against
// `TESTIMAGES/biggsky/mond-00_06_53_.ser` (12 GB lunar SER). Per-frame
// offset = `178 + index * bytesPerFrame`, computed in Int64 even for
// adversarial `index * bytesPerFrame` products. The boundary check in
// `withFrameBytes` traps cleanly if a truncated / corrupt file is
// memory-mapped but lacks the bytes the header claims.
//
// Reference: http://www.grischa-hahn.homepage.t-online.de/astro/ser/
import Foundation

/// SER `ColorID` values, exactly as defined by the SER v3 specification.
///
/// The values matter for interop and are easy to get wrong: RGB is **100**
/// and BGR is **101**, NOT 16 / 17. Codes 16–19 are the CMY Bayer variants
/// (`BAYER_CYYM`, `BAYER_YCMY`, `BAYER_YMCY`, `BAYER_MYYC`) from an era of
/// complementary-colour sensors that no current planetary camera uses; we
/// deliberately do not model them, so they fall through to the frame-size
/// inference below and are rejected with a clear message if that can't
/// resolve them either.
///
/// History (2026-07-28): this enum previously used 16 / 17 for RGB / BGR and
/// carried a `mapExtendedColorID` table that folded 100 onto `.mono`. Both
/// were wrong. The consequence was visible: a Siril-written RGB24 SER
/// (ColorID 100) was read as 8-bit mono, so `bytesPerFrame` came out three
/// times too small and every displayed frame was one third of a real frame
/// interpreted as luminance — flat, grey, with a 3-pixel line pattern. On
/// the write side we stamped 16 into our own bake-in exports, which every
/// spec-conformant reader (Siril, PIPP, AutoStakkert) decodes as CMY Bayer.
enum SerColorID: Int32 {
    case mono       = 0
    case bayerRGGB  = 8
    case bayerGRBG  = 9
    case bayerGBRG  = 10
    case bayerBGGR  = 11
    case rgb        = 100
    case bgr        = 101

    var isBayer: Bool {
        switch self {
        case .bayerRGGB, .bayerGRBG, .bayerGBRG, .bayerBGGR: return true
        default: return false
        }
    }
    var isMono: Bool { self == .mono }
    var isRGB: Bool { self == .rgb || self == .bgr }

    /// Pattern index expected by the Metal `unpack_bayer*` kernels:
    /// 0 = RGGB, 1 = GRBG, 2 = GBRG, 3 = BGGR. Mono returns 0 (unused).
    var bayerPatternIndex: UInt32 {
        switch self {
        case .bayerRGGB: return 0
        case .bayerGRBG: return 1
        case .bayerGBRG: return 2
        case .bayerBGGR: return 3
        default:         return 0
        }
    }
}

struct SerHeader {
    let fileID: String          // "LUCAM-RECORDER"
    let luID: Int32
    let colorID: SerColorID
    /// The ColorID exactly as written in the file, before any resolution.
    /// Kept for diagnostics — `astrosharper analyze` prints it next to the
    /// resolved value so a mismatch is immediately visible.
    let rawColorID: Int32
    /// True when `colorID` could not be taken from the header and had to be
    /// derived from the frame-size arithmetic instead. A non-conformant
    /// writer, worth reporting.
    let colorIDWasInferred: Bool
    /// The header's `LittleEndian` field. ADVISORY ONLY — real-world writers
    /// disagree about its polarity, so nothing in the decode path reads it.
    /// The authority for 16-bit sample order is
    /// `SerReader.pixelDataIsLittleEndian`, which probes the actual data.
    let isLittleEndian: Bool
    let imageWidth: Int
    let imageHeight: Int
    let pixelDepthPerPlane: Int  // 8 or 16
    let frameCount: Int
    let observer: String
    let instrument: String
    let telescope: String
    let dateTime: Int64           // recording start (.NET ticks)
    let dateTimeUTC: Int64

    var bytesPerPlane: Int { pixelDepthPerPlane > 8 ? 2 : 1 }
    var planesPerPixel: Int { colorID.isRGB ? 3 : 1 }
    var bytesPerFrame: Int { imageWidth * imageHeight * bytesPerPlane * planesPerPixel }

    /// Convert .NET ticks (DateTimeUTC field) to a Foundation Date.
    /// .NET ticks are 100-nanosecond intervals since 0001-01-01 UTC.
    var dateUTC: Date? {
        guard dateTimeUTC > 0 else { return nil }
        let secondsBetweenDotNetEpochAndUnixEpoch: TimeInterval = 62_135_596_800
        let secondsSinceDotNetEpoch = TimeInterval(dateTimeUTC) / 10_000_000.0
        let unixSeconds = secondsSinceDotNetEpoch - secondsBetweenDotNetEpochAndUnixEpoch
        return Date(timeIntervalSince1970: unixSeconds)
    }
}

enum SerReaderError: Error {
    case cannotOpen(URL)
    case tooSmall
    case invalidHeader
    case unsupportedFormat(String)
}

final class SerReader {
    let url: URL
    let header: SerHeader

    /// Byte order of the 16-bit pixel samples, decided by looking at the
    /// PIXELS rather than at the header's `LittleEndian` field.
    ///
    /// The header flag is unusable in practice: the spec and the installed
    /// base of capture tools disagree about its polarity, so both `0` and
    /// `1` occur on files whose samples are plainly little-endian. Every
    /// real-world writer emits little-endian, which is also what Apple
    /// Silicon reads natively, so that stays the default — this probe only
    /// exists to CATCH the byte-swapped case rather than render it as noise.
    /// Always `true` for 8-bit sources, where byte order is meaningless.
    let pixelDataIsLittleEndian: Bool

    private let data: Data           // memory-mapped, kept alive
    private let frameDataOffset: Int = 178

    init(url: URL) throws {
        self.url = url

        // Memory-map (read-only). On macOS this is real mmap with no RAM cost
        // beyond the pages we touch.
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped, .uncached]) else {
            throw SerReaderError.cannotOpen(url)
        }
        self.data = data

        guard data.count >= 178 else { throw SerReaderError.tooSmall }
        self.header = try Self.parseHeader(data)
        guard header.bytesPerFrame > 0 else { throw SerReaderError.invalidHeader }
        self.pixelDataIsLittleEndian = Self.probePixelByteOrder(
            data: data, header: header, frameDataOffset: 178
        )

        // Diagnostic: if the OS mapped fewer bytes than the file really
        // has, large-file frame access silently runs short — surfaces as
        // a "dead zone" of frozen frames near the end of a multi-GB SER.
        // Log it so the cause (header overcount vs mmap truncation) is
        // distinguishable.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let realSize = (attrs[.size] as? NSNumber)?.intValue,
           realSize != data.count {
            NSLog("SerReader: mapped %d bytes but file is %d on disk (%@) — frame access clamped to mapped size",
                  data.count, realSize, url.lastPathComponent)
        }
    }

    /// Frames actually present in the mapped data. Clamps a header
    /// `frameCount` that overstates a truncated / aborted capture (or a
    /// short mmap) so callers — scrub UI, quality scan, lucky-stack frame
    /// loop — never index into bytes that aren't there (which would
    /// freeze the scrubber or trip `withFrameBytes`'s precondition).
    /// Equals `header.frameCount` for a complete file.
    var readableFrameCount: Int {
        let avail = data.count - frameDataOffset
        guard avail > 0, header.bytesPerFrame > 0 else { return 0 }
        return Swift.min(header.frameCount, avail / header.bytesPerFrame)
    }

    // MARK: - Frame access

    /// Returns a raw byte pointer to frame `index` valid for the lifetime of
    /// the reader. The buffer length is `header.bytesPerFrame`.
    ///
    /// Boundary guard catches truncated / corrupt files where the mapped
    /// data is shorter than the header claims (e.g. a SER copy interrupted
    /// mid-transfer). Without this check we'd return a pointer into invalid
    /// memory. >4 GB SERs are fine — see file-level `>4 GB SER safety` note.
    /// True when frame `index` is fully present in the mapped data.
    /// Guards against a header `frameCount` that overstates a truncated
    /// or still-being-written file (common with live captures + the
    /// folder-watch auto-stack path). Cheap — no read, just offset math.
    /// Speculative callers (playback prefetch / manual scrub) MUST check
    /// this before `withFrameBytes` so a short file fails soft instead of
    /// tripping the hard `precondition` and crashing the whole app —
    /// `precondition` is fatal and not catchable by the loaders' `try?`.
    func canReadFrame(at index: Int) -> Bool {
        guard index >= 0, index < header.frameCount else { return false }
        let bpf = header.bytesPerFrame
        let offset = frameDataOffset + index * bpf
        return offset >= 0 && offset + bpf <= data.count
    }

    /// Derived capture FPS from the SER's optional per-frame timestamp
    /// trailer. Returns nil if the trailer is absent (most capture
    /// tools do populate it — FireCapture, SharpCap, ASIStudio — but
    /// some don't) or if it's degenerate (single frame, zero span).
    ///
    /// SER timestamp trailer layout: at offset `178 + N × bytesPerFrame`
    /// there are N × Int64 .NET ticks (100 ns) values, little-endian.
    /// fps = (N - 1) / ((last - first) / 10^7 seconds).
    var capturedFPS: Double? {
        let n = readableFrameCount
        guard n >= 2 else { return nil }
        let trailerStart = frameDataOffset + n * header.bytesPerFrame
        let trailerSize = n * MemoryLayout<Int64>.size
        guard data.count >= trailerStart + trailerSize else { return nil }
        let firstTs = readInt64LE(at: trailerStart)
        let lastTs = readInt64LE(at: trailerStart + (n - 1) * MemoryLayout<Int64>.size)
        guard lastTs > firstTs else { return nil }
        let ticksPerSecond: Double = 10_000_000  // .NET 100 ns ticks
        let seconds = Double(lastTs - firstTs) / ticksPerSecond
        guard seconds > 0 else { return nil }
        let fps = Double(n - 1) / seconds
        // Sanity-clamp to plausible astrophotography rates. A bogus
        // trailer (zero-filled, wrong endianness, …) shouldn't drive
        // a nonsense UI number.
        guard fps.isFinite, fps >= 0.5, fps <= 1000 else { return nil }
        return fps
    }

    /// Read a little-endian Int64 from the mapped data at `offset`.
    private func readInt64LE(at offset: Int) -> Int64 {
        return data.withUnsafeBytes { raw -> Int64 in
            guard let base = raw.baseAddress else { return 0 }
            let p = base.advanced(by: offset)
            // Unaligned load — Apple Silicon allows it but go through
            // a byte-wise reassembly to stay strictly conformant.
            var v: Int64 = 0
            for i in 0..<8 {
                let byte = p.advanced(by: i).load(as: UInt8.self)
                v |= Int64(byte) << (i * 8)
            }
            return v
        }
    }

    func withFrameBytes<R>(at index: Int, _ body: (UnsafePointer<UInt8>, Int) throws -> R) rethrows -> R {
        precondition(index >= 0 && index < header.frameCount, "frame index out of range")
        let bpf = header.bytesPerFrame
        let offset = frameDataOffset + index * bpf
        precondition(offset + bpf <= data.count,
                     "SER file truncated at frame \(index): need \(offset + bpf) bytes, have \(data.count)")
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
            // Guard the baseAddress force-unwrap — an empty mmap (zero-
            // byte file slipped past the header validation, or a file
            // that vanished after open) would otherwise hard-crash here
            // with a useless trap. preconditionFailure surfaces the
            // file name so the failure is debuggable.
            guard let rawBase = raw.baseAddress else {
                preconditionFailure("SerReader: empty memory-mapped buffer for \(url.lastPathComponent)")
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return try body(base.advanced(by: offset), bpf)
        }
    }

    // MARK: - Byte-order probe

    /// Decide the byte order of 16-bit samples from the data itself.
    ///
    /// Method: an image row is locally smooth — neighbouring samples differ
    /// by a little. Swapping the two bytes of every sample turns the low
    /// byte into the high byte, so neighbouring differences explode by
    /// roughly two orders of magnitude. Comparing the mean absolute
    /// neighbour difference under both interpretations therefore separates
    /// the two cases by a wide margin, and we only overturn the
    /// little-endian default when the margin is unmistakable (4×).
    ///
    /// Cost: one row of one frame — a few kilobytes paged in, so this is
    /// safe to run at `init` even for the file-list's dimension probe over
    /// a folder of multi-GB captures.
    private static func probePixelByteOrder(
        data: Data, header: SerHeader, frameDataOffset: Int
    ) -> Bool {
        // 8-bit samples have no byte order to get wrong.
        guard header.bytesPerPlane == 2 else { return true }
        guard header.imageHeight > 0, header.imageWidth > 0 else { return true }
        // Frame 0 must be fully mapped before we read into it.
        guard frameDataOffset + header.bytesPerFrame <= data.count else { return true }

        let samplesPerRow = header.imageWidth * header.planesPerPixel
        guard samplesPerRow >= 2 else { return true }
        // Middle row — avoids the black borders and any leading padding a
        // capture tool might leave at the top of the frame.
        let row = header.imageHeight / 2
        let rowStart = frameDataOffset + row * samplesPerRow * 2
        let pairs = Swift.min(2048, samplesPerRow - 1)
        guard rowStart + (pairs + 1) * 2 <= data.count else { return true }

        var littleEnergy: Double = 0
        var bigEnergy: Double = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var previousLE = 0, previousBE = 0
            for i in 0...pairs {
                // Unaligned-safe byte-wise load; the row offset has no
                // alignment guarantee.
                let lo = Int(base.advanced(by: rowStart + i * 2).load(as: UInt8.self))
                let hi = Int(base.advanced(by: rowStart + i * 2 + 1).load(as: UInt8.self))
                let asLE = lo | (hi << 8)
                let asBE = hi | (lo << 8)
                if i > 0 {
                    littleEnergy += Double(abs(asLE - previousLE))
                    bigEnergy += Double(abs(asBE - previousBE))
                }
                previousLE = asLE
                previousBE = asBE
            }
        }

        // Only call it big-endian when the little-endian reading is
        // dramatically rougher. A flat / black row leaves both at zero and
        // keeps the default.
        let isLittle = !(bigEnergy > 0 && littleEnergy > bigEnergy * 4)
        if !isLittle {
            NSLog("SerReader: 16-bit samples look byte-swapped (neighbour roughness LE %.0f vs BE %.0f) — file is not little-endian",
                  littleEnergy, bigEnergy)
        }
        return isLittle
    }

    // MARK: - Header parsing

    private static func parseHeader(_ data: Data) throws -> SerHeader {
        let raw = (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: 178)

        let fileID = String(bytes: data.prefix(14), encoding: .ascii) ?? ""
        let luID = readInt32(raw, offset: 14)
        let colorIDRaw = readInt32(raw, offset: 18)
        let endianRaw = readInt32(raw, offset: 22)
        let imageWidth = Int(readInt32(raw, offset: 26))
        let imageHeight = Int(readInt32(raw, offset: 30))
        let pixelDepth = Int(readInt32(raw, offset: 34))
        let frameCount = Int(readInt32(raw, offset: 38))
        let observer = readString(raw, offset: 42, length: 40)
        let instrument = readString(raw, offset: 82, length: 40)
        let telescope = readString(raw, offset: 122, length: 40)
        let dateTime = readInt64(raw, offset: 162)
        let dateTimeUTC = readInt64(raw, offset: 170)

        guard pixelDepth == 8 || pixelDepth == 16 else {
            throw SerReaderError.unsupportedFormat("pixelDepth \(pixelDepth)")
        }
        guard imageWidth > 0, imageHeight > 0, frameCount > 0 else {
            throw SerReaderError.invalidHeader
        }

        // Resolve the colour ID. Documented spec values are 0 (mono),
        // 8/9/10/11 (RGB Bayer), 16..19 (CMY Bayer — unsupported), 100 (RGB)
        // and 101 (BGR). Strategy:
        //   1. Take the raw value if it is one of the layouts we model.
        //   2. Otherwise infer from frame-size math (file size − header /
        //      frame count / pixels = bytes per pixel; 1 = mono, 2 = mono16,
        //      3 = RGB24, 6 = RGB48). Only commit when the math is clean and
        //      unambiguous.
        // Step 2 covers two real cases: capture tools that write a value
        // outside the spec, and AstroSharper's own pre-0.7.0 bake-in exports,
        // which stamped 16 (really BAYER_CYYM) for what is actually RGB.
        //
        // There is deliberately NO "+100 dialect" table here. An earlier
        // version had one, which folded the spec's RGB code (100) onto mono
        // and broke every RGB24 SER written by a conformant tool.
        let colorID: SerColorID
        let wasInferred: Bool
        if let standard = SerColorID(rawValue: colorIDRaw) {
            colorID = standard
            wasInferred = false
        } else {
            let inferred = inferColorIDFromFrameSize(
                totalBytes: data.count,
                frameCount: frameCount,
                pixels: imageWidth * imageHeight,
                pixelDepth: pixelDepth
            )
            // The CMY Bayer codes are real spec values we can't demosaic. A
            // CMY frame is one sample per pixel, so the byte math cannot
            // tell it apart from mono — accepting the mono guess would show
            // a mosaic as greyscale and call it success. Only let inference
            // override these codes when it says packed RGB, which is the
            // signature of our own pre-0.7.0 exports rather than a real CMY
            // sensor.
            let isCMYCode = (16...19).contains(colorIDRaw)
            if let inferred, !isCMYCode || inferred.isRGB {
                colorID = inferred
                wasInferred = true
            } else {
                throw SerReaderError.unsupportedFormat(describeUnknownColorID(colorIDRaw))
            }
        }

        return SerHeader(
            fileID: fileID,
            luID: luID,
            colorID: colorID,
            rawColorID: colorIDRaw,
            colorIDWasInferred: wasInferred,
            isLittleEndian: endianRaw == 0,  // advisory only — see field doc
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            pixelDepthPerPlane: pixelDepth,
            frameCount: frameCount,
            observer: observer,
            instrument: instrument,
            telescope: telescope,
            dateTime: dateTime,
            dateTimeUTC: dateTimeUTC
        )
    }

    /// Build the error text for a ColorID we can neither map nor infer.
    /// Names the CMY Bayer codes explicitly — a user hitting one deserves
    /// to know their file is a valid-but-exotic SER rather than corrupt.
    private static func describeUnknownColorID(_ raw: Int32) -> String {
        switch raw {
        case 16: return "ColorID 16 (BAYER_CYYM) — CMY-Bayer sensors are not supported"
        case 17: return "ColorID 17 (BAYER_YCMY) — CMY-Bayer sensors are not supported"
        case 18: return "ColorID 18 (BAYER_YMCY) — CMY-Bayer sensors are not supported"
        case 19: return "ColorID 19 (BAYER_MYYC) — CMY-Bayer sensors are not supported"
        default: return "ColorID \(raw)"
        }
    }

    /// Last-resort inference from frame byte count. Useful when capture
    /// tools write a ColorID that doesn't appear in the spec, and for
    /// AstroSharper's own pre-0.7.0 bake-in exports (ColorID 16 with
    /// 6 bytes per pixel is unambiguously RGB48, not CMY Bayer).
    /// Returns nil when the math doesn't cleanly point at a single
    /// interpretation — better to fail with a clear error than to mis-
    /// categorise the data and produce visually-broken output.
    private static func inferColorIDFromFrameSize(
        totalBytes: Int,
        frameCount: Int,
        pixels: Int,
        pixelDepth: Int
    ) -> SerColorID? {
        guard frameCount > 0, pixels > 0 else { return nil }
        let dataBytes = totalBytes - 178   // strip header
        guard dataBytes > 0 else { return nil }
        let perFrame = dataBytes / frameCount
        // Allow up to 1% padding tolerance — some capture tools pad to
        // power-of-two row strides or sector boundaries.
        let bpp8: Int  = pixels * 1
        let bpp16: Int = pixels * 2
        let bppRGB: Int  = pixels * 3
        let bppRGB16: Int = pixels * 6
        let tol = max(64, perFrame / 100)   // ≥64-byte tolerance
        func close(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= tol }
        // 16-bit cases are tried first so an 8-bit ambiguity doesn't
        // win when pixelDepth is 16.
        if pixelDepth == 16 {
            if close(perFrame, bpp16) { return .mono }
            if close(perFrame, bppRGB16) { return .rgb }
        } else {
            if close(perFrame, bpp8) { return .mono }
            if close(perFrame, bppRGB) { return .rgb }
        }
        return nil
    }

    private static func readInt32(_ p: UnsafePointer<UInt8>, offset: Int) -> Int32 {
        var v: Int32 = 0
        memcpy(&v, p.advanced(by: offset), 4)
        return v.littleEndian
    }
    private static func readInt64(_ p: UnsafePointer<UInt8>, offset: Int) -> Int64 {
        var v: Int64 = 0
        memcpy(&v, p.advanced(by: offset), 8)
        return v.littleEndian
    }
    private static func readString(_ p: UnsafePointer<UInt8>, offset: Int, length: Int) -> String {
        let buf = UnsafeBufferPointer(start: p.advanced(by: offset), count: length)
        // Trim trailing zero/whitespace bytes.
        let bytes = Array(buf).prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
