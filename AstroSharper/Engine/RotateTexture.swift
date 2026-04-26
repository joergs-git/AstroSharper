// 180° in-place rotation helper. Allocates a destination texture, dispatches
// the GPU rotation kernel, returns the rotated texture. Used to apply a
// meridian-flip flag at texture load time so the rest of the pipeline never
// has to think about orientation.
import Metal

enum RotateTexture {
    private static let cache = TextureCache()

    /// Returns a new private-storage texture containing `src` rotated 180°.
    /// Caller owns the returned texture.
    static func rotate180(_ src: MTLTexture, device: MTLDevice) -> MTLTexture {
        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: src.pixelFormat,
            width: src.width, height: src.height, mipmapped: false
        )
        dstDesc.storageMode = .private
        dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let dst = device.makeTexture(descriptor: dstDesc) else { return src }
        guard let pso = cache.rotate180(device: device),
              let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return src }
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        let tgw = pso.threadExecutionWidth
        let tgh = pso.maxTotalThreadsPerThreadgroup / tgw
        enc.dispatchThreadgroups(
            MTLSize(width: (src.width + tgw - 1) / tgw, height: (src.height + tgh - 1) / tgh, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgw, height: tgh, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return dst
    }
}

/// Tiny pipeline-state cache so we only build the rotate kernel once.
final class TextureCache {
    private var pso: MTLComputePipelineState?

    func rotate180(device: MTLDevice) -> MTLComputePipelineState? {
        if let pso { return pso }
        guard let lib = MetalDevice.shared.library,
              let fn = lib.makeFunction(name: "rotate_180"),
              let p = try? device.makeComputePipelineState(function: fn)
        else { return nil }
        pso = p
        return p
    }
}
