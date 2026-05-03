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

enum SerColorID: Int32 {
    case mono       = 0
    case bayerRGGB  = 8
    case bayerGRBG  = 9
    case bayerGBRG  = 10
    case bayerBGGR  = 11
    case rgb        = 16
    case bgr        = 17

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
    }

    // MARK: - Frame access

    /// Returns a raw byte pointer to frame `index` valid for the lifetime of
    /// the reader. The buffer length is `header.bytesPerFrame`.
    ///
    /// Boundary guard catches truncated / corrupt files where the mapped
    /// data is shorter than the header claims (e.g. a SER copy interrupted
    /// mid-transfer). Without this check we'd return a pointer into invalid
    /// memory. >4 GB SERs are fine — see file-level `>4 GB SER safety` note.
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

        // Resolve the colour ID. Spec values are 0/8/9/10/11/16/17. Capture
        // tools in the wild (SharpCap variants, FireCapture custom builds)
        // sometimes write non-standard values. Strategy:
        //   1. Try the raw value against the standard enum.
        //   2. If unknown, try the SharpCap-style "+100" extended forms.
        //   3. As a last resort, infer from frame-size math (file size −
        //      header / frame count / pixels = bytes per pixel; 1=mono,
        //      3=RGB, 6=RGB16). Only commit to this when the math is
        //      clean and unambiguous.
        // This handles the real-world ColorID 101 case (an ASI662MC file
        // captured by a tool that uses the +100 dialect for Bayer/RGB).
        let colorID: SerColorID
        if let standard = SerColorID(rawValue: colorIDRaw) {
            colorID = standard
        } else if let extended = mapExtendedColorID(colorIDRaw) {
            colorID = extended
        } else if let inferred = inferColorIDFromFrameSize(
            totalBytes: data.count,
            frameCount: frameCount,
            pixels: imageWidth * imageHeight,
            pixelDepth: pixelDepth
        ) {
            colorID = inferred
        } else {
            throw SerReaderError.unsupportedFormat("ColorID \(colorIDRaw)")
        }

        return SerHeader(
            fileID: fileID,
            luID: luID,
            colorID: colorID,
            isLittleEndian: endianRaw == 0,  // SER convention: 0 = LE
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

    /// SharpCap / FireCapture sometimes write `100 + standardColorID`. The
    /// extra 100 is undocumented in the canonical SER spec but well-known
    /// in the planetary capture community. Convert if the offset value
    /// matches a known pattern.
    private static func mapExtendedColorID(_ raw: Int32) -> SerColorID? {
        switch raw {
        case 100:  return .mono        // 100 + 0
        case 108:  return .bayerRGGB   // 100 + 8
        case 109:  return .bayerGRBG   // 100 + 9
        case 110:  return .bayerGBRG   // 100 + 10
        case 111:  return .bayerBGGR   // 100 + 11
        case 116:  return .rgb         // 100 + 16
        case 117:  return .bgr         // 100 + 17
        default:   return nil
        }
    }

    /// Last-resort inference from frame byte count. Useful when capture
    /// tools write a ColorID that doesn't appear in any documented dialect
    /// (e.g. the user-reported ColorID=101 case where the file's
    /// 3-bytes-per-pixel math definitively identifies it as RGB24).
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
