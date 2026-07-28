// Helpers for building synthetic SER files in unit tests.
//
// SER's header is fixed at 178 bytes; frame data is tightly packed
// after that. We write a minimal valid header for a given color-ID +
// dimensions + frame count, fill the frame data with a fixed byte so
// readers can sanity-check the bytes-per-frame math, and return the
// temp URL. The test cleans up via `defer FileManager.removeItem`.
//
// Living in the test target only — never linked into the app or CLI.
import Foundation

enum SyntheticSER {
    /// Build a SER file at a fresh temp URL. Caller is responsible for
    /// cleaning it up.
    /// - Parameters:
    ///   - width: imageWidth field
    ///   - height: imageHeight field
    ///   - depth: pixelDepthPerPlane (8 or 16)
    ///   - frameCount: number of frames (each width*height*bytesPerPlane)
    ///   - colorID: SER ColorID (0 mono, 8 RGGB, 9 GRBG, 10 GBRG, 11 BGGR,
    ///              100 RGB, 101 BGR — the spec values)
    ///   - planesPerPixelOverride: force the samples-per-pixel used to size
    ///              the frame data, independent of `colorID`. Needed to build
    ///              non-conformant files on purpose — e.g. a legacy
    ///              AstroSharper export that stamped ColorID 16 onto packed
    ///              RGB data, which the reader must resolve by byte math.
    ///   - fillByte: byte value written to every pixel of every frame
    ///   - dateTimeUTC: 0 to omit the timestamp; otherwise .NET ticks
    static func write(
        width: Int = 64,
        height: Int = 48,
        depth: Int = 8,
        frameCount: Int = 3,
        colorID: Int32 = 0,
        planesPerPixelOverride: Int? = nil,
        fillByte: UInt8 = 0xAA,
        dateTimeUTC: Int64 = 0,
        observer: String = "",
        instrument: String = "",
        telescope: String = "",
        stampFrameIndices: Bool = false
    ) throws -> URL {
        var data = Data()
        data.reserveCapacity(178 + width * height * frameCount * (depth > 8 ? 2 : 1))

        // FileID — 14 ASCII bytes
        let fileID = "LUCAM-RECORDER".data(using: .ascii)!
        precondition(fileID.count == 14)
        data.append(fileID)

        data.appendLE(Int32(0))                   // luID
        data.appendLE(colorID)                    // colorID
        data.appendLE(Int32(0))                   // little-endian flag (SER: 0 = LE)
        data.appendLE(Int32(width))               // imageWidth
        data.appendLE(Int32(height))              // imageHeight
        data.appendLE(Int32(depth))               // pixelDepthPerPlane
        data.appendLE(Int32(frameCount))          // frameCount

        data.appendFixedAscii(observer, length: 40)
        data.appendFixedAscii(instrument, length: 40)
        data.appendFixedAscii(telescope, length: 40)

        data.appendLE(Int64(0))                   // dateTime (.NET ticks, local)
        data.appendLE(dateTimeUTC)                // dateTimeUTC

        precondition(data.count == 178, "header must be exactly 178 bytes")

        // Frames
        let bytesPerPlane = depth > 8 ? 2 : 1
        let planesPerPixel: Int
        if let planesPerPixelOverride {
            planesPerPixel = planesPerPixelOverride
        } else {
            switch colorID {
            case 100, 101: planesPerPixel = 3   // rgb / bgr, per the SER v3 spec
            default:       planesPerPixel = 1
            }
        }
        let bytesPerFrame = width * height * bytesPerPlane * planesPerPixel
        data.append(Data(repeating: fillByte, count: bytesPerFrame * frameCount))

        // Mark byte 0 of each frame with `0x10 + frameIndex` (mod 256) so
        // tests can verify multi-frame offset arithmetic in `withFrameBytes`.
        // Only applied when `stampFrameIndices` is true (default false to
        // keep existing tests' uniform-fill expectations intact).
        if stampFrameIndices {
            for frameIndex in 0..<frameCount {
                let stampOffset = 178 + frameIndex * bytesPerFrame
                data[stampOffset] = UInt8((0x10 + frameIndex) & 0xFF)
            }
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astrosharper-test-\(UUID().uuidString).ser")
        try data.write(to: url)
        return url
    }

    /// Build a mono16 SER from explicit per-frame sample buffers (row-major,
    /// `width*height` samples each). `byteSwapped` writes each sample in
    /// big-endian order, producing the non-conformant files that
    /// `SerReader.pixelDataIsLittleEndian` has to recognise.
    static func writeMono16(
        width: Int, height: Int, frames: [[UInt16]], byteSwapped: Bool = false
    ) throws -> URL {
        var data = Data()
        data.append("LUCAM-RECORDER".data(using: .ascii)!)   // 14 bytes
        data.appendLE(Int32(0))                 // luID
        data.appendLE(Int32(0))                 // colorID = mono
        data.appendLE(Int32(0))                 // little-endian flag (advisory)
        data.appendLE(Int32(width))
        data.appendLE(Int32(height))
        data.appendLE(Int32(16))                // 16-bit
        data.appendLE(Int32(frames.count))
        data.appendFixedAscii("", length: 40)   // observer
        data.appendFixedAscii("", length: 40)   // instrument
        data.appendFixedAscii("", length: 40)   // telescope
        data.appendLE(Int64(0))                 // dateTime
        data.appendLE(Int64(0))                 // dateTimeUTC
        precondition(data.count == 178)
        for f in frames {
            precondition(f.count == width * height, "frame must be width*height samples")
            // `appendLE` emits the value's little-endian bytes; feeding it a
            // pre-swapped sample therefore lays down big-endian bytes.
            for sample in f {
                data.appendLE(byteSwapped ? sample.byteSwapped : sample)
            }
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astrosharper-mono16-\(UUID().uuidString).ser")
        try data.write(to: url)
        return url
    }

    /// Build a mono8 SER from explicit per-frame pixel buffers (row-major,
    /// `width*height` bytes each). Used by the transit-detector tests to inject
    /// a moving blob / dark silhouette at exact positions.
    static func writeMono8(width: Int, height: Int, frames: [[UInt8]]) throws -> URL {
        var data = Data()
        data.append("LUCAM-RECORDER".data(using: .ascii)!)   // 14 bytes
        data.appendLE(Int32(0))                 // luID
        data.appendLE(Int32(0))                 // colorID = mono
        data.appendLE(Int32(0))                 // little-endian
        data.appendLE(Int32(width))
        data.appendLE(Int32(height))
        data.appendLE(Int32(8))                 // 8-bit
        data.appendLE(Int32(frames.count))
        data.appendFixedAscii("", length: 40)   // observer
        data.appendFixedAscii("", length: 40)   // instrument
        data.appendFixedAscii("", length: 40)   // telescope
        data.appendLE(Int64(0))                 // dateTime
        data.appendLE(Int64(0))                 // dateTimeUTC
        precondition(data.count == 178)
        for f in frames {
            precondition(f.count == width * height, "frame must be width*height bytes")
            data.append(contentsOf: f)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astrosharper-transit-\(UUID().uuidString).ser")
        try data.write(to: url)
        return url
    }
}

private extension Data {
    /// Append a little-endian fixed-width integer. We need the explicit
    /// `Swift.` prefix because in a `Data` extension `withUnsafeBytes`
    /// resolves to the instance method rather than the free function we
    /// want here.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    /// Append an ASCII string padded/truncated to `length` bytes with NULs.
    mutating func appendFixedAscii(_ s: String, length: Int) {
        let raw = Array(s.utf8.prefix(length))
        append(contentsOf: raw)
        if raw.count < length {
            append(Data(repeating: 0, count: length - raw.count))
        }
    }
}
