// SER export — writes a new .ser containing a frame range + crop
// rectangle of a source SER. Preserves bit depth, colour ID, byte
// order, observer/instrument/telescope strings, and the originating
// timestamps for the chosen range.
//
// The SER format (LUCAM Recorder v3) is:
//   178-byte header  (file ID + per-field little-endian metadata)
//   frame_count × image_width × image_height × bytes-per-pixel bytes
//   optional trailer with one int64 timestamp per frame
//
// We mutate three header fields for the export:
//   imageWidth   → crop width  (or source width if no crop)
//   imageHeight  → crop height (or source height if no crop)
//   frameCount   → trimmed range count
// Everything else is copied verbatim from the source header so the
// output is a valid SER that any tool can re-open (PIPP, AS!4, …).
//
// Per frame: read the source bytes, optionally copy only the crop
// rows + cols, append to the output file. For 16-bit-per-channel SER
// the byte stride doubles. Bayer crops MUST be aligned to even (2px)
// offsets to preserve the colour pattern — the writer rounds the
// crop origin down to the nearest even pixel when the source is
// Bayer.
import Foundation

enum SerWriter {
    enum WriteError: LocalizedError {
        case openFailed(String)
        case writeFailed(String)
        case invalidCrop(String)
        case emptyRange

        var errorDescription: String? {
            switch self {
            case .openFailed(let s):  return "Open failed: \(s)"
            case .writeFailed(let s): return "Write failed: \(s)"
            case .invalidCrop(let s): return "Crop invalid: \(s)"
            case .emptyRange:         return "Frame range is empty."
            }
        }
    }

    /// Write `frameRange` of the source SER into a new SER at
    /// `output`, optionally cropping every frame to `crop`.
    /// - Parameters:
    ///   - source: input SER URL
    ///   - output: output SER URL (file at this path is overwritten)
    ///   - frameRange: closed range of source frame indices to include
    ///   - crop: source-pixel rect; nil = full frame. Snapped to even
    ///           coords on Bayer sources to preserve the colour pattern.
    ///   - fps: playback fps to encode into the output's per-frame
    ///          timestamp trailer (SER format spec). Most SER players
    ///          (SER Player, PIPP, AS!4, FireCapture) derive playback
    ///          fps from the trailer rather than from any single header
    ///          field, so this is the right knob to control "how fast
    ///          should this thing play back". Pass `nil` to skip the
    ///          trailer entirely (smaller file, viewer defaults apply).
    ///   - progress: optional callback (0.0…1.0) for UI feedback
    static func write(
        source: URL,
        output: URL,
        frameRange: ClosedRange<Int>,
        crop: CGRect?,
        bakeIn: BakeInExporter.Options? = nil,
        frameStride: Int = 1,
        targetFrameCount: Int? = nil,
        fps: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard !frameRange.isEmpty else { throw WriteError.emptyRange }
        let reader = try SerReader(url: source)
        let h = reader.header
        let srcW = h.imageWidth
        let srcH = h.imageHeight
        let bpp = h.bytesPerPlane * (h.colorID.isRGB ? 3 : 1)

        // Resolve + validate crop.
        var cx = 0, cy = 0, cw = srcW, ch_ = srcH
        if let c = crop {
            cx = Int(c.origin.x.rounded())
            cy = Int(c.origin.y.rounded())
            cw = Int(c.width.rounded())
            ch_ = Int(c.height.rounded())
            if h.colorID.isBayer {
                // Snap to even — preserves the Bayer mosaic.
                cx &= ~1; cy &= ~1
                if cw & 1 != 0 { cw -= 1 }
                if ch_ & 1 != 0 { ch_ -= 1 }
            }
            cx = max(0, min(srcW - 1, cx))
            cy = max(0, min(srcH - 1, cy))
            cw = max(2, min(srcW - cx, cw))
            ch_ = max(2, min(srcH - cy, ch_))
        }

        let frameStart = max(0, min(frameRange.lowerBound, h.frameCount - 1))
        let frameEnd   = max(frameStart, min(frameRange.upperBound, h.frameCount - 1))
        // Stride-aware index list. stride=1 → [start, start+1, …, end];
        // stride=5 → [start, start+5, start+10, …].
        let stride = max(1, frameStride)
        let candidates: [Int] = Swift.stride(
            from: frameStart, through: frameEnd, by: stride
        ).map { $0 }
        guard !candidates.isEmpty else { throw WriteError.emptyRange }
        // If the caller wants a specific output frame count
        // (duration × fps from the export panel), evenly distribute
        // that many picks across the stride-filtered candidates.
        // Otherwise use every candidate (legacy stride-only behaviour).
        let pickedIndices: [Int]
        if let target = targetFrameCount, target > 0, target < candidates.count {
            var picked: [Int] = []
            picked.reserveCapacity(target)
            if target == 1 {
                picked.append(candidates[0])
            } else {
                for i in 0..<target {
                    let t = Double(i) / Double(target - 1)
                    let pos = Int((t * Double(candidates.count - 1)).rounded())
                    picked.append(candidates[pos])
                }
            }
            pickedIndices = picked
        } else {
            pickedIndices = candidates
        }
        let count = pickedIndices.count
        guard count > 0 else { throw WriteError.emptyRange }

        // Build output header — copy source bytes, override fields.
        let srcHeaderBytes = try Data(contentsOf: source, options: .alwaysMapped).prefix(178)
        guard srcHeaderBytes.count == 178 else {
            throw WriteError.openFailed("Header too short")
        }
        var hdr = Data(srcHeaderBytes)

        // SER header layout offsets (little-endian, 32-bit ints unless noted):
        //   14   LuID (uint32)
        //   18   ColorID
        //   22   LittleEndian
        //   26   ImageWidth
        //   30   ImageHeight
        //   34   PixelDepthPerPlane
        //   38   FrameCount
        let colorOff:  Int = 18
        let widthOff:  Int = 26
        let heightOff: Int = 30
        let depthOff:  Int = 34
        let frameOff:  Int = 38
        // Resolve output dimensions. Bake-in with resizeDivisor > 1
        // shrinks the frame on the GPU; rotation 90/270 swaps width
        // and height. Header must reflect the final on-disk frame
        // size, not the source crop.
        let div = max(1, bakeIn?.resizeDivisor ?? 1)
        let postResizeW = max(2, cw / div)
        let postResizeH = max(2, ch_ / div)
        let rot = bakeIn?.rotationDegrees ?? 0
        let (hdrW, hdrH): (Int, Int) = (rot == 90 || rot == 270)
            ? (postResizeH, postResizeW)
            : (postResizeW, postResizeH)
        writeInt32LE(&hdr, offset: widthOff,  value: Int32(hdrW))
        writeInt32LE(&hdr, offset: heightOff, value: Int32(hdrH))
        writeInt32LE(&hdr, offset: frameOff,  value: Int32(count))
        // Bake-in flips the SER from whatever the source was (mono /
        // Bayer / RGB-8) to 16-bit RGB. Reason: the processing
        // pipeline outputs demosaiced RGB and tone-mapped values; we
        // preserve maximum dynamic range by writing 16-bit per channel.
        if bakeIn != nil {
            writeInt32LE(&hdr, offset: colorOff, value: Int32(SerColorID.rgb.rawValue))
            writeInt32LE(&hdr, offset: depthOff, value: 16)
        }

        // Create + open the output file.
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        fm.createFile(atPath: output.path, contents: nil, attributes: nil)
        guard let outFH = try? FileHandle(forWritingTo: output) else {
            throw WriteError.openFailed("Open output failed")
        }
        defer { try? outFH.close() }

        try outFH.write(contentsOf: hdr)

        // Bake-in path: every frame goes through Sharpen + Tone on the
        // GPU and is re-encoded as 16-bit RGB (3×UInt16 per pixel, LE).
        // Crop happens inside processedFrame() via texture getBytes.
        if let opts = bakeIn {
            // Pass the caller's Options through verbatim so resize +
            // rotation reach the GPU pipeline. Re-wrapping with only
            // sharpen/tone/depth silently dropped them and produced
            // full-size unrotated SERs.
            let ctx = BakeInExporter.Context(options: opts)
            for (i, idx) in pickedIndices.enumerated() {
                let frame = try ctx.processedFrame(
                    sourceURL: source,
                    frameIndex: idx,
                    crop: (cx == 0 && cy == 0 && cw == srcW && ch_ == srcH) ? nil
                          : CGRect(x: cx, y: cy, width: cw, height: ch_)
                )
                try outFH.write(contentsOf: frame.data)
                if i % 8 == 0 || i == count - 1 {
                    progress?(Double(i + 1) / Double(count))
                }
            }
            try appendTimestampTrailer(handle: outFH, header: hdr, count: count, fps: fps)
            return
        }

        // Raw-copy path. For a full-frame copy we blast bytes straight
        // through. For a crop we slice rows.
        let rowBytes = cw * bpp
        let srcRowBytes = srcW * bpp
        let isFullFrame = (cx == 0 && cy == 0 && cw == srcW && ch_ == srcH)

        // Reusable row buffer for the crop path.
        var rowBuf = [UInt8](repeating: 0, count: rowBytes)

        for (i, idx) in pickedIndices.enumerated() {
            guard reader.canReadFrame(at: idx) else {
                throw WriteError.writeFailed("Source frame \(idx) not readable.")
            }
            reader.withFrameBytes(at: idx) { ptr, _ in
                if isFullFrame {
                    // One write per frame.
                    let bytes = srcW * srcH * bpp
                    let data = Data(bytes: ptr, count: bytes)
                    try? outFH.write(contentsOf: data)
                } else {
                    // Row-by-row inside the crop window.
                    for y in 0..<ch_ {
                        let srcY = cy + y
                        let srcBase = srcY * srcRowBytes + cx * bpp
                        rowBuf.withUnsafeMutableBufferPointer { buf in
                            memcpy(buf.baseAddress, ptr.advanced(by: srcBase), rowBytes)
                        }
                        let data = Data(rowBuf)
                        try? outFH.write(contentsOf: data)
                    }
                }
            }
            if i % 16 == 0 || i == count - 1 {
                progress?(Double(i + 1) / Double(count))
            }
        }

        // Trailing per-frame timestamps. SER spec defines an optional
        // trailer of `frameCount × Int64 LE` .NET-tick timestamps
        // immediately after the last frame's pixel data. Most viewers
        // (SER Player, FireCapture, AS!4) compute playback fps from
        // this trailer rather than from any header field, so writing it
        // is how we control "how fast does this thing play back".
        try appendTimestampTrailer(handle: outFH, header: hdr, count: count, fps: fps)
    }

    /// Append an N×Int64 LE timestamp trailer to the just-written file.
    /// Frame 0 timestamp = source header's dateTimeUTC (offset 162);
    /// subsequent frames are equally spaced at `1/fps` seconds apart.
    /// Pass `fps == nil` to skip the trailer entirely.
    private static func appendTimestampTrailer(handle: FileHandle,
                                               header: Data,
                                               count: Int,
                                               fps: Int?) throws {
        guard let fps = fps, fps > 0, count > 0 else { return }
        // .NET ticks = 100-ns intervals. Source dateTimeUTC lives at
        // offset 162 (Int64 LE); if missing/zero, fall back to "now" in
        // ticks so the timestamps are at least monotonic + plausible.
        let startTicks = readInt64LE(header, offset: 162)
        let baseTicks: Int64
        if startTicks > 0 {
            baseTicks = startTicks
        } else {
            // .NET epoch is 0001-01-01 UTC; Unix epoch offset is
            // 62_135_596_800 seconds. ticks = (unix + offset) * 10^7.
            let unixSecs = Date().timeIntervalSince1970
            baseTicks = Int64((unixSecs + 62_135_596_800) * 10_000_000)
        }
        let ticksPerFrame = Int64(10_000_000 / fps)   // 10^7 = 1 second
        var trailer = Data(capacity: count * 8)
        for i in 0..<count {
            var ts = (baseTicks + Int64(i) * ticksPerFrame).littleEndian
            withUnsafeBytes(of: &ts) { raw in
                trailer.append(contentsOf: raw)
            }
        }
        try handle.write(contentsOf: trailer)
    }

    @inline(__always)
    private static func readInt64LE(_ data: Data, offset: Int) -> Int64 {
        guard data.count >= offset + 8 else { return 0 }
        var v: Int64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + 8))
        }
        return Int64(littleEndian: v)
    }

    @inline(__always)
    private static func writeInt32LE(_ data: inout Data, offset: Int, value: Int32) {
        var v = value.littleEndian
        let p = UnsafeBufferPointer(start: &v, count: 1)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(base.advanced(by: offset), p.baseAddress, 4)
        }
    }
}
