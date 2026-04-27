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
    ///   - colorID: SER ColorID (0 mono, 8 RGGB, 9 GRBG, 10 GBRG, 11 BGGR)
    ///   - fillByte: byte value written to every pixel of every frame
    ///   - dateTimeUTC: 0 to omit the timestamp; otherwise .NET ticks
    static func write(
        width: Int = 64,
        height: Int = 48,
        depth: Int = 8,
        frameCount: Int = 3,
        colorID: Int32 = 0,
        fillByte: UInt8 = 0xAA,
        dateTimeUTC: Int64 = 0,
        observer: String = "",
        instrument: String = "",
        telescope: String = ""
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
        switch colorID {
        case 16, 17: planesPerPixel = 3   // rgb / bgr
        default:     planesPerPixel = 1
        }
        let bytesPerFrame = width * height * bytesPerPlane * planesPerPixel
        data.append(Data(repeating: fillByte, count: bytesPerFrame * frameCount))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astrosharper-test-\(UUID().uuidString).ser")
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
