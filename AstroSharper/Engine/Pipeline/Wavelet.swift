// À-trous (starlet) wavelet sharpening — the standard workflow for
// planetary and solar imaging after stacking. Produces smoother, more
// natural-looking sharpening than a single-scale unsharp mask because detail
// is enhanced per frequency band instead of indiscriminately.
//
// Algorithm for N scales (we use 4 — sigmas 1, 2, 4, 8 is a classic choice):
//   c_0 = input
//   For i in 0..<N:
//     c_{i+1} = gauss(c_i, sigma = 2^i * sigma0)
//     layer_i = c_i - c_{i+1}              // band-pass at this scale
//   result = c_N + Σ amount_i * layer_i    // start from the residual and add
//                                            // each scale back with boost
//
// With amounts = [1,1,1,1] the result equals the input (perfect reconstruction).
// Raising amount_i > 1 boosts detail at that scale.
import Metal
import MetalPerformanceShaders

enum Wavelet {
    private struct AddParams { var amount: Float }

    static func sharpen(
        input: MTLTexture,
        output: MTLTexture,
        amounts: [Float],
        baseSigma: Float,
        pipeline: Pipeline,
        commandBuffer: MTLCommandBuffer,
        borrowed: inout [MTLTexture]
    ) {
        let device = pipeline.device
        let w = input.width, h = input.height
        let fmt = input.pixelFormat

        let scales = max(1, min(amounts.count, 6))
        let coarse0 = pipeline.borrow(width: w, height: h, format: fmt)
        borrowed.append(coarse0)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: input, to: coarse0)
            blit.endEncoding()
        }

        var coarses: [MTLTexture] = [coarse0]
        var layers: [MTLTexture] = []

        // Build the pyramid.
        for i in 0..<scales {
            let sigma = baseSigma * powf(2.0, Float(i))
            let gauss = MPSImageGaussianBlur(device: device, sigma: sigma)
            let nextCoarse = pipeline.borrow(width: w, height: h, format: fmt)
            let layer = pipeline.borrow(width: w, height: h, format: fmt)
            borrowed.append(nextCoarse)
            borrowed.append(layer)

            // next = gauss(current)
            gauss.encode(commandBuffer: commandBuffer, sourceTexture: coarses.last!, destinationTexture: nextCoarse)

            // layer_i = current - next
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline.subtractPipeline)
                enc.setTexture(coarses.last!, index: 0)
                enc.setTexture(nextCoarse, index: 1)
                enc.setTexture(layer, index: 2)
                let (tgC, tgS) = dispatchThreadgroups(for: layer, pso: pipeline.subtractPipeline)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }

            coarses.append(nextCoarse)
            layers.append(layer)
        }

        // Initial reconstruction = the final coarse residual.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: coarses.last!, to: output)
            blit.endEncoding()
        }

        // Add each layer with its own amount — read-write on `output`.
        for (i, layer) in layers.enumerated() {
            var params = AddParams(amount: amounts[i])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline.waddPipeline)
                enc.setTexture(layer, index: 0)
                enc.setTexture(output, index: 1)
                enc.setBytes(&params, length: MemoryLayout<AddParams>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: output, pso: pipeline.waddPipeline)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
        }
    }
}
