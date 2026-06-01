// Per-frame processed-bytes provider used by SerWriter + GifWriter
// when the user opts to bake the current Sharpen + Tone settings
// into the exported file.
//
// Pipeline (per frame, identical to what the live preview shows):
//   raw SER frame bytes
//     → SerFrameLoader.loadFrame → rgba16Float MTLTexture (Bayer demosaiced)
//     → Pipeline.process(sharpen, toneCurve, LUT) → processed rgba16Float
//     → blit to .shared storage, getBytes for the crop window
//     → convert Float16 RGBA → 8-bit RGB or 16-bit RGB (SER bake-in
//       always writes 16-bit RGB to keep dynamic range; GIF bake-in
//       always 8-bit RGBA).
//
// The exporter builds its Pipeline + tone LUT ONCE per export job
// (sharpen/tone settings are frozen during the job) so per-frame work
// is just decode + process + readback.
import Foundation
import Metal
import MetalPerformanceShaders
import CoreGraphics

enum BakeInExporter {
    struct Options {
        let sharpen: SharpenSettings
        let toneCurve: ToneCurveSettings
        let coloring: ColoringSettings
        /// 8 = pack to UInt8 RGB (GIF + 8-bit SER); 16 = pack to UInt16 RGB (SER).
        let outputBitDepth: Int
        /// 1 = full res, 2 = half (½×½ = ¼ area), 4 = quarter, 8, 16.
        /// Applied AFTER Sharpen+Tone via an MPS bilinear scale, so the
        /// processed image is downsampled to the requested size and the
        /// readback is correspondingly smaller. Keeps GIFs manageable
        /// for 4 GB SER sources.
        let resizeDivisor: Int
        /// 0 / 90 / 180 / 270 — clockwise rotation applied to each
        /// output frame AFTER resize, in CPU. For 90 / 270 the output
        /// width and height swap.
        let rotationDegrees: Int

        init(sharpen: SharpenSettings,
             toneCurve: ToneCurveSettings,
             coloring: ColoringSettings = ColoringSettings(),
             outputBitDepth: Int,
             resizeDivisor: Int = 1,
             rotationDegrees: Int = 0) {
            self.sharpen = sharpen
            self.toneCurve = toneCurve
            self.coloring = coloring
            self.outputBitDepth = outputBitDepth
            self.resizeDivisor = max(1, resizeDivisor)
            // Snap to nearest multiple of 90 in 0..<360.
            var r = rotationDegrees % 360
            if r < 0 { r += 360 }
            let snapped = ((r + 45) / 90) * 90 % 360
            self.rotationDegrees = snapped
        }
    }

    struct FrameOut {
        let width: Int
        let height: Int
        let bytesPerPixel: Int       // 3 for SER RGB; 4 for GIF RGBA
        let data: Data
    }

    /// One context per export job — owns the Pipeline + tone LUT so the
    /// per-frame call only pays for upload + process + readback.
    final class Context {
        let options: Options
        private let pipeline: Pipeline
        private let lut: MTLTexture?
        private let device: MTLDevice

        init(options: Options) {
            // Strip per-frame auto-color decisions for video bake-in.
            //
            // auto-WB, channel-normalize, chromatic alignment and
            // purple-fringe all compute their corrections from the
            // CURRENT frame's statistics. On a single still image
            // that's what the user wants. On a 60-frame GIF the
            // per-frame measurements drift across frames (noise,
            // seeing, drifting subject geometry), so every frame
            // gets a slightly different correction → output strobes
            // as the playback walks through them. The user just
            // reported exactly this on an OSC GIF (autoWB +
            // channelNormalize default-ON via OscDefaults).
            //
            // Manual Coloring curves stay live — those are pure per-
            // pixel LUTs, frame-stable by construction. The user's
            // Tone curve + B/C + Sat also stay live for the same
            // reason.
            var stableTone = options.toneCurve
            stableTone.autoWB = false
            stableTone.channelNormalize = false
            stableTone.chromaticAlignment = false
            stableTone.reducePurpleFringe = false
            self.options = Options(
                sharpen: options.sharpen,
                toneCurve: stableTone,
                coloring: options.coloring,
                outputBitDepth: options.outputBitDepth,
                resizeDivisor: options.resizeDivisor,
                rotationDegrees: options.rotationDegrees
            )
            self.device = MetalDevice.shared.device
            self.pipeline = Pipeline()
            // Build tone LUT once. Mirrors PreviewCoordinator.ensureLUT.
            if !stableTone.enabled {
                self.lut = nil
            } else if stableTone.solarDualZone {
                self.lut = ToneCurveLUT.buildSolarDualZone(device: device)
            } else {
                self.lut = ToneCurveLUT.build(
                    points: stableTone.controlPoints,
                    device: device
                )
            }
        }

        /// Decode `frameIndex` from `sourceURL`, run it through the
        /// frozen Sharpen + Tone chain, optionally crop, and return
        /// packed bytes in the requested bit depth.
        ///
        /// `crop` is in source-pixel coords (top-left origin). When nil
        /// the full processed frame is returned.
        func processedFrame(
            sourceURL: URL,
            frameIndex: Int,
            crop: CGRect?
        ) throws -> FrameOut {
            // 1) Decode raw → rgba16Float (Bayer demosaiced).
            let inputTex = try SerFrameLoader.loadFrame(
                url: sourceURL, frameIndex: frameIndex, device: device
            )
            // 2) Run the live Sharpen + Tone + Coloring pipeline.
            let outTex = pipeline.process(
                input: inputTex,
                sharpen: options.sharpen,
                toneCurve: options.toneCurve,
                toneCurveLUT: lut,
                coloring: options.coloring,
                preview: false
            )
            // 3) Determine crop window (source pixels). The processed
            //    texture has the same width × height as the source.
            let srcW = outTex.width
            let srcH = outTex.height
            var cx = 0, cy = 0, cw = srcW, ch = srcH
            if let c = crop {
                cx = max(0, min(srcW - 1, Int(c.origin.x.rounded())))
                cy = max(0, min(srcH - 1, Int(c.origin.y.rounded())))
                cw = max(2, min(srcW - cx, Int(c.width.rounded())))
                ch = max(2, min(srcH - cy, Int(c.height.rounded())))
            }
            // 4) Resolve output dimensions after resize. Floor so we
            //    never overshoot the cropped region; min 2 px so the
            //    blit/getBytes never gets a degenerate region.
            let div = max(1, options.resizeDivisor)
            let outW = max(2, cw / div)
            let outH = max(2, ch / div)

            // 5) Blit the cropped region of `outTex` into a .shared
            //    staging texture at output dimensions. When no resize,
            //    a direct blit copy. With resize, run MPSImageBilinear
            //    Scale to downsample on the GPU.
            let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: outW, height: outH, mipmapped: false
            )
            stageDesc.storageMode = .shared
            stageDesc.usage = [.shaderRead, .shaderWrite]
            guard let staging = device.makeTexture(descriptor: stageDesc) else {
                throw BakeError.gpuAllocFailed
            }
            guard let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer() else {
                throw BakeError.commandQueueFailed
            }
            if div == 1 {
                guard let blit = cmd.makeBlitCommandEncoder() else {
                    throw BakeError.commandQueueFailed
                }
                blit.copy(
                    from: outTex,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: cx, y: cy, z: 0),
                    sourceSize: MTLSize(width: cw, height: ch, depth: 1),
                    to: staging,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            } else {
                // Bilinear downscale via MPS. The scale takes the full
                // input texture, so first blit the crop into an
                // intermediate .private texture sized cw × ch, then
                // scale into the smaller .shared staging texture.
                let cropDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float, width: cw, height: ch, mipmapped: false
                )
                cropDesc.storageMode = .private
                cropDesc.usage = [.shaderRead, .shaderWrite]
                guard let cropTex = device.makeTexture(descriptor: cropDesc) else {
                    throw BakeError.gpuAllocFailed
                }
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(
                        from: outTex,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: cx, y: cy, z: 0),
                        sourceSize: MTLSize(width: cw, height: ch, depth: 1),
                        to: cropTex,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blit.endEncoding()
                }
                let scaler = MPSImageBilinearScale(device: device)
                let scaleX = Double(outW) / Double(cw)
                let scaleY = Double(outH) / Double(ch)
                var transform = MPSScaleTransform(
                    scaleX: scaleX, scaleY: scaleY, translateX: 0, translateY: 0
                )
                withUnsafePointer(to: &transform) { ptr in
                    scaler.scaleTransform = ptr
                    scaler.encode(commandBuffer: cmd, sourceTexture: cropTex, destinationTexture: staging)
                }
            }
            cmd.commit()
            cmd.waitUntilCompleted()

            // 6) getBytes the full staging texture (already at outW × outH).
            let f16Stride = MemoryLayout<UInt16>.stride * 4
            let cropRowBytes = outW * f16Stride
            var f16Buf = [UInt16](repeating: 0, count: outW * outH * 4)
            f16Buf.withUnsafeMutableBufferPointer { buf in
                staging.getBytes(
                    buf.baseAddress!,
                    bytesPerRow: cropRowBytes,
                    from: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: outW, height: outH, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
            // Re-bind cw / ch to the actual output dims for the packer below.
            let pcw = outW
            let pch = outH
            // 7) Pack Float16 RGBA → output, applying CPU rotation
            //    during the pixel walk. For rotation 0 the dst index
            //    increments linearly; for 90/180/270 we re-map (sx, sy)
            //    in the source buffer to (dx, dy) in the destination.
            //    Doing it during pack avoids a second pass + extra
            //    allocation. For 90/270 the output width and height
            //    swap.
            let rot = options.rotationDegrees
            let (dstW, dstH): (Int, Int) = (rot == 90 || rot == 270)
                ? (pch, pcw) : (pcw, pch)

            if options.outputBitDepth == 8 {
                var rgba = Data(count: dstW * dstH * 4)
                rgba.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: UInt8.self).baseAddress!
                    for sy in 0..<pch {
                        for sx in 0..<pcw {
                            let (dx, dy) = rotMap(sx: sx, sy: sy, pcw: pcw, pch: pch, rot: rot)
                            let dstIdx = (dy * dstW + dx) * 4
                            let srcIdx = (sy * pcw + sx) * 4
                            p[dstIdx + 0] = float16ToU8(f16Buf[srcIdx + 0])
                            p[dstIdx + 1] = float16ToU8(f16Buf[srcIdx + 1])
                            p[dstIdx + 2] = float16ToU8(f16Buf[srcIdx + 2])
                            p[dstIdx + 3] = 255
                        }
                    }
                }
                return FrameOut(width: dstW, height: dstH, bytesPerPixel: 4, data: rgba)
            } else {
                var rgb = Data(count: dstW * dstH * 6)
                rgb.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: UInt16.self).baseAddress!
                    for sy in 0..<pch {
                        for sx in 0..<pcw {
                            let (dx, dy) = rotMap(sx: sx, sy: sy, pcw: pcw, pch: pch, rot: rot)
                            let dstIdx = (dy * dstW + dx) * 3
                            let srcIdx = (sy * pcw + sx) * 4
                            p[dstIdx + 0] = float16ToU16(f16Buf[srcIdx + 0])
                            p[dstIdx + 1] = float16ToU16(f16Buf[srcIdx + 1])
                            p[dstIdx + 2] = float16ToU16(f16Buf[srcIdx + 2])
                        }
                    }
                }
                return FrameOut(width: dstW, height: dstH, bytesPerPixel: 6, data: rgb)
            }
        }
    }

    enum BakeError: LocalizedError {
        case gpuAllocFailed
        case commandQueueFailed
        var errorDescription: String? {
            switch self {
            case .gpuAllocFailed:     return "Bake-in: GPU staging texture allocation failed."
            case .commandQueueFailed: return "Bake-in: Metal command queue unavailable."
            }
        }
    }

    // MARK: - Float16 unpack helpers
    //
    // The pipeline outputs values in [0…1] linear-ish. We clamp before
    // quantising so spikes above 1.0 (rare; can happen during sharpen
    // overshoot at 1.0 boundary) don't wrap UInt8.

    /// Maps a source-buffer (sx, sy) to a destination-buffer (dx, dy)
    /// for clockwise rotation. pcw/pch are the pre-rotation dims; the
    /// caller pre-computes the post-rotation dstW/dstH.
    @inline(__always)
    private static func rotMap(sx: Int, sy: Int, pcw: Int, pch: Int, rot: Int) -> (Int, Int) {
        switch rot {
        case 90:  return (pch - 1 - sy, sx)        // clockwise 90°
        case 180: return (pcw - 1 - sx, pch - 1 - sy)
        case 270: return (sy, pcw - 1 - sx)        // clockwise 270°
        default:  return (sx, sy)
        }
    }

    @inline(__always)
    private static func float16ToU8(_ raw: UInt16) -> UInt8 {
        let f = Float(Float16(bitPattern: raw))
        let clamped = max(0, min(1, f))
        return UInt8((clamped * 255.0).rounded())
    }

    @inline(__always)
    private static func float16ToU16(_ raw: UInt16) -> UInt16 {
        let f = Float(Float16(bitPattern: raw))
        let clamped = max(0, min(1, f))
        return UInt16((clamped * 65535.0).rounded())
    }
}
