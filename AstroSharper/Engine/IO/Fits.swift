// Minimal FITS reader/writer for 2D Float32 images.
//
// FITS is the standard astronomy file format: ASCII headers + big-
// endian binary data, packaged in 2880-byte blocks. Siril, PixInsight,
// AstroPy and every dedicated stacking tool consume it directly.
// AstroSharper's lucky-stack / deconv outputs become useful in those
// pipelines only after a FITS write path lands.
//
// The reader covers every standard BITPIX — 8, 16, 32, 64 integer and
// -32 / -64 float — over a 2D primary HDU with the canonical required
// keywords (SIMPLE, BITPIX, NAXIS, NAXIS1, NAXIS2, END). Integer data is
// scaled through BZERO / BSCALE per the standard, which is how every
// camera writes unsigned 16-bit (BITPIX=16 with BZERO=32768). Optional
// user metadata gets serialised as additional header cards. The writer
// always emits BITPIX = -32.
//
// Integer support matters because it is what smart telescopes actually
// produce: Vaonis Vespera, ZWO Seestar and DwarfLab all write 16-bit
// integer FITS per sub, never float and never video. Before this, those
// files could not be opened at all.
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
    /// BITPIX as declared by the source file, negative for float formats.
    /// A first-class field rather than a metadata entry: `metadata` is the
    /// caller's own keyword bag, and the required structural keywords are
    /// stripped from it. Defaults to the format the writer emits.
    let bitpix: Int

    init(width: Int, height: Int, pixels: [Float],
         metadata: [String: String] = [:], bitpix: Int = -32) {
        precondition(pixels.count == width * height, "buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.metadata = metadata
        self.bitpix = bitpix
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

/// The sample layouts a FITS primary HDU can declare, keyed by BITPIX.
/// FITS integers are big-endian and SIGNED; unsigned data is expressed
/// by pairing them with a BZERO offset.
enum FitsSampleFormat {
    case uint8       // BITPIX  =   8
    case int16       // BITPIX  =  16
    case int32       // BITPIX  =  32
    case int64       // BITPIX  =  64
    case float32     // BITPIX  = -32
    case float64     // BITPIX  = -64

    init?(bitpix: Int) {
        switch bitpix {
        case 8:   self = .uint8
        case 16:  self = .int16
        case 32:  self = .int32
        case 64:  self = .int64
        case -32: self = .float32
        case -64: self = .float64
        default:  return nil
        }
    }

    var byteCount: Int {
        switch self {
        case .uint8:              return 1
        case .int16:              return 2
        case .int32, .float32:    return 4
        case .int64, .float64:    return 8
        }
    }

    /// Divisor that maps physical integer values onto the [0, 1] range
    /// the rest of the pipeline works in.
    ///
    /// This MUST come from the header alone, never from the data. A
    /// per-frame divisor (say, the observed maximum) would scale every
    /// frame of a sequence differently, and stacking frames that no
    /// longer share a brightness scale produces a flickering, wrong
    /// result. Float samples are passed through untouched — those files
    /// are already normalised by whatever wrote them.
    var normalisationDivisor: Float? {
        switch self {
        case .uint8:  return 255
        case .int16:  return 65535
        case .int32:  return Float(Int32.max)
        case .int64:  return Float(Int64.max)
        case .float32, .float64: return nil
        }
    }
}

enum FitsReader {

    /// Decode `count` big-endian samples starting at `offset` into
    /// host-order Float, applying BZERO / BSCALE and then normalising
    /// integer formats into [0, 1].
    ///
    /// Values are clamped to [0, 1] afterwards. Signed integer data
    /// without a BZERO offset can legitimately go negative (a bias-
    /// subtracted frame); clamping is the sane display choice and keeps
    /// the texture upload well-defined.
    private static func decodeSamples(
        data: Data, offset: Int, count: Int,
        format: FitsSampleFormat, bzero: Double, bscale: Double
    ) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let stride = format.byteCount
        let divisor = Double(format.normalisationDivisor ?? 1)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.advanced(by: offset) else { return }

            /// Reassemble a big-endian integer of `stride` bytes. Byte-wise
            /// so unaligned offsets are safe — a FITS data block starts on
            /// a 2880-byte boundary, which is not a multiple of 8.
            func beBits(_ index: Int) -> UInt64 {
                var v: UInt64 = 0
                for b in 0..<stride {
                    v = (v << 8) | UInt64(base.load(fromByteOffset: index * stride + b, as: UInt8.self))
                }
                return v
            }

            for i in 0..<count {
                let stored: Double
                switch format {
                case .uint8:   stored = Double(UInt8(truncatingIfNeeded: beBits(i)))
                case .int16:   stored = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: beBits(i))))
                case .int32:   stored = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: beBits(i))))
                case .int64:   stored = Double(Int64(bitPattern: beBits(i)))
                case .float32: stored = Double(Float(bitPattern: UInt32(truncatingIfNeeded: beBits(i))))
                case .float64: stored = Double(bitPattern: beBits(i))
                }
                let physical = bzero + bscale * stored
                guard format.normalisationDivisor != nil else {
                    // Float sample: pass through exactly as before, with
                    // no clamp. These files carry whatever range their
                    // writer chose and existing behaviour depends on it.
                    out[i] = Float(physical)
                    continue
                }
                out[i] = Float(Swift.min(1.0, Swift.max(0.0, physical / divisor)))
            }
        }
        return out
    }

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
        guard let sampleFormat = FitsSampleFormat(bitpix: bitpix) else {
            throw FitsError.unsupportedBitpix(bitpix)
        }
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

        // BZERO / BSCALE convert stored integers to physical values:
        //   physical = BZERO + BSCALE × stored
        // This is how unsigned 16-bit is represented in a format whose
        // integers are signed — BITPIX=16 with BZERO=32768 is what every
        // astronomy camera writes. Defaults are the identity transform.
        let bzero = (cards["BZERO"]).flatMap { Double($0) } ?? 0
        let bscale = (cards["BSCALE"]).flatMap { Double($0) } ?? 1

        let pixelByteCount = w * h * sampleFormat.byteCount
        guard cursor + pixelByteCount <= data.count else {
            throw FitsError.fileTooSmall
        }
        let pixels = decodeSamples(
            data: data, offset: cursor, count: w * h,
            format: sampleFormat, bzero: bzero, bscale: bscale
        )

        // Strip the structural keywords before exposing metadata — they are
        // represented by the struct's own fields, not by the caller's
        // keyword bag.
        var metadata = cards
        for required in ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2"] {
            metadata.removeValue(forKey: required)
        }
        return FitsImage(width: w, height: h, pixels: pixels, metadata: metadata, bitpix: bitpix)
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

    /// BITPIX exactly as the header declares it — negative for float
    /// formats. Surfaced for diagnostics; `pixelDepth` is the unsigned
    /// bit count the `SourceReader` protocol asks for.
    var bitpix: Int { image.bitpix }

    /// Bits per sample. Reported unsigned — a BITPIX of -32 is 32 bits
    /// of float, not "minus 32 bits".
    var pixelDepth: Int { abs(bitpix) }

    /// Colour layout from the `BAYERPAT` keyword, which every camera that
    /// writes CFA data sets (ZWO / SharpCap / N.I.N.A. / Siril all agree
    /// on the name and the four-letter values). Absent keyword = mono,
    /// which is both the old behaviour and the right answer for a
    /// monochrome or already-debayered frame.
    ///
    /// This is what lets a smart-telescope raw sub go straight into
    /// AstroSharper: without it the CFA mosaic would stack as grey.
    var colorID: SerColorID { Self.bayerPattern(from: image.metadata) ?? .mono }

    /// Map a FITS `BAYERPAT` value onto our colour enum. FITS stores it
    /// as a quoted string; `parseCard` has already stripped the quotes.
    static func bayerPattern(from metadata: [String: String]) -> SerColorID? {
        guard let raw = metadata["BAYERPAT"]?
            .trimmingCharacters(in: .whitespaces)
            .uppercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "RGGB": return .bayerRGGB
        case "GRBG": return .bayerGRBG
        case "GBRG": return .bayerGBRG
        case "BGGR": return .bayerBGGR
        default:     return nil
        }
    }

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

    /// Demosaic a CFA frame on the GPU with the shared Bayer kernel.
    /// The normalised [0,1] floats are quantised back to 16-bit and
    /// staged in an `r16Uint` texture, exactly the layout the kernel
    /// expects from a 16-bit Bayer SER, so both formats reach the same
    /// code path and the same output.
    private func demosaicToTexture(pattern: SerColorID, device: MTLDevice) throws -> MTLTexture {
        let w = image.width, h = image.height
        guard let library = MetalDevice.shared.library,
              let fn = library.makeFunction(name: "unpack_bayer16_to_rgba"),
              let pso = try? device.makeComputePipelineState(function: fn) else {
            throw FitsError.ioError("Bayer demosaic kernel unavailable")
        }

        var samples = [UInt16](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            samples[i] = UInt16(max(0, min(65535, (image.pixels[i] * 65535).rounded())))
        }

        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: w, height: h, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead]
        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        dstDesc.storageMode = .private
        dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let staging = device.makeTexture(descriptor: stageDesc),
              let dst = device.makeTexture(descriptor: dstDesc) else {
            throw FitsError.ioError("MTLTexture allocation failed (\(w)×\(h))")
        }
        samples.withUnsafeBufferPointer { ptr in
            staging.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: w, height: h, depth: 1)),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: w * MemoryLayout<UInt16>.size
            )
        }

        guard let queue = device.makeCommandQueue(),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw FitsError.ioError("Metal command encoding failed")
        }
        enc.setComputePipelineState(pso)
        // Mirrors BayerUnpackParams in Shaders.metal: (scale, flip, pattern).
        var params: (Float, UInt32, UInt32) = (1.0 / 65535.0, 0, pattern.bayerPatternIndex)
        enc.setBytes(&params, length: MemoryLayout<(Float, UInt32, UInt32)>.stride, index: 0)
        enc.setTexture(staging, index: 0)
        enc.setTexture(dst, index: 1)
        let tgw = pso.threadExecutionWidth
        let tgh = max(1, pso.maxTotalThreadsPerThreadgroup / tgw)
        enc.dispatchThreadgroups(
            MTLSize(width: (w + tgw - 1) / tgw, height: (h + tgh - 1) / tgh, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgw, height: tgh, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return dst
    }

    /// Convert the in-memory Float32 pixel buffer to an `rgba16Float`
    /// texture — broadcast mono to RGB, alpha=1. Index is ignored
    /// because FITS is single-frame here; callers passing index>0 still
    /// get frame 0 (matches the model that "frameCount=1 means index
    /// 0 is always the only valid frame").
    func loadFrame(at index: Int, device: MTLDevice) throws -> MTLTexture {
        _ = index   // single-frame; index ignored
        let w = image.width
        let h = image.height

        // CFA data goes through the same GPU demosaic the SER path uses.
        // Quantising the normalised floats back to 16-bit to feed the
        // existing `unpack_bayer16_to_rgba` kernel costs nothing real —
        // the source was 16-bit integer to begin with — and avoids a
        // second, divergent demosaic implementation.
        if let pattern = Self.bayerPattern(from: image.metadata) {
            return try demosaicToTexture(pattern: pattern, device: device)
        }
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
