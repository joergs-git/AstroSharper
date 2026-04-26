// Non-blind Lucy-Richardson deconvolution with a Gaussian PSF.
//
// Iteration (gaussian PSF is symmetric so no flip is needed for the correction):
//     conv     = gauss(estimate)          (MPS Gaussian blur)
//     ratio    = observed / max(conv, eps)
//     corr     = gauss(ratio)
//     estimate = estimate * corr
import Metal
import MetalPerformanceShaders

enum Deconvolve {
    static func run(
        input: MTLTexture,
        output: MTLTexture,
        sigma: Float,
        iterations: Int,
        pipeline: Pipeline,
        commandBuffer: MTLCommandBuffer,
        borrowed: inout [MTLTexture]
    ) {
        let device = pipeline.device
        let w = input.width, h = input.height
        let fmt = input.pixelFormat

        let observed = input
        // We ping-pong between estimateA and estimateB. All temporaries are
        // registered with the caller so they're recycled only after GPU done.
        let estimateA = pipeline.borrow(width: w, height: h, format: fmt)
        let estimateB = pipeline.borrow(width: w, height: h, format: fmt)
        let convolved = pipeline.borrow(width: w, height: h, format: fmt)
        let ratio     = pipeline.borrow(width: w, height: h, format: fmt)
        let correction = pipeline.borrow(width: w, height: h, format: fmt)
        borrowed.append(contentsOf: [estimateA, estimateB, convolved, ratio, correction])

        // Initialize estimateA = observed (blit).
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: observed, to: estimateA)
            blit.endEncoding()
        }

        let gauss = MPSImageGaussianBlur(device: device, sigma: sigma)

        var src = estimateA
        var dst = estimateB

        for _ in 0..<max(1, iterations) {
            // convolved = gauss(src)
            gauss.encode(commandBuffer: commandBuffer, sourceTexture: src, destinationTexture: convolved)

            // ratio = observed / convolved
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline.dividePipeline)
                enc.setTexture(observed, index: 0)
                enc.setTexture(convolved, index: 1)
                enc.setTexture(ratio, index: 2)
                let (tgC, tgS) = dispatchThreadgroups(for: ratio, pso: pipeline.dividePipeline)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }

            // correction = gauss(ratio)
            gauss.encode(commandBuffer: commandBuffer, sourceTexture: ratio, destinationTexture: correction)

            // dst = src * correction
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline.multiplyPipeline)
                enc.setTexture(src, index: 0)
                enc.setTexture(correction, index: 1)
                enc.setTexture(dst, index: 2)
                let (tgC, tgS) = dispatchThreadgroups(for: dst, pso: pipeline.multiplyPipeline)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }

            swap(&src, &dst)
        }

        // Final result is in `src`. Blit into caller's output.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: src, to: output)
            blit.endEncoding()
        }
    }
}
