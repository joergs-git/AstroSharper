// Animated PNG (APNG) export — a lossless 24-bit alternative to GIF
// that any modern browser, forum and image viewer renders as a plain
// `<img>` tag (no video player needed). Compared to GIF:
//   - 24-bit RGB instead of 256-colour palette → no banding on noisy
//     planetary footage, no posterised Mond surfaces
//   - Lossless DEFLATE compression instead of LZW
//   - Same `<img>` embed semantics → drop-in upgrade for AstroBin / CN
//     / Discord / Discourse posts where MP4 would need a player
//
// Format reference: PNG 1.2 + APNG extension (Mozilla, fully supported
// in libpng / browsers since the late 2010s). Structurally APNG is
// just a regular PNG file with a few extra chunks slotted in:
//
//   PNG signature  (8 bytes)
//   IHDR           — width, height, bit depth, colour type
//   acTL           — animation header (num_frames, num_plays)
//   fcTL #0        — frame 0 metadata (delay, dispose, blend)
//   IDAT           — frame 0 pixel data (= default static image)
//   fcTL #1
//   fdAT           — frame 1 pixel data (same payload as IDAT but
//                    prefixed with a sequence number)
//   …
//   IEND
//
// `seq_num` is global across fcTL + fdAT chunks: starts at 0 with
// fcTL #0 and increments by 1 for each subsequent fcTL / fdAT.
//
// macOS has no built-in APNG encoder so we DIY. The heavy bit is
// turning a frame's RGBA scanlines into a zlib stream that PNG
// decoders accept:
//   raw scanline bytes → prepend filter-type byte per row → DEFLATE
//   the lot → prepend the 2-byte zlib header (0x78 0x9C) → append
//   the 4-byte Adler32 of the *unfiltered* scanline buffer. Apple's
//   `compression_encode_buffer` with COMPRESSION_ZLIB gives us raw
//   DEFLATE; we add the wrapper bytes ourselves.
//
// Filter type 0 (None) for every scanline keeps the encoder ~150 LOC.
// Adaptive filtering would compress better but adds another ~80 LOC
// of per-row trial / comparison; can revisit if file sizes hurt.
//
// Bit depth is fixed at 8-bit RGBA. 16-bit APNG IS valid and lossless
// for the bake-in 16-bit path, but doubles file size and browser
// support is fine but not universal-universal. Default to 8-bit; if
// the user asks for 16-bit later, flip IHDR + double the scanline
// stride.
import Foundation
import Compression
import CoreGraphics

enum ApngWriter {
    enum WriteError: LocalizedError {
        case openFailed(String)
        case writeFailed(String)
        case emptyRange
        case noPixels
        case compressionFailed

        var errorDescription: String? {
            switch self {
            case .openFailed(let s):  return "APNG open failed: \(s)"
            case .writeFailed(let s): return "APNG write failed: \(s)"
            case .emptyRange:         return "Frame range is empty."
            case .noPixels:           return "No pixel data after crop / decode."
            case .compressionFailed:  return "zlib compression failed."
            }
        }
    }

    /// Write the picked frames as an Animated PNG at `fps` playback
    /// rate. `bakeIn`-nil falls back to the same CPU demosaic GifWriter
    /// uses so behaviour matches what users already expect from the
    /// existing GIF path.
    static func write(
        source: URL,
        output: URL,
        frameRange: ClosedRange<Int>,
        targetFrameCount: Int,
        fps: Int,
        crop: CGRect?,
        bakeIn: BakeInExporter.Options? = nil,
        frameStride: Int = 1,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard !frameRange.isEmpty else { throw WriteError.emptyRange }
        let reader = try SerReader(url: source)
        let h = reader.header
        let srcW = h.imageWidth
        let srcH = h.imageHeight

        // Crop snapping — mirror SerWriter / GifWriter / Mp4Writer.
        var cx = 0, cy = 0, cw = srcW, ch_ = srcH
        if let c = crop {
            cx = Int(c.origin.x.rounded())
            cy = Int(c.origin.y.rounded())
            cw = Int(c.width.rounded())
            ch_ = Int(c.height.rounded())
            if h.colorID.isBayer {
                cx &= ~1; cy &= ~1
                if cw & 1 != 0 { cw -= 1 }
                if ch_ & 1 != 0 { ch_ -= 1 }
            }
            cx = max(0, min(srcW - 1, cx))
            cy = max(0, min(srcH - 1, cy))
            cw = max(2, min(srcW - cx, cw))
            ch_ = max(2, min(srcH - cy, ch_))
        }

        // Stride + target frame picking (identical to GifWriter so the
        // user gets the same frame timeline as the GIF would produce).
        let frameStart = max(0, min(frameRange.lowerBound, h.frameCount - 1))
        let frameEnd   = max(frameStart, min(frameRange.upperBound, h.frameCount - 1))
        let stride = max(1, frameStride)
        let stridedCandidates: [Int] = Swift.stride(
            from: frameStart, through: frameEnd, by: stride
        ).map { $0 }
        let totalAvail = stridedCandidates.count
        guard totalAvail > 0 else { throw WriteError.emptyRange }
        let outCount = max(1, min(targetFrameCount, totalAvail))

        var pickedIndices: [Int] = []
        pickedIndices.reserveCapacity(outCount)
        if outCount == 1 {
            pickedIndices.append(stridedCandidates[0])
        } else {
            for i in 0..<outCount {
                let t = Double(i) / Double(outCount - 1)
                let pos = Int((t * Double(totalAvail - 1)).rounded())
                pickedIndices.append(stridedCandidates[pos])
            }
        }

        // Resolve output dimensions BEFORE writing IHDR — bake-in's
        // resize/rotate can change w/h. Decode frame 0 upfront and reuse
        // its data as the IDAT payload below.
        let bakeCtx: BakeInExporter.Context? = bakeIn.map {
            BakeInExporter.Context(options: $0)
        }
        let firstCrop: CGRect? = (cx == 0 && cy == 0 && cw == srcW && ch_ == srcH)
            ? nil
            : CGRect(x: cx, y: cy, width: cw, height: ch_)

        let isBayer = h.colorID.isBayer
        let mono16 = !isBayer && h.bytesPerPlane == 2 && !h.colorID.isRGB

        var outW = cw
        var outH = ch_
        let firstFrameRGBA: Data
        if let ctx = bakeCtx {
            let frame = try ctx.processedFrame(
                sourceURL: source,
                frameIndex: pickedIndices[0],
                crop: firstCrop
            )
            outW = frame.width
            outH = frame.height
            firstFrameRGBA = frame.data
        } else {
            guard reader.canReadFrame(at: pickedIndices[0]) else {
                throw WriteError.writeFailed("Source frame \(pickedIndices[0]) not readable.")
            }
            var buf = [UInt8](repeating: 0, count: cw * ch_ * 4)
            reader.withFrameBytes(at: pickedIndices[0]) { ptr, _ in
                fillRGBA(ptr: ptr, srcW: srcW, srcH: srcH,
                         cx: cx, cy: cy, cw: cw, ch: ch_,
                         isBayer: isBayer, mono16: mono16,
                         colorID: h.colorID, rgba: &buf)
            }
            firstFrameRGBA = Data(buf)
        }
        guard outW > 0, outH > 0 else { throw WriteError.noPixels }

        // Open output. Truncate any prior file at the path.
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: nil)
        guard let fh = try? FileHandle(forWritingTo: output) else {
            throw WriteError.openFailed("FileHandle on \(output.path)")
        }
        defer { try? fh.close() }

        // PNG signature.
        try fh.write(contentsOf: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        // IHDR — 13 bytes.
        var ihdr = Data(capacity: 13)
        ihdr.append(uint32BE(UInt32(outW)))
        ihdr.append(uint32BE(UInt32(outH)))
        ihdr.append(8)   // bit_depth = 8
        ihdr.append(6)   // colour_type = truecolour + alpha (RGBA)
        ihdr.append(0)   // compression_method = 0 (DEFLATE — only option)
        ihdr.append(0)   // filter_method      = 0
        ihdr.append(0)   // interlace_method   = 0 (none)
        try writeChunk(fh: fh, type: "IHDR", data: ihdr)

        // acTL — animation control. num_plays = 0 → loop forever.
        var actl = Data(capacity: 8)
        actl.append(uint32BE(UInt32(outCount)))
        actl.append(uint32BE(0))
        try writeChunk(fh: fh, type: "acTL", data: actl)

        // First frame: fcTL + IDAT.
        var seq: UInt32 = 0
        try writeFcTL(fh: fh, seq: seq, width: outW, height: outH, fps: fps)
        seq += 1
        let firstZlib = try zlibWrap(filteredScanlines(rgba: firstFrameRGBA,
                                                       width: outW, height: outH))
        try writeChunk(fh: fh, type: "IDAT", data: firstZlib)
        progress?(1.0 / Double(outCount))

        // Subsequent frames: fcTL + fdAT.
        for i in 1..<outCount {
            let frameRGBA: Data
            if let ctx = bakeCtx {
                let frame = try ctx.processedFrame(
                    sourceURL: source,
                    frameIndex: pickedIndices[i],
                    crop: firstCrop
                )
                // Dimension stability check — bake-in shouldn't change
                // size mid-run (options are frozen on the Context), but
                // skip anomalous frames rather than write a corrupt PNG.
                guard frame.width == outW, frame.height == outH else { continue }
                frameRGBA = frame.data
            } else {
                guard reader.canReadFrame(at: pickedIndices[i]) else { continue }
                var buf = [UInt8](repeating: 0, count: outW * outH * 4)
                reader.withFrameBytes(at: pickedIndices[i]) { ptr, _ in
                    fillRGBA(ptr: ptr, srcW: srcW, srcH: srcH,
                             cx: cx, cy: cy, cw: outW, ch: outH,
                             isBayer: isBayer, mono16: mono16,
                             colorID: h.colorID, rgba: &buf)
                }
                frameRGBA = Data(buf)
            }

            try writeFcTL(fh: fh, seq: seq, width: outW, height: outH, fps: fps)
            seq += 1

            let zlib = try zlibWrap(filteredScanlines(rgba: frameRGBA,
                                                      width: outW, height: outH))
            // fdAT payload = 4-byte sequence number + zlib stream.
            var fdat = Data(capacity: 4 + zlib.count)
            fdat.append(uint32BE(seq))
            seq += 1
            fdat.append(zlib)
            try writeChunk(fh: fh, type: "fdAT", data: fdat)

            if i % 4 == 0 || i == outCount - 1 {
                progress?(Double(i + 1) / Double(outCount))
            }
        }

        // IEND — empty payload.
        try writeChunk(fh: fh, type: "IEND", data: Data())
    }

    // MARK: - APNG chunk helpers

    /// `delay_num / delay_den` seconds between frames. With delay_num=1
    /// and delay_den=fps we get a clean 1/fps interval, which all APNG
    /// players honour exactly.
    private static func writeFcTL(fh: FileHandle,
                                  seq: UInt32,
                                  width: Int,
                                  height: Int,
                                  fps: Int) throws {
        var data = Data(capacity: 26)
        data.append(uint32BE(seq))
        data.append(uint32BE(UInt32(width)))
        data.append(uint32BE(UInt32(height)))
        data.append(uint32BE(0))   // x_offset
        data.append(uint32BE(0))   // y_offset
        data.append(uint16BE(1))                                       // delay_num
        data.append(uint16BE(UInt16(min(max(1, fps), 65535))))         // delay_den
        data.append(0)             // dispose_op = APNG_DISPOSE_OP_NONE
        data.append(0)             // blend_op   = APNG_BLEND_OP_SOURCE
        try writeChunk(fh: fh, type: "fcTL", data: data)
    }

    /// Standard PNG chunk: 4-byte length, 4-byte ASCII type, payload,
    /// 4-byte CRC32 of (type || payload).
    private static func writeChunk(fh: FileHandle, type: String, data: Data) throws {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4, "PNG chunk type must be 4 ASCII bytes")
        var out = Data(capacity: 12 + data.count)
        out.append(uint32BE(UInt32(data.count)))
        out.append(contentsOf: typeBytes)
        out.append(data)
        var crcInput = Data(capacity: 4 + data.count)
        crcInput.append(contentsOf: typeBytes)
        crcInput.append(data)
        out.append(uint32BE(crc32(crcInput)))
        try fh.write(contentsOf: out)
    }

    // MARK: - Filtered scanlines + zlib wrap

    /// Prepend the per-scanline filter-type byte (0 = None) to each row.
    /// Result is exactly what PNG decoders expect inside an IDAT/fdAT
    /// zlib stream.
    private static func filteredScanlines(rgba: Data,
                                          width: Int,
                                          height: Int) -> Data {
        let stride = width * 4
        var out = Data(capacity: height * (1 + stride))
        rgba.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var rowBuf = [UInt8](repeating: 0, count: 1 + stride)
            for y in 0..<height {
                rowBuf[0] = 0   // filter type None
                memcpy(&rowBuf[1], base.advanced(by: y * stride), stride)
                out.append(contentsOf: rowBuf)
            }
        }
        return out
    }

    /// Wrap raw DEFLATE output into a zlib stream: 2-byte header
    /// (0x78 0x9C = 32K window, default level) + DEFLATE + 4-byte
    /// Adler32 of the original (unfiltered? — no, of the input to the
    /// DEFLATE step, which IS our filtered-scanlines blob).
    private static func zlibWrap(_ src: Data) throws -> Data {
        let deflated = try rawDeflate(src)
        let adler = adler32(src)
        var out = Data(capacity: 2 + deflated.count + 4)
        out.append(0x78)
        out.append(0x9C)
        out.append(deflated)
        out.append(uint32BE(adler))
        return out
    }

    /// Apple's `COMPRESSION_ZLIB` produces RAW DEFLATE (no zlib header
    /// / no Adler32 trailer) despite the name — verified against
    /// `compression.h` docs. We add the wrapper bytes in `zlibWrap`.
    private static func rawDeflate(_ src: Data) throws -> Data {
        let bufSize = max(64, src.count + 1024)
        var dst = [UInt8](repeating: 0, count: bufSize)
        let written = src.withUnsafeBytes { srcRaw -> Int in
            guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &dst, bufSize,
                srcPtr, src.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { throw WriteError.compressionFailed }
        return Data(dst.prefix(written))
    }

    // MARK: - CRC32 (PNG / ISO 3309, polynomial 0xEDB88320)

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<data.count {
                let idx = Int((c ^ UInt32(p[i])) & 0xFF)
                c = crcTable[idx] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFFFFFF
    }

    // MARK: - Adler32 (zlib stream trailer)

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let MOD: UInt32 = 65521
        data.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<data.count {
                a = (a + UInt32(p[i])) % MOD
                b = (b + a) % MOD
            }
        }
        return (b << 16) | a
    }

    // MARK: - Big-endian writers

    private static func uint32BE(_ v: UInt32) -> Data {
        var n = v.bigEndian
        return withUnsafeBytes(of: &n) { Data($0) }
    }

    private static func uint16BE(_ v: UInt16) -> Data {
        var n = v.bigEndian
        return withUnsafeBytes(of: &n) { Data($0) }
    }

    // MARK: - Raw SER bytes → RGBA8 (mirrors GifWriter.fillRGBA so the
    // non-bake-in path looks identical between the two formats).

    private static func fillRGBA(
        ptr: UnsafePointer<UInt8>,
        srcW: Int, srcH: Int,
        cx: Int, cy: Int, cw: Int, ch: Int,
        isBayer: Bool, mono16: Bool,
        colorID: SerColorID,
        rgba: inout [UInt8]
    ) {
        let bayerOff: (rx: Int, ry: Int) = {
            switch colorID {
            case .bayerRGGB: return (0, 0)
            case .bayerGRBG: return (1, 0)
            case .bayerGBRG: return (0, 1)
            case .bayerBGGR: return (1, 1)
            default:         return (0, 0)
            }
        }()
        func sample8(_ x: Int, _ y: Int) -> UInt8 {
            let xi = min(srcW - 1, max(0, x))
            let yi = min(srcH - 1, max(0, y))
            let idx = yi * srcW + xi
            if mono16 {
                let p16 = ptr.advanced(by: idx * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
                return UInt8(min(UInt32(p16) >> 8, 255))
            }
            return ptr[idx]
        }
        for y in 0..<ch {
            let sy = cy + y
            for x in 0..<cw {
                let sx = cx + x
                let outIdx = (y * cw + x) * 4
                if isBayer {
                    let tx = sx - (sx & 1)
                    let ty = sy - (sy & 1)
                    let r  = sample8(tx + bayerOff.rx,         ty + bayerOff.ry)
                    let b  = sample8(tx + (1 - bayerOff.rx),   ty + (1 - bayerOff.ry))
                    let g1 = sample8(tx + (1 - bayerOff.rx),   ty + bayerOff.ry)
                    let g2 = sample8(tx + bayerOff.rx,         ty + (1 - bayerOff.ry))
                    let g  = UInt8((Int(g1) + Int(g2)) >> 1)
                    rgba[outIdx + 0] = r
                    rgba[outIdx + 1] = g
                    rgba[outIdx + 2] = b
                } else {
                    let v = sample8(sx, sy)
                    rgba[outIdx + 0] = v
                    rgba[outIdx + 1] = v
                    rgba[outIdx + 2] = v
                }
                rgba[outIdx + 3] = 255
            }
        }
    }
}
