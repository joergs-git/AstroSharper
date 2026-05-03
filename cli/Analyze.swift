// `astrosharper analyze <file.ser>` — print SER metadata + sanity stats.
//
// This is the smallest possible end-to-end exercise of the CLI: open a
// SER, parse the header, print a summary. Pure Foundation, no Metal
// device required, so it doubles as a build smoke test for the CLI
// target. Everything heavier (frame decode + Metal-backed metrics)
// lands when Block A's quality intelligence work is wired in.
import Foundation

enum Analyze {
    static func run(args: [String]) -> Int32 {
        // Single positional: input file path. Optional flags:
        //   --json            JSON output instead of pretty text
        //   --probe-frame N   read bytes for frame N + report stats. Used
        //                     to diagnose >4GB memory-map issues: the
        //                     header parse alone reads only the first 178
        //                     bytes, which never trips a 4GB-offset bug.
        //                     Probing a frame past the 4GB boundary
        //                     forces a real read at the failing offset.
        var path: String?
        var emitJSON = false
        var probeFrame: Int?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json":
                emitJSON = true
                i += 1
            case "--probe-frame":
                guard i + 1 < args.count, let v = Int(args[i + 1]), v >= 0 else {
                    cliStderr("analyze: --probe-frame requires a non-negative integer")
                    return 64
                }
                probeFrame = v
                i += 2
            case let opt where opt.hasPrefix("--"):
                cliStderr("analyze: unknown option '\(opt)'")
                cliStderr("usage: astrosharper analyze <file.ser> [--json] [--probe-frame N]")
                return 64
            default:
                if path != nil {
                    cliStderr("analyze: only one input file accepted (got '\(path!)' and '\(arg)')")
                    return 64
                }
                path = arg
                i += 1
            }
        }

        guard let inputPath = path else {
            cliStderr("analyze: missing input file path")
            cliStderr("usage: astrosharper analyze <file.ser> [--json]")
            return 64
        }

        let url = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            cliStderr("analyze: file not found: \(url.path)")
            return 1
        }

        // Dispatch by extension. FITS routes to the FITS-specific emit
        // since its metadata vocabulary (BITPIX / NAXIS / DATE-OBS /
        // EXPTIME) doesn't map cleanly onto SER's. The frame probe is
        // SER-only and produces a usage error elsewhere.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "fits", "fit":
            do {
                let reader = try FitsFrameReader(url: url)
                if emitJSON {
                    emit(jsonFits: reader)
                } else {
                    emit(textFits: reader)
                }
                if probeFrame != nil {
                    cliStderr("analyze: --probe-frame is not supported for FITS (single-frame format)")
                    return 64
                }
                return 0
            } catch {
                cliStderr("analyze: failed to open '\(url.path)' as FITS: \(error)")
                return 1
            }
        default:
            do {
                let reader = try SerReader(url: url)
                if emitJSON {
                    emit(json: reader)
                } else {
                    emit(text: reader)
                }
                if let probeIdx = probeFrame {
                    return runFrameProbe(reader: reader, frameIndex: probeIdx)
                }
                return 0
            } catch {
                cliStderr("analyze: failed to open '\(url.path)': \(error)")
                return 1
            }
        }
    }

    // MARK: - FITS emit

    private static func emit(textFits reader: FitsFrameReader) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: reader.url.path)[.size] as? Int) ?? 0
        let totalGB = Double(bytes) / 1_000_000_000.0
        print("file        : \(reader.url.lastPathComponent)")
        print("format      : FITS (BITPIX=-32, NAXIS=2)")
        print("dimensions  : \(reader.imageWidth) x \(reader.imageHeight)")
        print("pixel depth : 32-bit float")
        if let date = reader.captureDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            print("captured UT : \(formatter.string(from: date))")
        } else {
            print("captured UT : (DATE-OBS not present in header)")
        }
        print("total bytes : \(bytes.formatted()) (\(String(format: "%.3f", totalGB)) GB)")
    }

    private static func emit(jsonFits reader: FitsFrameReader) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: reader.url.path)[.size] as? Int) ?? 0
        var payload: [String: Any] = [
            "filename": reader.url.lastPathComponent,
            "format": "fits",
            "imageWidth": reader.imageWidth,
            "imageHeight": reader.imageHeight,
            "frameCount": 1,
            "pixelDepth": 32,
            "colorID": "mono",
            "colorIsMono": true,
            "colorIsBayer": false,
            "colorIsRGB": false,
            "totalBytes": bytes,
        ]
        if let date = reader.captureDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            payload["captureDateUTC"] = formatter.string(from: date)
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    /// Read the raw bytes of frame `frameIndex` and report min / max /
    /// mean. The byte offset of the frame start is also printed; if the
    /// offset is > 4 GB and the read fails, the SER reader has a
    /// 32-bit-truncation bug somewhere in its memory-map path.
    private static func runFrameProbe(reader: SerReader, frameIndex: Int) -> Int32 {
        let h = reader.header
        guard frameIndex >= 0, frameIndex < h.frameCount else {
            cliStderr("analyze: --probe-frame \(frameIndex) is out of range [0, \(h.frameCount - 1)]")
            return 1
        }

        // Compute and print the byte offset.
        let frameOffset = 178 + frameIndex * h.bytesPerFrame
        let offsetGB = Double(frameOffset) / 1_000_000_000.0
        print("")
        print("--- probe frame \(frameIndex) ---")
        print("byte offset : \(frameOffset.formatted()) (\(String(format: "%.3f", offsetGB)) GB)")
        print("frame bytes : \(h.bytesPerFrame.formatted())")

        // Touch every byte in the frame. If the memory map is truncated
        // past the 4GB boundary, this will crash or read zeros where
        // there should be real data.
        let bytesPerPlane = h.bytesPerPlane
        var minVal: Int = Int.max
        var maxVal: Int = Int.min
        var sum: Double = 0
        let pxCount = h.imageWidth * h.imageHeight

        reader.withFrameBytes(at: frameIndex) { ptr, len in
            if bytesPerPlane == 2 {
                ptr.withMemoryRebound(to: UInt16.self, capacity: pxCount) { u16 in
                    for i in 0..<pxCount {
                        let v = Int(u16[i].littleEndian)
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                        sum += Double(v)
                    }
                }
            } else {
                for i in 0..<pxCount {
                    let v = Int(ptr[i])
                    if v < minVal { minVal = v }
                    if v > maxVal { maxVal = v }
                    sum += Double(v)
                }
            }
            _ = len
        }

        let mean = sum / Double(pxCount)
        let scale: Double = bytesPerPlane == 2 ? 65535.0 : 255.0
        print("pixel min   : \(minVal) (\(String(format: "%.4f", Double(minVal) / scale)))")
        print("pixel max   : \(maxVal) (\(String(format: "%.4f", Double(maxVal) / scale)))")
        print("pixel mean  : \(String(format: "%.1f", mean)) (\(String(format: "%.4f", mean / scale)))")
        if minVal == 0 && maxVal == 0 {
            print("WARNING: frame is all zeros — likely a >4GB memory-map truncation")
            return 2
        }
        if Double(maxVal) / scale < 0.01 {
            print("WARNING: frame is extremely dim (max < 1%) — preview will look black without auto-stretch")
        }
        return 0
    }

    // MARK: - Output

    private static func emit(text reader: SerReader) {
        let h = reader.header
        let totalBytes = h.frameCount * h.bytesPerFrame
        let totalGB = Double(totalBytes) / 1_000_000_000.0

        print("file        : \(reader.url.path)")
        print("dimensions  : \(h.imageWidth) × \(h.imageHeight)")
        print("frames      : \(h.frameCount)")
        print("bit depth   : \(h.pixelDepthPerPlane)")
        print("color       : \(h.colorID) (mono=\(h.colorID.isMono), bayer=\(h.colorID.isBayer), rgb=\(h.colorID.isRGB))")
        print("instrument  : \(emptyOrValue(h.instrument))")
        print("observer    : \(emptyOrValue(h.observer))")
        print("telescope   : \(emptyOrValue(h.telescope))")
        if let date = reader.captureDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            print("captured UT : \(formatter.string(from: date))")
        } else {
            print("captured UT : (unknown — header has no timestamp)")
        }
        print("frame bytes : \(h.bytesPerFrame.formatted())")
        print("total bytes : \(totalBytes.formatted()) (\(String(format: "%.2f", totalGB)) GB)")
    }

    private static func emit(json reader: SerReader) {
        let h = reader.header
        // Emit basename only (not absolute path) so the regression
        // harness's baselines are stable across machines and clones.
        // The full path is still in the input argument and the run log.
        var payload: [String: Any] = [
            "filename": reader.url.lastPathComponent,
            "imageWidth": h.imageWidth,
            "imageHeight": h.imageHeight,
            "frameCount": h.frameCount,
            "pixelDepth": h.pixelDepthPerPlane,
            "colorID": String(describing: h.colorID),
            "colorIsMono": h.colorID.isMono,
            "colorIsBayer": h.colorID.isBayer,
            "colorIsRGB": h.colorID.isRGB,
            "bytesPerFrame": h.bytesPerFrame,
            "totalBytes": h.frameCount * h.bytesPerFrame,
            "instrument": h.instrument,
            "observer": h.observer,
            "telescope": h.telescope
        ]
        if let date = reader.captureDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            payload["captureDateUTC"] = formatter.string(from: date)
        } else {
            payload["captureDateUTC"] = NSNull()
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                cliStderr("analyze: JSON encoding produced no bytes")
            }
        } catch {
            cliStderr("analyze: JSON encode failed: \(error)")
        }
    }

    private static func emptyOrValue(_ s: String) -> String {
        s.isEmpty ? "(none)" : s
    }
}
