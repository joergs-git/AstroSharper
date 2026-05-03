// Decode a single SER frame into a Metal texture, pipeline-ready (rgba16Float).
//
// Used by the preview view when the user selects a `.ser` row in the file
// list, so they see frame 0 immediately and can adjust sharpening / tone
// against it before kicking off the full lucky-stack run.
import Foundation
import Metal
import os

enum SerFrameLoader {
    enum Error: Swift.Error {
        case unsupportedColor
        case decodeFailed
        case readerOpenFailed(String)
        case stagingTextureFailed(width: Int, height: Int)
        case destTextureFailed(width: Int, height: Int)
        case kernelMissing(String)
        case commandBufferMissing
    }

    private static let log = OSLog(subsystem: "com.joergsflow.AstroSharper", category: "SerFrameLoader")

    /// Returns a private-storage rgba16Float texture containing frame `index`
    /// of the SER at `url`. Supports mono 8/16 and 4 Bayer patterns
    /// (RGGB / GRBG / GBRG / BGGR) at 8/16 bit. Bayer is bilinearly
    /// demosaiced on the GPU during unpack.
    static func loadFrame(url: URL, frameIndex: Int = 0, device: MTLDevice) throws -> MTLTexture {
        let reader: SerReader
        do {
            reader = try SerReader(url: url)
        } catch {
            os_log("SerReader open failed for %{public}@ — %{public}@",
                   log: log, type: .error, url.lastPathComponent, String(describing: error))
            throw Error.readerOpenFailed("\(error)")
        }
        let h = reader.header
        os_log("SER opened %{public}@ — %dx%d, %d frames, %d-bit, colorID=%{public}@, bytesPerFrame=%d",
               log: log, type: .info,
               url.lastPathComponent, h.imageWidth, h.imageHeight, h.frameCount,
               h.pixelDepthPerPlane, String(describing: h.colorID), h.bytesPerFrame)
        // 16-bit RGB SERs are out of scope for the v0 RGB unpack kernel —
        // throw a specific error so the user-facing surface tells them
        // why instead of producing wrong-coloured output.
        if h.colorID.isRGB && h.bytesPerPlane != 1 {
            os_log("SerFrameLoader: 16-bit RGB SER not yet supported (colorID=%{public}@, depth=%d)",
                   log: log, type: .error, String(describing: h.colorID), h.pixelDepthPerPlane)
            throw Error.unsupportedColor
        }
        guard h.colorID.isMono || h.colorID.isBayer || h.colorID.isRGB else {
            os_log("SerFrameLoader: unsupported colorID %{public}@", log: log, type: .error,
                   String(describing: h.colorID))
            throw Error.unsupportedColor
        }
        guard frameIndex >= 0 && frameIndex < h.frameCount else {
            os_log("SerFrameLoader: frame index %d out of range [0, %d)", log: log, type: .error,
                   frameIndex, h.frameCount)
            throw Error.decodeFailed
        }

        let isBayer = h.colorID.isBayer
        let isRGB = h.colorID.isRGB
        let mono16 = h.bytesPerPlane == 2 && !isRGB   // RGB v0 is 8-bit only

        // Destination — same format as ImageTexture.load output.
        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: h.imageWidth, height: h.imageHeight, mipmapped: false
        )
        dstDesc.storageMode = .private
        dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let dst = device.makeTexture(descriptor: dstDesc) else {
            os_log("SerFrameLoader: rgba16Float dst allocation failed (%dx%d ≈ %d MB)",
                   log: log, type: .error, h.imageWidth, h.imageHeight,
                   (h.imageWidth * h.imageHeight * 8) / (1024 * 1024))
            throw Error.destTextureFailed(width: h.imageWidth, height: h.imageHeight)
        }

        // Pick the right unpack kernel based on colour layout.
        // RGB / BGR uses an MTLBuffer source (3 bytes per pixel — Metal has
        // no .rgb8Unorm texture format); mono / bayer use a texture source.
        let kernelName: String
        if isRGB {
            kernelName = "unpack_rgb8_to_rgba"
        } else if isBayer {
            kernelName = mono16 ? "unpack_bayer16_to_rgba" : "unpack_bayer8_to_rgba"
        } else {
            kernelName = mono16 ? "unpack_mono16_to_rgba" : "unpack_mono8_to_rgba"
        }
        guard let lib = MetalDevice.shared.library else {
            os_log("SerFrameLoader: Metal library missing", log: log, type: .error)
            throw Error.kernelMissing(kernelName)
        }
        guard let fn = lib.makeFunction(name: kernelName) else {
            os_log("SerFrameLoader: kernel function %{public}@ not found", log: log, type: .error, kernelName)
            throw Error.kernelMissing(kernelName)
        }
        let pso: MTLComputePipelineState
        do {
            pso = try device.makeComputePipelineState(function: fn)
        } catch {
            os_log("SerFrameLoader: PSO build for %{public}@ failed: %{public}@",
                   log: log, type: .error, kernelName, String(describing: error))
            throw Error.kernelMissing(kernelName)
        }
        guard let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else {
            os_log("SerFrameLoader: command buffer / encoder unavailable", log: log, type: .error)
            throw Error.commandBufferMissing
        }

        enc.setComputePipelineState(pso)

        // Path A — RGB / BGR: MTLBuffer source + dst texture.
        if isRGB {
            // 3 bytes per pixel — copy the raw frame bytes into a shared
            // MTLBuffer the kernel reads via `device const uchar*`.
            let frameBytes = h.imageWidth * h.imageHeight * 3
            guard let buffer = device.makeBuffer(length: frameBytes, options: [.storageModeShared]) else {
                os_log("SerFrameLoader: RGB MTLBuffer allocation failed (%d bytes)",
                       log: log, type: .error, frameBytes)
                throw Error.stagingTextureFailed(width: h.imageWidth, height: h.imageHeight)
            }
            reader.withFrameBytes(at: frameIndex) { ptr, _ in
                memcpy(buffer.contents(), ptr, frameBytes)
            }
            // RgbUnpackParams: scale, flip, swapRB, width.
            var p: (Float, UInt32, UInt32, UInt32) = (
                1.0 / 255.0,
                0,
                h.colorID == .bgr ? 1 : 0,
                UInt32(h.imageWidth)
            )
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setTexture(dst, index: 0)
            enc.setBytes(&p, length: MemoryLayout<(Float, UInt32, UInt32, UInt32)>.stride, index: 1)
        } else {
            // Path B — mono / Bayer: staging texture source + dst texture.
            let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: mono16 ? .r16Uint : .r8Unorm,
                width: h.imageWidth, height: h.imageHeight, mipmapped: false
            )
            stageDesc.storageMode = .shared
            stageDesc.usage = [.shaderRead]
            guard let staging = device.makeTexture(descriptor: stageDesc) else {
                os_log("SerFrameLoader: staging texture allocation failed (%dx%d, mono16=%{public}@)",
                       log: log, type: .error, h.imageWidth, h.imageHeight, mono16 ? "true" : "false")
                throw Error.stagingTextureFailed(width: h.imageWidth, height: h.imageHeight)
            }
            reader.withFrameBytes(at: frameIndex) { ptr, _ in
                staging.replace(
                    region: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: h.imageWidth, height: h.imageHeight, depth: 1)
                    ),
                    mipmapLevel: 0,
                    withBytes: ptr,
                    bytesPerRow: h.imageWidth * h.bytesPerPlane
                )
            }
            if isBayer {
                var p: (Float, UInt32, UInt32) = (
                    mono16 ? 1.0 / 65535.0 : 1.0,
                    0,
                    h.colorID.bayerPatternIndex
                )
                enc.setBytes(&p, length: MemoryLayout<(Float, UInt32, UInt32)>.stride, index: 0)
            } else {
                var paramBuf: (Float, UInt32) = (mono16 ? 1.0 / 65535.0 : 1.0, 0)
                enc.setBytes(&paramBuf, length: MemoryLayout<(Float, UInt32)>.stride, index: 0)
            }
            enc.setTexture(staging, index: 0)
            enc.setTexture(dst, index: 1)
        }
        let tgw = pso.threadExecutionWidth
        let tgh = pso.maxTotalThreadsPerThreadgroup / tgw
        let tgSize = MTLSize(width: tgw, height: tgh, depth: 1)
        let tgCount = MTLSize(
            width: (h.imageWidth + tgw - 1) / tgw,
            height: (h.imageHeight + tgh - 1) / tgh,
            depth: 1
        )
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return dst
    }
}
