// Unsharp-mask sharpening: blur the input with a Gaussian (via MPS), then the
// `unsharp_mask` kernel computes `output = input + amount * (input - blurred)`,
// optionally modulated by local luminance (adaptive mode).
import Metal
import MetalPerformanceShaders

enum Sharpen {
    private struct UnsharpParams {
        var amount: Float
        var adaptiveMin: Float
        var adaptiveMax: Float
        var adaptive: UInt32
    }

    static func unsharpMask(
        input: MTLTexture,
        output: MTLTexture,
        sigma: Float,
        amount: Float,
        adaptive: Bool,
        pipeline: Pipeline,
        commandBuffer: MTLCommandBuffer,
        borrowed: inout [MTLTexture]
    ) {
        let device = pipeline.device
        // Temporaries get appended to `borrowed` and are recycled by the caller
        // after the command buffer has completed — never before.
        let blurred = pipeline.borrow(width: input.width, height: input.height, format: input.pixelFormat)
        borrowed.append(blurred)

        let gauss = MPSImageGaussianBlur(device: device, sigma: sigma)
        gauss.encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: blurred)

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline.unsharpPipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(blurred, index: 1)
        enc.setTexture(output, index: 2)

        var params = UnsharpParams(
            amount: amount,
            adaptiveMin: 0.05,
            adaptiveMax: 0.50,
            adaptive: adaptive ? 1 : 0
        )
        enc.setBytes(&params, length: MemoryLayout<UnsharpParams>.stride, index: 0)

        let (tgCount, tgSize) = dispatchThreadgroups(for: output, pso: pipeline.unsharpPipeline)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
    }
}
