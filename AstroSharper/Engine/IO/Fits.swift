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
