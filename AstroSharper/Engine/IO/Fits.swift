// Minimal FITS reader/writer for 2D Float32 images.
//
// FITS is the standard astronomy file format: ASCII headers + big-
// endian binary data, packaged in 2880-byte blocks. Siril, PixInsight,
// AstroPy and every dedicated stacking tool consume it directly.
// AstroSharper's lucky-stack / deconv outputs become useful in those
// pipelines only after a FITS write path lands.
//
// v0 covers the BITPIX = -32 (IEEE single-precision float) variant,
// 2D primary HDU, no extensions, with the canonical required keywords
// (SIMPLE, BITPIX, NAXIS, NAXIS1, NAXIS2, END). Optional user
// metadata gets serialised as additional header cards. Reader
// validates the required keywords and rejects everything else with a
// FitsError so the caller can route to a richer external library if
// ever needed.
//
// Pure-Swift + Foundation. No SPM dependency.
//
// Reference: NASA FITS Standard 4.0
//   https://fits.gsfc.nasa.gov/standard40/fits_standard40aa-le.pdf
import Foundation
import Metal

// MARK: - Public API

/// FITS image payload. Pixels are row-major, top-to-bottom, in host-
/// endian Float32. Metadata keys are uppercase ≤ 8 chars (FITS card
/// keyword constraint); values are stringified per FITS conventions.
struct FitsImage: Equatable {
    let width: Int
    let height: Int
    let pixels: [Float]
    let metadata: [String: String]

    init(width: Int, height: Int, pixels: [Float], metadata: [String: String] = [:]) {
        precondition(pixels.count == width * height, "buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.metadata = metadata
    }
}

enum FitsError: Error, Equatable {
    case fileTooSmall
    case missingKeyword(String)
    case unsupportedBitpix(Int)
    case unsupportedNaxis(Int)
    case invalidDimensions
    case ioError(String)
}

enum FitsWriter {

    /// Serialise a FITS image to disk. Always writes BITPIX = -32
    /// (Float32) regardless of the precision the caller created the
    /// image with — sufficient for downstream pipelines.
    static func write(_ image: FitsImage, to url: URL) throws {
        guard image.width > 0, image.height > 0 else {
            throw FitsError.invalidDimensions
        }

        // Header.
        var cards: [String] = []
        cards.append(card("SIMPLE",  "T",                comment: "Standard FITS"))
        cards.append(card("BITPIX",  "-32",              comment: "IEEE single precision"))
        cards.append(card("NAXIS",   "2",                comment: "2-D image"))
        cards.append(card("NAXIS1",  String(image.width),  comment: "image width"))
        cards.append(card("NAXIS2",  String(image.height), comment: "image height"))
        // Optional user metadata. Keys must be ≤ 8 ASCII chars.
        for (k, v) in image.metadata.sorted(by: { $0.key < $1.key }) {
            let key = sanitiseKey(k)
            cards.append(card(key, v))
        }
        cards.append(endCard())

        var headerBytes = Data()
        for c in cards { headerBytes.append(c.data(using: .ascii)!) }
        // Pad header to 2880-byte block with ASCII spaces.
        let pad = (2880 - (headerBytes.count % 2880)) % 2880
        if pad > 0 {
            headerBytes.append(Data(repeating: 0x20, count: pad))
        }

        // Pixel data: big-endian Float32, row-major, height × width.
        var dataBytes = Data(capacity: image.pixels.count * 4)
        for v in image.pixels {
            let bits = v.bitPattern.bigEndian
            withUnsafeBytes(of: bits) { dataBytes.append(contentsOf: $0) }
        }
        let dataPad = (2880 - (dataBytes.count % 2880)) % 2880
        if dataPad > 0 {
            dataBytes.append(Data(repeating: 0, count: dataPad))
        }

        do {
            try headerBytes.write(to: url, options: .atomic)
            // Append data block. Use a file handle for efficiency on
            // large images (a 4K float TIFF is 64 MB; copying through
            // Data + write is fine but two-step keeps memory bounded).
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: dataBytes)
        } catch {
            throw FitsError.ioError("\(error)")
        }
    }

    // MARK: - Card formatting

    /// Build an 80-byte FITS card. `value` is stringified per FITS:
    /// strings get single quotes, others go through verbatim.
    private static func card(_ keyword: String, _ value: String, comment: String? = nil) -> String {
        let key = padKey(keyword.uppercased())
        let val = formatValue(value)
        var card = "\(key)= \(val)"
        if let c = comment, !c.isEmpty {
            card += " / \(c)"
        }
        return padTo80(card)
    }

    private static func endCard() -> String { padTo80("END") }

    private static func padKey(_ k: String) -> String {
        if k.count >= 8 { return String(k.prefix(8)) }
        return k.padding(toLength: 8, withPad: " ", startingAt: 0)
    }

    /// Right-aligned value field per FITS conventions. Strings are
    /// quoted; numbers and T/F land verbatim.
    private static func formatValue(_ raw: String) -> String {
        let isNumeric = Double(raw) != nil
        let isLogical = raw == "T" || raw == "F"
        let payload: String
        if isNumeric || isLogical {
            payload = raw
        } else {
            // String literal — surround with single quotes; FITS
            // convention pads to ≥ 8 chars between the quotes.
            let inner = raw.padding(toLength: max(8, raw.count), withPad: " ", startingAt: 0)
            payload = "'\(inner)'"
        }
        // Right-align numbers in a 20-character field (col 11–30 of the
        // 80-column card).
        if isNumeric || isLogical {
            return String(repeating: " ", count: max(0, 20 - payload.count)) + payload
        }
        return payload
    }

    private static func padTo80(_ s: String) -> String {
        if s.count >= 80 { return String(s.prefix(80)) }
        return s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    private static func sanitiseKey(_ k: String) -> String {
        let upper = k.uppercased()
        let allowed: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = upper.filter { allowed.contains($0) }
        return String(cleaned.prefix(8))
    }
}

enum FitsReader {

    /// Parse a FITS file from disk. Validates SIMPLE=T, BITPIX=-32,
    /// NAXIS=2, then reads the row-major Float32 pixel data into
    /// host-endian memory.
    static func read(_ url: URL) throws -> FitsImage {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.alwaysMapped])
        } catch {
            throw FitsError.ioError("\(error)")
        }
        guard data.count >= 2880 else { throw FitsError.fileTooSmall }

        // Read header blocks until END.
        var cursor = 0
        var cards: [String: String] = [:]
        var sawEnd = false

        outer: while cursor + 2880 <= data.count {
            for i in 0..<36 {
                let cardStart = cursor + i * 80
                let cardEnd   = cardStart + 80
                guard cardEnd <= data.count else { break outer }
                let cardBytes = data.subdata(in: cardStart..<cardEnd)
                let card = String(data: cardBytes, encoding: .ascii) ?? ""
                if card.hasPrefix("END") {
                    sawEnd = true
                    cursor += 2880
                    break outer
                }
                if let (k, v) = parseCard(card) {
                    cards[k] = v
                }
            }
            cursor += 2880
        }
        guard sawEnd else { throw FitsError.missingKeyword("END") }

        // Validate.
        guard let simple = cards["SIMPLE"], simple == "T" else {
            throw FitsError.missingKeyword("SIMPLE")
        }
        guard let bitpix = (cards["BITPIX"]).flatMap({ Int($0) }) else {
            throw FitsError.missingKeyword("BITPIX")
        }
        guard bitpix == -32 else { throw FitsError.unsupportedBitpix(bitpix) }
        guard let naxis = (cards["NAXIS"]).flatMap({ Int($0) }) else {
            throw FitsError.missingKeyword("NAXIS")
        }
        guard naxis == 2 else { throw FitsError.unsupportedNaxis(naxis) }
        guard let w = (cards["NAXIS1"]).flatMap({ Int($0) }), w > 0 else {
            throw FitsError.missingKeyword("NAXIS1")
        }
        guard let h = (cards["NAXIS2"]).flatMap({ Int($0) }), h > 0 else {
            throw FitsError.missingKeyword("NAXIS2")
        }

        // Read pixel data.
        let pixelByteCount = w * h * 4
        guard cursor + pixelByteCount <= data.count else {
            throw FitsError.fileTooSmall
        }
        var pixels = [Float](repeating: 0, count: w * h)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: cursor)
            for i in 0..<(w * h) {
                let b0 = base.load(fromByteOffset: i * 4 + 0, as: UInt8.self)
                let b1 = base.load(fromByteOffset: i * 4 + 1, as: UInt8.self)
                let b2 = base.load(fromByteOffset: i * 4 + 2, as: UInt8.self)
                let b3 = base.load(fromByteOffset: i * 4 + 3, as: UInt8.self)
                let beBits = (UInt32(b0) << 24) | (UInt32(b1) << 16)
                           | (UInt32(b2) << 8)  | UInt32(b3)
                pixels[i] = Float(bitPattern: beBits)
            }
        }

        // Strip the standard required keys before exposing metadata.
        var metadata = cards
        for required in ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2"] {
            metadata.removeValue(forKey: required)
        }
        return FitsImage(width: w, height: h, pixels: pixels, metadata: metadata)
    }

    /// Lightweight header peek — returns (width, height) without
    /// decoding the pixel buffer. Used by FileCatalog to populate
    /// dimensions in the file row without paying for a full read.
    /// Returns nil if the file isn't a parseable BITPIX=-32 NAXIS=2
    /// FITS — caller falls back to a missing-dimension display.
    static func readDimensions(_ url: URL) -> (Int, Int)? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]),
              data.count >= 2880
        else { return nil }
        var cards: [String: String] = [:]
        outer: for cursor in stride(from: 0, to: data.count, by: 2880) {
            for i in 0..<36 {
                let cardStart = cursor + i * 80
                let cardEnd = cardStart + 80
                guard cardEnd <= data.count else { return nil }
                let cardBytes = data.subdata(in: cardStart..<cardEnd)
                guard let card = String(data: cardBytes, encoding: .ascii) else { return nil }
                if card.hasPrefix("END") { break outer }
                if let (k, v) = parseCard(card) { cards[k] = v }
            }
        }
        guard let w = (cards["NAXIS1"]).flatMap(Int.init),
              let h = (cards["NAXIS2"]).flatMap(Int.init),
              w > 0, h > 0
        else { return nil }
        return (w, h)
    }

    /// Parse a single 80-byte FITS card into (key, value). Returns nil
    /// for HISTORY/COMMENT/blank cards we don't surface in metadata.
    private static func parseCard(_ card: String) -> (String, String)? {
        guard card.count >= 9 else { return nil }
        let keyword = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return nil }
        guard keyword != "HISTORY", keyword != "COMMENT" else { return nil }
        let body = String(card.dropFirst(9))      // skip keyword + "="
        // Strip trailing comment ("/ ...") and whitespace.
        var valuePart = body
        if let slashIdx = body.firstIndex(of: "/") {
            // Leave the slash intact when it's inside a quoted string.
            // Simple heuristic: count quotes before slash; even count
            // means we're outside a string.
            let prefix = body[body.startIndex..<slashIdx]
            let quoteCount = prefix.filter { $0 == "'" }.count
            if quoteCount % 2 == 0 {
                valuePart = String(prefix)
            }
        }
        let trimmed = valuePart.trimmingCharacters(in: .whitespaces)
        // Unquote string values.
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            let inner = trimmed.dropFirst().dropLast()
            return (keyword, String(inner).trimmingCharacters(in: .whitespaces))
        }
        return (keyword, trimmed)
    }
}

// MARK: - SourceReader-compatible wrapper

/// Class wrapper around `FitsReader.read` so FITS files plug into the
/// `SourceReader` protocol uniformly with SER + AVI. v0 supports the
/// 2D primary HDU only (single frame, BITPIX=-32 Float32). The pixel
/// buffer is held in memory for the lifetime of the reader so
/// `loadFrame(at:)` calls don't re-parse the file on every access —
/// FITS files are typically <100 MB so the memory cost is bounded.
final class FitsFrameReader {
    let url: URL
    private let image: FitsImage

    init(url: URL) throws {
        self.url = url
        self.image = try FitsReader.read(url)
    }

    var imageWidth: Int  { image.width }
    var imageHeight: Int { image.height }

    /// 2D primary HDU = single decodable frame. Multi-extension /
    /// data-cube FITS would need a richer model.
    var frameCount: Int  { 1 }

    /// BITPIX=-32 = IEEE single-precision float, the only variant
    /// the v0 reader accepts.
    var pixelDepth: Int  { 32 }

    /// FITS doesn't carry a Bayer pattern in any standardised way at
    /// this layer — we treat the 2D image as monochrome and let the
    /// downstream OSC heuristics route via the file extension instead.
    var colorID: SerColorID { .mono }

    var nominalFrameRate: Double? { nil }

    /// `DATE-OBS` is the FITS standard observation timestamp keyword.
    /// Per the FITS spec the value is interpreted as UTC. Real-world
    /// writers (astropy / SharpCap / PixInsight / Siril) use a few
    /// variants — none consistently — so we try the four most common
    /// shapes and treat all as UTC:
    ///   1. `yyyy-MM-dd'T'HH:mm:ss.SSS` (ISO with fractional seconds, no TZ)
    ///   2. `yyyy-MM-dd'T'HH:mm:ss`     (ISO without fractional seconds)
    ///   3. ISO 8601 with explicit `Z` / offset (Apple's formatter handles)
    ///   4. `yyyy-MM-dd` (date only, older files)
    var captureDate: Date? {
        guard let raw = image.metadata["DATE-OBS"]?
            .trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        let utc = TimeZone(identifier: "UTC")
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = utc
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return d }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    /// Convert the in-memory Float32 pixel buffer to an `rgba16Float`
    /// texture — broadcast mono to RGB, alpha=1. Index is ignored
    /// because FITS v0 is single-frame; callers passing index>0 still
    /// get frame 0 (matches the model that "frameCount=1 means index
    /// 0 is always the only valid frame").
    func loadFrame(at index: Int, device: MTLDevice) throws -> MTLTexture {
        _ = index   // single-frame; index ignored
        let w = image.width
        let h = image.height
        // Float32 → Float16 RGBA broadcast. One pass, no autorelease
        // churn. CPU-only since the buffer's already in memory.
        var rgba = [UInt16](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBufferPointer { dst in
            image.pixels.withUnsafeBufferPointer { src in
                for i in 0..<(w * h) {
                    let v = Float16(src[i])
                    let bits = v.bitPattern
                    let off = i * 4
                    dst[off + 0] = bits
                    dst[off + 1] = bits
                    dst[off + 2] = bits
                    dst[off + 3] = 0x3C00   // Float16 1.0
                }
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        guard let dst = device.makeTexture(descriptor: desc) else {
            throw FitsError.ioError("MTLTexture allocation failed (\(w)×\(h))")
        }

        // Private storage can't be written directly from CPU bytes —
        // stage in a shared texture, blit to the private destination.
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stageDesc) else {
            throw FitsError.ioError("MTLTexture (staging) allocation failed (\(w)×\(h))")
        }
        rgba.withUnsafeBufferPointer { ptr in
            staging.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: w, height: h, depth: 1)),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: w * 4 * MemoryLayout<UInt16>.size
            )
        }

        guard let queue = device.makeCommandQueue(),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder()
        else {
            throw FitsError.ioError("MTLCommandQueue / blit encoder allocation failed")
        }
        blit.copy(from: staging, to: dst)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return dst
    }
}

extension FitsFrameReader: SourceReader {}
