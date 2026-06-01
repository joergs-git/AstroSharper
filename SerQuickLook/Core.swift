// Standalone SER decoder + auto-stretch + bilinear debayer for the
// AstroSharper QuickLook thumbnail and preview extensions.
//
// IMPORTANT: this file is intentionally self-contained and does NOT
// import the host AstroSharper module. macOS QuickLook extensions run
// in a sandboxed XPC process with no access to the host app's binary
// or types — so we replicate just enough of the SerReader header parse,
// debayer, and percentile-stretch logic to render one representative
// frame as a CGImage.
//
// Format reference (mirrors AstroSharper's Engine/IO/SerReader.swift):
//   - 178-byte header, fields little-endian
//   - colorID:   0 = mono, 8..11 = Bayer (RGGB/GRBG/GBRG/BGGR),
//                16 = RGB,   17 = BGR
//   - depth:     8 or 16 bits per plane (16-bit pixels are LE uint16)
//   - frame N starts at offset 178 + N * (W * H * bytesPerSample * planes)
//
// All output is 8-bit sRGB premultiplied RGBA; that is what QuickLook
// will display in Finder and the spacebar Preview panel.

import Foundation
import CoreGraphics

enum SerQL {

    // MARK: - Public entry point

    /// Decode a representative frame of the SER file at `url`, apply a
    /// 1%/99.5% percentile auto-stretch, downsample to fit in
    /// `maxDimension` on the long edge, and return an 8-bit sRGB CGImage.
    ///
    /// We pick the middle frame because the first few frames of a typical
    /// planetary capture are often focus / calibration / "still settling"
    /// frames — the middle of the run gives the most representative look.
    ///
    /// Returns `nil` on any decode failure; the QuickLook host then falls
    /// back to the generic file icon, which is the safest failure mode.
    static func renderRepresentativeFrame(url: URL,
                                          maxDimension: Int = 1024) -> CGImage? {
        guard let header = readHeader(url: url) else { return nil }
        let frameIndex = max(0, header.frameCount / 2)
        guard let raw = readFrame(url: url, header: header, index: frameIndex) else { return nil }
        let rgb8 = convertToRGB8(raw: raw, header: header)
        guard !rgb8.isEmpty else { return nil }
        let stretched = autoStretchRGB8ToRGBA(rgb8: rgb8,
                                              width: header.width,
                                              height: header.height)
        let (pixels, outW, outH) = downsampleRGBA(stretched,
                                                  width: header.width,
                                                  height: header.height,
                                                  maxDim: maxDimension)
        return makeCGImage(rgba8: pixels, width: outW, height: outH)
    }

    // MARK: - Header parse

    struct Header {
        var width: Int
        var height: Int
        /// 8 or 16 — bits per sample plane.
        var depth: Int
        /// Normalised colorID (SharpCap dialect offset of +100 stripped).
        var colorID: Int
        var frameCount: Int

        var bytesPerSample: Int { depth > 8 ? 2 : 1 }
        /// 3 for interleaved RGB / BGR, 1 for everything else (mono + Bayer).
        var samplesPerPixel: Int {
            switch colorID { case 16, 17: return 3; default: return 1 }
        }
        var bytesPerFrame: Int { width * height * bytesPerSample * samplesPerPixel }
        var isBayer: Bool { (8...11).contains(colorID) }
        /// Bayer pattern index matching AstroSharper's convention:
        /// 0=RGGB, 1=GRBG, 2=GBRG, 3=BGGR.
        var bayerIndex: Int { colorID - 8 }
    }

    static func readHeader(url: URL) -> Header? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 178), data.count == 178 else { return nil }
        let magic = String(data: data.subdata(in: 0..<14), encoding: .ascii) ?? ""
        guard magic.hasPrefix("LUCAM-RECORDER") else { return nil }
        // SharpCap stores some colorIDs as raw + 100 to mark its dialect.
        // We strip that offset so 108 → 8, 116 → 16, etc.
        let colorID = Int(readI32LE(data, at: 18)) % 100
        let width   = Int(readI32LE(data, at: 26))
        let height  = Int(readI32LE(data, at: 30))
        let depth   = Int(readI32LE(data, at: 34))
        let frames  = Int(readI32LE(data, at: 38))
        guard width > 0, height > 0, frames > 0,
              depth == 8 || depth == 16 else { return nil }
        return Header(width: width, height: height, depth: depth,
                      colorID: colorID, frameCount: frames)
    }

    private static func readFrame(url: URL, header: Header, index: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let offset = UInt64(178 + index * header.bytesPerFrame)
        do { try fh.seek(toOffset: offset) } catch { return nil }
        guard let data = try? fh.read(upToCount: header.bytesPerFrame),
              data.count == header.bytesPerFrame else { return nil }
        return data
    }

    // MARK: - Raw → 8-bit RGB

    /// Convert the raw frame bytes into an 8-bit interleaved RGB array
    /// (3 bytes per pixel). 16-bit samples are truncated to their high
    /// byte (`>> 8`), matching the existing engine convention for fast
    /// preview rendering.
    static func convertToRGB8(raw: Data, header: Header) -> [UInt8] {
        let count = header.width * header.height
        var rgb = [UInt8](repeating: 0, count: count * 3)

        raw.withUnsafeBytes { rawBuf in
            switch (header.depth, header.colorID) {

            case (8, 0): // Mono 8
                let p = rawBuf.bindMemory(to: UInt8.self)
                for i in 0..<count {
                    let v = p[i]
                    rgb[3*i] = v; rgb[3*i+1] = v; rgb[3*i+2] = v
                }

            case (16, 0): // Mono 16 LE
                let p = rawBuf.bindMemory(to: UInt16.self)
                for i in 0..<count {
                    let v = UInt8(p[i] >> 8)
                    rgb[3*i] = v; rgb[3*i+1] = v; rgb[3*i+2] = v
                }

            case (8, 16): // RGB 8
                let p = rawBuf.bindMemory(to: UInt8.self)
                for i in 0..<count {
                    rgb[3*i]   = p[3*i]
                    rgb[3*i+1] = p[3*i+1]
                    rgb[3*i+2] = p[3*i+2]
                }

            case (16, 16): // RGB 16 LE
                let p = rawBuf.bindMemory(to: UInt16.self)
                for i in 0..<count {
                    rgb[3*i]   = UInt8(p[3*i]   >> 8)
                    rgb[3*i+1] = UInt8(p[3*i+1] >> 8)
                    rgb[3*i+2] = UInt8(p[3*i+2] >> 8)
                }

            case (8, 17): // BGR 8 — swap R/B
                let p = rawBuf.bindMemory(to: UInt8.self)
                for i in 0..<count {
                    rgb[3*i]   = p[3*i+2]
                    rgb[3*i+1] = p[3*i+1]
                    rgb[3*i+2] = p[3*i]
                }

            case (16, 17): // BGR 16 LE — swap R/B
                let p = rawBuf.bindMemory(to: UInt16.self)
                for i in 0..<count {
                    rgb[3*i]   = UInt8(p[3*i+2] >> 8)
                    rgb[3*i+1] = UInt8(p[3*i+1] >> 8)
                    rgb[3*i+2] = UInt8(p[3*i]   >> 8)
                }

            case (_, 8), (_, 9), (_, 10), (_, 11): // Bayer (depth 8 or 16)
                let mono = monoFromBayerRaw(buf: rawBuf,
                                            depth: header.depth,
                                            count: count)
                rgb = debayerBilinear(mono: mono,
                                      width: header.width,
                                      height: header.height,
                                      pattern: header.bayerIndex)

            default:
                // Unknown colorID → leave zeros; QuickLook gets nil from
                // the empty-stretch branch and shows the generic icon.
                break
            }
        }
        return rgb
    }

    private static func monoFromBayerRaw(buf: UnsafeRawBufferPointer,
                                         depth: Int,
                                         count: Int) -> [UInt8] {
        var mono = [UInt8](repeating: 0, count: count)
        if depth == 8 {
            let p = buf.bindMemory(to: UInt8.self)
            for i in 0..<count { mono[i] = p[i] }
        } else {
            let p = buf.bindMemory(to: UInt16.self)
            for i in 0..<count { mono[i] = UInt8(p[i] >> 8) }
        }
        return mono
    }

    // MARK: - Bilinear debayer

    /// Cheap bilinear Bayer demosaic — good enough for a QuickLook
    /// thumbnail. Patterns: 0=RGGB, 1=GRBG, 2=GBRG, 3=BGGR. Colour codes
    /// inside the layout matrix: 0=R, 1=G, 2=B.
    private static func debayerBilinear(mono: [UInt8],
                                        width: Int,
                                        height: Int,
                                        pattern: Int) -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: mono.count * 3)
        let layout: [[Int]]
        switch pattern {
        case 0: layout = [[0,1],[1,2]]  // RGGB
        case 1: layout = [[1,0],[2,1]]  // GRBG
        case 2: layout = [[1,2],[0,1]]  // GBRG
        case 3: layout = [[2,1],[1,0]]  // BGGR
        default: layout = [[0,1],[1,2]]
        }

        @inline(__always)
        func at(_ x: Int, _ y: Int) -> Int {
            let xx = min(max(x, 0), width - 1)
            let yy = min(max(y, 0), height - 1)
            return Int(mono[yy * width + xx])
        }

        for y in 0..<height {
            for x in 0..<width {
                let c = layout[y & 1][x & 1]
                let center = at(x, y)
                var r = 0, g = 0, b = 0
                switch c {
                case 0: // sensor is R
                    r = center
                    g = (at(x-1, y) + at(x+1, y) + at(x, y-1) + at(x, y+1)) / 4
                    b = (at(x-1, y-1) + at(x+1, y-1) + at(x-1, y+1) + at(x+1, y+1)) / 4
                case 2: // sensor is B
                    b = center
                    g = (at(x-1, y) + at(x+1, y) + at(x, y-1) + at(x, y+1)) / 4
                    r = (at(x-1, y-1) + at(x+1, y-1) + at(x-1, y+1) + at(x+1, y+1)) / 4
                default: // sensor is G — decide R/B from horizontal neighbour colour.
                    g = center
                    let leftColor = layout[y & 1][(x - 1 + 2) & 1]
                    let lr = (at(x-1, y) + at(x+1, y)) / 2
                    let ud = (at(x, y-1) + at(x, y+1)) / 2
                    if leftColor == 0 { r = lr; b = ud } else { b = lr; r = ud }
                }
                let i = y * width + x
                rgb[3*i]   = UInt8(min(255, max(0, r)))
                rgb[3*i+1] = UInt8(min(255, max(0, g)))
                rgb[3*i+2] = UInt8(min(255, max(0, b)))
            }
        }
        return rgb
    }

    // MARK: - Percentile auto-stretch → RGBA

    /// 1% / 99.5% luminance-percentile linear stretch. Mirrors the engine's
    /// `FileCatalog.autoStretchPercentile` so a SER thumbnail in Finder
    /// looks the same as the in-app preview the user is already used to.
    /// Output is interleaved RGBA8 (premultiplied alpha = 255).
    static func autoStretchRGB8ToRGBA(rgb8: [UInt8],
                                      width: Int,
                                      height: Int) -> [UInt8] {
        let count = width * height
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<count {
            let r = Int(rgb8[3*i])
            let g = Int(rgb8[3*i+1])
            let b = Int(rgb8[3*i+2])
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            hist[lum] += 1
        }
        let total = count
        let lowTarget  = total / 100
        let highTarget = total - total / 200

        var cum = 0, lo = 0, hi = 255
        for i in 0..<256 {
            cum += hist[i]
            if cum >= lowTarget { lo = i; break }
        }
        cum = 0
        for i in 0..<256 {
            cum += hist[i]
            if cum >= highTarget { hi = i; break }
        }

        var out = [UInt8](repeating: 255, count: count * 4)
        guard hi > lo + 1 else {
            // Flat / featureless frame: emit unstretched RGB → RGBA.
            for i in 0..<count {
                out[4*i]   = rgb8[3*i]
                out[4*i+1] = rgb8[3*i+1]
                out[4*i+2] = rgb8[3*i+2]
            }
            return out
        }

        let scale = 255.0 / Double(hi - lo)
        for i in 0..<count {
            for c in 0..<3 {
                let v = Int(rgb8[3*i + c])
                let s = Int(Double(v - lo) * scale + 0.5)
                out[4*i + c] = UInt8(min(255, max(0, s)))
            }
        }
        return out
    }

    // MARK: - Downsample (cheap box-average)

    /// Box-averaging downsample. Good enough for a thumbnail target;
    /// keeps the extension dependency-free (no vImage) so it can run
    /// inside the minimal QL sandbox without surprises.
    static func downsampleRGBA(_ rgba: [UInt8],
                               width: Int,
                               height: Int,
                               maxDim: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let big = max(width, height)
        guard big > maxDim else { return (rgba, width, height) }
        let factor = Int((Double(big) / Double(maxDim)).rounded(.up))
        let nw = max(1, width / factor)
        let nh = max(1, height / factor)
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        for ny in 0..<nh {
            for nx in 0..<nw {
                var sr = 0, sg = 0, sb = 0, sa = 0, n = 0
                for dy in 0..<factor {
                    let sy = ny * factor + dy
                    if sy >= height { continue }
                    for dx in 0..<factor {
                        let sx = nx * factor + dx
                        if sx >= width { continue }
                        let i = (sy * width + sx) * 4
                        sr += Int(rgba[i])
                        sg += Int(rgba[i+1])
                        sb += Int(rgba[i+2])
                        sa += Int(rgba[i+3])
                        n  += 1
                    }
                }
                let o = (ny * nw + nx) * 4
                if n > 0 {
                    out[o]   = UInt8(sr / n)
                    out[o+1] = UInt8(sg / n)
                    out[o+2] = UInt8(sb / n)
                    out[o+3] = UInt8(sa / n)
                }
            }
        }
        return (out, nw, nh)
    }

    // MARK: - CGImage construction

    static func makeCGImage(rgba8: [UInt8],
                            width: Int,
                            height: Int) -> CGImage? {
        guard !rgba8.isEmpty, width > 0, height > 0 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let nsData = NSData(bytes: rgba8, length: rgba8.count)
        guard let provider = CGDataProvider(data: nsData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: cs,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: - Helpers

    private static func readI32LE(_ data: Data, at offset: Int) -> Int32 {
        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + 4))
        }
        return Int32(littleEndian: value)
    }
}
