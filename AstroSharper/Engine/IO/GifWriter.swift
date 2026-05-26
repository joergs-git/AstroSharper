// Animated GIF export — writes the SER frame range out as a GIF
// with configurable target frame count and FPS. Built on ImageIO's
// CGImageDestination which handles the GIF89a encoding (LZW, palette
// quantisation, per-frame delay, loop count).
//
// Frame sub-sampling: if the user picked fewer target frames than
// the trimmed range, we sample evenly so the GIF spans the full
// time range without bloating size. e.g. 600-frame range + target
// 60 = every 10th frame.
//
// Crop: same rectangle as SerWriter — applied per-frame before
// the GIF encode. For Bayer sources the bytes get a quick CPU
// demosaic (2×2 RGGB) so the GIF shows colour, not raw mosaic.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum GifWriter {
    enum WriteError: LocalizedError {
        case openFailed(String)
        case writeFailed(String)
        case emptyRange

        var errorDescription: String? {
            switch self {
            case .openFailed(let s):  return "GIF open failed: \(s)"
            case .writeFailed(let s): return "GIF write failed: \(s)"
            case .emptyRange:         return "Frame range is empty."
            }
        }
    }

    static func write(
        source: URL,
        output: URL,
        frameRange: ClosedRange<Int>,
        targetFrameCount: Int,
        fps: Int,
        crop: CGRect?,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard !frameRange.isEmpty else { throw WriteError.emptyRange }
        let reader = try SerReader(url: source)
        let h = reader.header
        let srcW = h.imageWidth
        let srcH = h.imageHeight

        // Crop snapping (mirror SerWriter's logic).
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

        let frameStart = max(0, min(frameRange.lowerBound, h.frameCount - 1))
        let frameEnd   = max(frameStart, min(frameRange.upperBound, h.frameCount - 1))
        let totalAvail = frameEnd - frameStart + 1
        let outCount = max(1, min(targetFrameCount, totalAvail))

        // Pick evenly-spaced frame indices.
        var pickedIndices: [Int] = []
        pickedIndices.reserveCapacity(outCount)
        if outCount == 1 {
            pickedIndices.append(frameStart)
        } else {
            for i in 0..<outCount {
                let t = Double(i) / Double(outCount - 1)
                let idx = frameStart + Int((t * Double(totalAvail - 1)).rounded())
                pickedIndices.append(idx)
            }
        }

        let delay = 1.0 / Double(max(1, fps))
        let dest = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.gif.identifier as CFString,
            outCount, nil
        )
        guard let dest else {
            throw WriteError.openFailed("CGImageDestinationCreate")
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,            // infinite
            ] as [CFString: Any]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ] as [CFString: Any]
        ]

        let isBayer = h.colorID.isBayer
        let mono16  = !isBayer && h.bytesPerPlane == 2 && !h.colorID.isRGB

        let outW = cw
        let outH = ch_
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)

        for (i, frameIdx) in pickedIndices.enumerated() {
            guard reader.canReadFrame(at: frameIdx) else { continue }
            reader.withFrameBytes(at: frameIdx) { ptr, _ in
                fillRGBA(
                    ptr: ptr,
                    srcW: srcW, srcH: srcH,
                    cx: cx, cy: cy, cw: outW, ch: outH,
                    isBayer: isBayer, mono16: mono16,
                    colorID: h.colorID,
                    rgba: &rgba
                )
            }
            if let cg = makeCGImage(rgba: rgba, width: outW, height: outH) {
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            }
            if i % 4 == 0 || i == outCount - 1 {
                progress?(Double(i + 1) / Double(outCount))
            }
        }

        if !CGImageDestinationFinalize(dest) {
            throw WriteError.writeFailed("Finalize failed")
        }
    }

    /// Decode the source's crop window into an RGBA byte buffer.
    /// Mono sources broadcast to all three channels; Bayer sources
    /// get a quick 2×2 RGGB demosaic with green-average.
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

    private static func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmpInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs, bitmapInfo: bmpInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
