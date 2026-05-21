// Pre-sharpen highlight suppression (LSW 3.1.3 parity).
//
// Soft-clips the brightest features of an image before the downstream
// sharpening / deconvolution stage runs. Wiener deconv restores high-
// frequency energy on the existing distribution — when bright peaks
// are already near 1.0 (e.g. Jupiter's polar regions on a freshly
// stacked frame), Wiener pushes them past 1.0 and the subsequent
// applyOutputRemap clamps a flat plateau onto the saved file. This
// pass rolls the brightest 5-15% off below the ceiling so Wiener has
// headroom to add high-frequency content without saturating.
//
// Hue-preserving by construction: the curve runs on Rec. 709 luma and
// the per-pixel scale factor is applied to all three channels.
//
// Auto-engagement: callers check `shouldEngage(percentiles:)` before
// dispatching. The kernel itself is a no-op for pixels at or below the
// knee, so running it unconditionally is correct but wastes a Metal
// dispatch; the auto-engage gate keeps the cost-free fast path on
// already-well-exposed input.
//
// Empirical bracket (BiggSky Jupiter SERs, 2026-05-21): default
// knee=0.85 picks up the polar overexposure on the bare stack and
// fixes the saved file without dimming the visible mid-band detail.
// Below knee=0.80 the disc starts to look hazy; above knee=0.92 the
// polar clipping persists. Auto-engage threshold p99 ≥ 0.98 picks up
// only the cases where the bare stack is genuinely about-to-clip.
import Foundation
import Metal

enum HighlightSuppression {

    /// Pure-Swift compression curve. Exposed for unit tests so the
    /// math is verifiable without spinning up a Metal device. The
    /// kernel in Shaders.metal computes exactly this for every pixel
    /// (with the per-channel scale-by-luma-ratio dressing on top).
    static func compress(_ L: Float, knee: Float) -> Float {
        if L <= knee || L < 1e-4 { return L }
        let head = 1.0 - knee
        return knee + head * tanh((L - knee) / head)
    }

    /// Auto-engagement heuristic. Returns true when the input
    /// histogram has bright pixels close enough to clipping that the
    /// downstream sharpener would push them over.
    /// Threshold 0.98 picks up genuine pre-clipping highlights without
    /// triggering on well-exposed lunar / solar frames whose p99 sits
    /// in the 0.85-0.95 range.
    static func shouldEngage(highlightP99: Float) -> Bool {
        return highlightP99 >= 0.98
    }

    /// Apply the suppression curve to `input` using the kernel inside
    /// `Pipeline`. Returns a new caller-owned texture (matching the
    /// input's pixel format) when the curve fires; returns `input` as-is
    /// when `knee >= 1.0` (caller already opted out) so callers can do
    /// `current = HighlightSuppression.apply(...) ?? current` without a
    /// guard.
    ///
    /// Caller decides whether to engage — the helper does NOT probe
    /// percentiles itself because the LuckyStack post-pass already
    /// computes the percentile distribution for `applyOutputRemap` a
    /// few lines later and we don't want to pay that cost twice.
    static func apply(
        input: MTLTexture,
        knee: Float,
        pipeline: Pipeline,
        device: MTLDevice
    ) -> MTLTexture? {
        // Sanity: knee outside [0.5, 0.99] means the user opted out
        // (knee = 1.0) or supplied a degenerate value. Pass-through.
        guard knee >= 0.5, knee < 1.0 else { return nil }

        let W = input.width
        let H = input.height
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat, width: W, height: H, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .private
        guard let output = device.makeTexture(descriptor: outDesc) else { return nil }

        let queue = MetalDevice.shared.commandQueue
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        let pso = pipeline.suppressHighlightsPipeline
        enc.setComputePipelineState(pso)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        struct Params { var knee: Float }
        var p = Params(knee: knee)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let tgw = pso.threadExecutionWidth
        let tgh = pso.maxTotalThreadsPerThreadgroup / tgw
        let threadsPerTG = MTLSize(width: tgw, height: tgh, depth: 1)
        let groups = MTLSize(
            width:  (W + tgw - 1) / tgw,
            height: (H + tgh - 1) / tgh,
            depth: 1
        )
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerTG)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return output
    }
}
