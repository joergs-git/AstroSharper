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
    func withFrameBytes<R>(at index: Int, _ body: (UnsafePointer<UInt8>, Int) throws -> R) rethrows -> R {
        precondition(index >= 0 && index < header.frameCount, "frame index out of range")
        let offset = frameDataOffset + index * header.bytesPerFrame
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
            guard let rawBase = raw.baseAddress else {
                preconditionFailure("SerReader: empty memory-mapped buffer for \(url.lastPathComponent)")
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return try body(base.advanced(by: offset), header.bytesPerFrame)
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

        guard let colorID = SerColorID(rawValue: colorIDRaw) else {
            throw SerReaderError.unsupportedFormat("ColorID \(colorIDRaw)")
        }
        guard pixelDepth == 8 || pixelDepth == 16 else {
            throw SerReaderError.unsupportedFormat("pixelDepth \(pixelDepth)")
        }
        guard imageWidth > 0, imageHeight > 0, frameCount > 0 else {
            throw SerReaderError.invalidHeader
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
