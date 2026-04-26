// Decode a single SER frame into a Metal texture, pipeline-ready (rgba16Float).
//
// Used by the preview view when the user selects a `.ser` row in the file
// list, so they see frame 0 immediately and can adjust sharpening / tone
// against it before kicking off the full lucky-stack run.
import Metal

enum SerFrameLoader {
    enum Error: Swift.Error {
        case unsupportedColor
        case decodeFailed
    }

    /// Returns a private-storage rgba16Float texture containing frame `index`
    /// of the SER at `url`. Supports mono 8/16 and 4 Bayer patterns
    /// (RGGB / GRBG / GBRG / BGGR) at 8/16 bit. Bayer is bilinearly
    /// demosaiced on the GPU during unpack.
    static func loadFrame(url: URL, frameIndex: Int = 0, device: MTLDevice) throws -> MTLTexture {
        let reader = try SerReader(url: url)
        let h = reader.header
        guard h.colorID.isMono || h.colorID.isBayer else { throw Error.unsupportedColor }
        guard frameIndex >= 0 && frameIndex < h.frameCount else { throw Error.decodeFailed }

        let mono16 = h.bytesPerPlane == 2

        // Staging texture (shared) gets a memcpy of the raw frame bytes.
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mono16 ? .r16Uint : .r8Unorm,
            width: h.imageWidth, height: h.imageHeight, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stageDesc) else { throw Error.decodeFailed }

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

        // Destination — same format as ImageTexture.load output.
        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: h.imageWidth, height: h.imageHeight, mipmapped: false
        )
        dstDesc.storageMode = .private
        dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let dst = device.makeTexture(descriptor: dstDesc) else { throw Error.decodeFailed }

        // Pick the right unpack kernel based on colour layout.
        let isBayer = h.colorID.isBayer
        let kernelName: String
        if isBayer {
            kernelName = mono16 ? "unpack_bayer16_to_rgba" : "unpack_bayer8_to_rgba"
        } else {
            kernelName = mono16 ? "unpack_mono16_to_rgba" : "unpack_mono8_to_rgba"
        }
        guard let lib = MetalDevice.shared.library,
              let fn = lib.makeFunction(name: kernelName),
              let pso = try? device.makeComputePipelineState(function: fn),
              let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { throw Error.decodeFailed }

        enc.setComputePipelineState(pso)
        if isBayer {
            // BayerUnpackParams: scale + flip + pattern.
            var p: (Float, UInt32, UInt32) = (
                mono16 ? 1.0 / 65535.0 : 1.0,
                0,
                h.colorID.bayerPatternIndex
            )
            enc.setBytes(&p, length: MemoryLayout<(Float, UInt32, UInt32)>.stride, index: 0)
        } else {
            // SerUnpackParams: scale + flip.
            var paramBuf: (Float, UInt32) = (mono16 ? 1.0 / 65535.0 : 1.0, 0)
            enc.setBytes(&paramBuf, length: MemoryLayout<(Float, UInt32)>.stride, index: 0)
        }
        enc.setTexture(staging, index: 0)
        enc.setTexture(dst, index: 1)
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
