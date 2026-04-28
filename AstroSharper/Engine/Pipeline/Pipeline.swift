// Top-level processing pipeline: takes an input texture + settings and produces
// a processed texture. Operations are applied in a fixed order that matches
// the conceptual model: (stabilization, handled outside) → L-R → Unsharp → Tone.
// Each step checks its own "enabled" flag.
//
// Textures are allocated from a small pool keyed by (w, h, format) to avoid
// reallocating on every preview update.
import Metal
import MetalPerformanceShaders

final class Pipeline {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // Compute pipelines (lazily built).
    private lazy var unsharpPSO = makeComputePSO(function: "unsharp_mask")
    private lazy var divPSO     = makeComputePSO(function: "lr_divide")
    private lazy var mulPSO     = makeComputePSO(function: "lr_multiply")
    private lazy var tonePSO    = makeComputePSO(function: "apply_tone_curve")
    private lazy var satPSO     = makeComputePSO(function: "apply_saturation")
    private lazy var nrPSO      = makeComputePSO(function: "noise_reduce_bilateral")
    private lazy var wbPSO      = makeComputePSO(function: "apply_white_balance")
    private lazy var acdcPSO    = makeComputePSO(function: "shift_rb_channels")
    private lazy var bcPSO      = makeComputePSO(function: "apply_brightness_contrast")
    private lazy var shiftPSO   = makeComputePSO(function: "sub_pixel_shift")
    private lazy var stackPSO   = makeComputePSO(function: "stack_accumulate")
    private lazy var subPSO     = makeComputePSO(function: "subtract_textures")
    private lazy var waddPSO    = makeComputePSO(function: "weighted_add")

    // Texture pool (per pipeline instance). Protected by `poolLock` since
    // process() may run on a background queue while other code paths also
    // touch the pool.
    private var pool: [TextureKey: [MTLTexture]] = [:]
    private let poolLock = NSLock()

    struct TextureKey: Hashable { let w: Int; let h: Int; let format: Int }

    init() {
        self.device = MetalDevice.shared.device
        self.commandQueue = MetalDevice.shared.commandQueue
        guard let lib = MetalDevice.shared.library else {
            fatalError("AstroSharper: default Metal library missing — is Shaders.metal in the target?")
        }
        self.library = lib
    }

    private func makeComputePSO(function name: String) -> MTLComputePipelineState {
        guard let fn = library.makeFunction(name: name) else {
            fatalError("AstroSharper: Metal function '\(name)' not found")
        }
        return try! device.makeComputePipelineState(function: fn)
    }

    // MARK: - Texture pool

    func borrow(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float) -> MTLTexture {
        let key = TextureKey(w: width, h: height, format: Int(format.rawValue))
        poolLock.lock()
        if var stack = pool[key], let tex = stack.popLast() {
            pool[key] = stack
            poolLock.unlock()
            return tex
        }
        poolLock.unlock()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)!
    }

    func recycle(_ tex: MTLTexture) {
        let key = TextureKey(w: tex.width, h: tex.height, format: Int(tex.pixelFormat.rawValue))
        poolLock.lock()
        pool[key, default: []].append(tex)
        poolLock.unlock()
    }

    // MARK: - Main entry

    /// Process `input` with `settings`, return new texture with the result.
    /// Caller owns the returned texture (not from the pool).
    func process(
        input: MTLTexture,
        sharpen: SharpenSettings,
        toneCurve: ToneCurveSettings,
        toneCurveLUT: MTLTexture? = nil
    ) -> MTLTexture {
        let w = input.width
        let h = input.height

        // Identity short-circuit: when nothing in the pipeline is enabled,
        // skip the entire alloc + GPU dispatch and just hand back a copy
        // of the input. Live preview hits this every file scrub when the
        // user has no panels active; without the early return the user
        // saw a brief 'blink' as Pipeline.process completed and replaced
        // the freshly-painted raw frame with a re-drawn-equal copy.
        let bcIsIdentity = abs(toneCurve.brightness) < 1e-4 && abs(toneCurve.contrast - 1.0) < 1e-4
        let satIsIdentity = abs(toneCurve.saturation - 1.0) < 1e-4
        let nothingActive = !toneCurve.autoWB
            && !toneCurve.chromaticAlignment
            && !sharpen.enabled
            && (!toneCurve.enabled || (toneCurveLUT == nil && bcIsIdentity && satIsIdentity))
        // Allocate a persistent output — not from pool, caller owns.
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat, width: w, height: h, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .private
        let output = device.makeTexture(descriptor: outDesc)!

        if nothingActive {
            return copyTexture(input, into: output)
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return copyTexture(input, into: output) }

        // Working texture threaded through the pipeline. All borrowed
        // temporaries are collected into `borrowed` and recycled in a single
        // pass AFTER the GPU has finished with them. Recycling mid-pipeline
        // is unsafe — the command buffer still references those textures.
        var current: MTLTexture = input
        var borrowed: [MTLTexture] = []

        // Step 0: Auto white balance (gray-world). MUST run BEFORE any
        // sharpen step because sharpen amplifies channel imbalance into
        // coloured halos. On mono / pre-balanced sources the gray-world
        // correction collapses to identity (all three channels share the
        // same statistics) so this is a no-op there.
        if toneCurve.autoWB {
            let wb = computeAutoWB(input: current)
            if wb != .identity {
                let result = borrow(width: w, height: h, format: input.pixelFormat)
                borrowed.append(result)
                if let enc = cmdBuf.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(wbPSO)
                    enc.setTexture(current, index: 0)
                    enc.setTexture(result, index: 1)
                    var p = WhiteBalanceParamsCPU(
                        offsets: SIMD3<Float>(wb.redOffset,  wb.greenOffset, wb.blueOffset),
                        scales:  SIMD3<Float>(wb.redScale,   wb.greenScale,  wb.blueScale)
                    )
                    enc.setBytes(&p, length: MemoryLayout<WhiteBalanceParamsCPU>.stride, index: 0)
                    let (tgC, tgS) = dispatchThreadgroups(for: result, pso: wbPSO)
                    enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                    enc.endEncoding()
                }
                current = result
            }
        }

        // Step 0.5: Atmospheric chromatic dispersion correction (Path A).
        // Runs AFTER WB so per-channel statistics are normalised before
        // the alignment search. Phase-correlates R/G and B/G on a 256×256
        // downsample of the current texture; applies sub-pixel shifts to
        // R and B (G stays anchored). On mono / pre-aligned sources both
        // offsets come out near zero and the GPU pass is skipped.
        if toneCurve.chromaticAlignment {
            let offsets = ChromaticDispersion.compute(
                input: current, device: device, commandQueue: commandQueue
            )
            if !offsets.isIdentity() {
                let result = borrow(width: w, height: h, format: input.pixelFormat)
                borrowed.append(result)
                if let enc = cmdBuf.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(acdcPSO)
                    enc.setTexture(current, index: 0)
                    enc.setTexture(result, index: 1)
                    var p = ChannelShiftParamsCPU(
                        redOffset:  offsets.red,
                        blueOffset: offsets.blue
                    )
                    enc.setBytes(&p, length: MemoryLayout<ChannelShiftParamsCPU>.stride, index: 0)
                    let (tgC, tgS) = dispatchThreadgroups(for: result, pso: acdcPSO)
                    enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                    enc.endEncoding()
                }
                current = result
            }
        }

        // Step 1: L-R deconvolution
        if sharpen.enabled && sharpen.lrEnabled {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            Deconvolve.run(
                input: current, output: result,
                sigma: Float(sharpen.lrSigma),
                iterations: sharpen.lrIterations,
                pipeline: self, commandBuffer: cmdBuf,
                borrowed: &borrowed
            )
            current = result
        }

        // Step 2: Wavelet sharpening (à-trous)
        if sharpen.enabled && sharpen.waveletEnabled {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            Wavelet.sharpen(
                input: current, output: result,
                amounts: sharpen.waveletScales.map { Float($0) },
                baseSigma: 1.0,
                noiseThreshold: Float(sharpen.waveletNoiseThreshold),
                pipeline: self, commandBuffer: cmdBuf,
                borrowed: &borrowed
            )
            current = result
        }

        // Step 3: Unsharp mask
        if sharpen.enabled && sharpen.unsharpEnabled {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            Sharpen.unsharpMask(
                input: current, output: result,
                sigma: Float(sharpen.radius),
                amount: Float(sharpen.amount),
                adaptive: sharpen.adaptive,
                pipeline: self, commandBuffer: cmdBuf,
                borrowed: &borrowed
            )
            current = result
        }

        // Wiener is a CPU-FFT stage; it manages its own command buffer + sync
        // internally. We need to flush all GPU work that wrote into `current`
        // before Wiener reads it, so commit + wait once here.
        let needsWiener = sharpen.enabled && sharpen.wienerEnabled
        if needsWiener {
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            Wiener.deconvolve(
                input: current, output: result,
                sigma: Float(sharpen.wienerSigma),
                snr: Float(sharpen.wienerSNR),
                device: device
            )
            current = result
        }

        // Tone curve runs on a fresh command buffer if Wiener already
        // committed the previous one.
        let cmdBuf2 = needsWiener ? commandQueue.makeCommandBuffer() : cmdBuf
        guard let finalCmd = cmdBuf2 else { return copyTexture(input, into: output) }

        // Noise reduction — bilateral filter, runs AFTER all sharpening
        // and BEFORE tone-curve / saturation. The sharpen chain inevitably
        // amplifies high-frequency residual stacking noise; bilateral
        // smoothing knocks the noise floor back down without un-doing the
        // visible detail because edge-aware weights skip jumps across
        // band boundaries.
        if sharpen.enabled, sharpen.nrEnabled {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            if let enc = finalCmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(nrPSO)
                enc.setTexture(current, index: 0)
                enc.setTexture(result, index: 1)
                var p = NoiseReduceParamsCPU(
                    spatialSigma: Float(sharpen.nrSpatial),
                    rangeSigma:   Float(sharpen.nrRange),
                    radius:       Int32(max(1, min(6, sharpen.nrRadius)))
                )
                enc.setBytes(&p, length: MemoryLayout<NoiseReduceParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: result, pso: nrPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            current = result
        }

        if toneCurve.enabled, let lut = toneCurveLUT {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            ToneCurveApply.run(
                input: current, lut: lut, output: result,
                pipeline: self, commandBuffer: finalCmd
            )
            current = result
        }

        // Brightness + contrast — independent of the tone-curve sub-step
        // (fires whenever the values aren't identity, regardless of the
        // curve toggle). Runs AFTER the curve so it operates on the
        // user's curve-mapped values, BEFORE saturation so saturation
        // sees the final luminance the user dialled in. (`bcIsIdentity`
        // is computed earlier as part of the nothing-active guard.)
        if toneCurve.enabled, !bcIsIdentity {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            if let enc = finalCmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(bcPSO)
                enc.setTexture(current, index: 0)
                enc.setTexture(result, index: 1)
                var p = BrightnessContrastParamsCPU(
                    brightness: Float(toneCurve.brightness),
                    contrast:   Float(toneCurve.contrast)
                )
                enc.setBytes(&p, length: MemoryLayout<BrightnessContrastParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: result, pso: bcPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            current = result
        }

        // Saturation runs even when the tone-curve sub-section is off — it's
        // an independent control on the same panel. Skipped at identity (1.0)
        // so the no-op case costs nothing. Always last in the chain so it
        // operates on the final RGB the user will see.
        if toneCurve.enabled, abs(toneCurve.saturation - 1.0) > 1e-4 {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            if let enc = finalCmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(satPSO)
                enc.setTexture(current, index: 0)
                enc.setTexture(result, index: 1)
                var p = SaturationParamsCPU(saturation: Float(toneCurve.saturation))
                enc.setBytes(&p, length: MemoryLayout<SaturationParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: result, pso: satPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            current = result
        }

        if let blit = finalCmd.makeBlitCommandEncoder() {
            blit.copy(from: current, to: output)
            blit.endEncoding()
        }
        finalCmd.commit()
        finalCmd.waitUntilCompleted()

        for tex in borrowed { recycle(tex) }
        return output
    }

    // MARK: - Helpers

    /// Compute a gray-world white-balance correction for `input`. Downsamples
    /// to a small staging texture (256-ish along the longest side), reads
    /// back to CPU, and reuses the existing `WhiteBalance.computeGrayWorld`
    /// math. Cost is dominated by the sync GPU→CPU readback (~1 ms on the
    /// downsampled buffer); cheap enough to do on every Pipeline.process
    /// call, which the live preview triggers on every frame change.
    private func computeAutoWB(input: MTLTexture) -> WhiteBalanceCorrection {
        let w = input.width, h = input.height
        guard w > 0, h > 0 else { return .identity }

        // Downsample target along the longest edge. 256 is enough for the
        // gray-world stats — we just want per-channel mean of mid-range
        // pixels.
        let targetMax = 256
        let scale = max(1, max(w, h) / targetMax)
        let dwsW = max(1, w / scale)
        let dwsH = max(1, h / scale)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: dwsW, height: dwsH, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        guard let staging = device.makeTexture(descriptor: desc),
              let cmd = commandQueue.makeCommandBuffer() else {
            return .identity
        }

        let scaler = MPSImageBilinearScale(device: device)
        var transform = MPSScaleTransform(
            scaleX: Double(dwsW) / Double(w),
            scaleY: Double(dwsH) / Double(h),
            translateX: 0, translateY: 0
        )
        withUnsafePointer(to: &transform) { ptr in
            scaler.scaleTransform = ptr
            scaler.encode(commandBuffer: cmd, sourceTexture: input, destinationTexture: staging)
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        let pixelCount = dwsW * dwsH
        var rgba = [Float](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBufferPointer { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: dwsW * MemoryLayout<Float>.size * 4,
                from: MTLRegionMake2D(0, 0, dwsW, dwsH),
                mipmapLevel: 0
            )
        }

        var red   = [Float](repeating: 0, count: pixelCount)
        var green = [Float](repeating: 0, count: pixelCount)
        var blue  = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            red[i]   = rgba[i * 4 + 0]
            green[i] = rgba[i * 4 + 1]
            blue[i]  = rgba[i * 4 + 2]
        }

        return WhiteBalance.computeGrayWorld(
            red: red, green: green, blue: blue,
            width: dwsW, height: dwsH,
            reference: .green,
            backgroundPercentile: 0.05
        )
    }

    @discardableResult
    private func copyTexture(_ src: MTLTexture, into dst: MTLTexture) -> MTLTexture {
        if let cmd = commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: src, to: dst)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return dst
    }

    // Pipeline-state accessors for Operation helpers.
    var unsharpPipeline: MTLComputePipelineState { unsharpPSO }
    var dividePipeline: MTLComputePipelineState { divPSO }
    var multiplyPipeline: MTLComputePipelineState { mulPSO }
    var tonePipeline: MTLComputePipelineState { tonePSO }
    var shiftPipeline: MTLComputePipelineState { shiftPSO }
    var stackPipeline: MTLComputePipelineState { stackPSO }
    var subtractPipeline: MTLComputePipelineState { subPSO }
    var waddPipeline: MTLComputePipelineState { waddPSO }
}

/// Mirror of the Metal `SaturationParams` struct; sent via `setBytes`.
struct SaturationParamsCPU {
    var saturation: Float
}

/// Mirror of the Metal `NoiseReduceParams` struct (struct field layout
/// must match the Metal definition exactly).
struct NoiseReduceParamsCPU {
    var spatialSigma: Float
    var rangeSigma: Float
    var radius: Int32
}

/// Mirror of the Metal `WhiteBalanceParams` struct. Metal `float3` is
/// 16-byte aligned (sizeof = 16); Swift `SIMD3<Float>` matches that
/// layout exactly so a setBytes copy lands the right bits in the right
/// slots.
struct WhiteBalanceParamsCPU {
    var offsets: SIMD3<Float>
    var scales: SIMD3<Float>
}

/// Mirror of the Metal `ChannelShiftParams` struct (two float2 = 16 bytes).
struct ChannelShiftParamsCPU {
    var redOffset:  SIMD2<Float>
    var blueOffset: SIMD2<Float>
}

/// Mirror of the Metal `BrightnessContrastParams` struct.
struct BrightnessContrastParamsCPU {
    var brightness: Float
    var contrast: Float
}

// Utility for dispatch sizing.
func dispatchThreadgroups(for texture: MTLTexture, pso: MTLComputePipelineState) -> (MTLSize, MTLSize) {
    let w = pso.threadExecutionWidth
    let h = pso.maxTotalThreadsPerThreadgroup / w
    let tgSize = MTLSize(width: w, height: h, depth: 1)
    let tgCount = MTLSize(
        width: (texture.width + w - 1) / w,
        height: (texture.height + h - 1) / h,
        depth: 1
    )
    return (tgCount, tgSize)
}
