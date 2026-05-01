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

    // Compute pipelines — eagerly built in init() so the ~80 ms one-time
    // compilation cost of these 14 kernels doesn't land on the user's
    // first slider drag. Building all PSOs upfront moves the hiccup into
    // app launch (where a SwiftUI splash already covers it) and gives a
    // smooth-from-tick-zero live preview.
    private let unsharpPSO: MTLComputePipelineState
    private let divPSO:     MTLComputePipelineState
    private let mulPSO:     MTLComputePipelineState
    private let tonePSO:    MTLComputePipelineState
    private let satPSO:     MTLComputePipelineState
    private let nrPSO:      MTLComputePipelineState
    private let wbPSO:      MTLComputePipelineState
    private let acdcPSO:    MTLComputePipelineState
    private let stretchPSO: MTLComputePipelineState
    private let bcPSO:      MTLComputePipelineState
    private let hsPSO:      MTLComputePipelineState     // highlights / shadows
    private let shiftPSO:   MTLComputePipelineState
    private let stackPSO:   MTLComputePipelineState
    private let subPSO:     MTLComputePipelineState
    private let waddPSO:    MTLComputePipelineState

    // Texture pool (per pipeline instance). Protected by `poolLock` since
    // process() may run on a background queue while other code paths also
    // touch the pool.
    private var pool: [TextureKey: [MTLTexture]] = [:]
    private let poolLock = NSLock()

    struct TextureKey: Hashable { let w: Int; let h: Int; let format: Int }

    init() {
        let dev = MetalDevice.shared.device
        self.device = dev
        self.commandQueue = MetalDevice.shared.commandQueue
        guard let lib = MetalDevice.shared.library else {
            fatalError("AstroSharper: default Metal library missing — is Shaders.metal in the target?")
        }
        self.library = lib
        // Eager PSO compilation. Building all 14 compute pipelines upfront
        // is ~80 ms on Apple Silicon — fine at app launch, painful as a
        // first-slider hiccup if left lazy. The kernels are tiny and
        // shared across every pipeline call anyway, so up-front build is
        // strictly cheaper than first-touch latency. (No cleanup work
        // needed; PSOs are reference-counted.)
        //
        // The local `make` captures `dev` and `lib` only (not `self`) so
        // it's safe to call before all stored properties are initialised.
        @inline(__always) func make(_ name: String) -> MTLComputePipelineState {
            guard let fn = lib.makeFunction(name: name) else {
                fatalError("AstroSharper: Metal function '\(name)' not found")
            }
            return try! dev.makeComputePipelineState(function: fn)
        }
        self.unsharpPSO = make("unsharp_mask")
        self.divPSO     = make("lr_divide")
        self.mulPSO     = make("lr_multiply")
        self.tonePSO    = make("apply_tone_curve")
        self.satPSO     = make("apply_saturation")
        self.nrPSO      = make("noise_reduce_bilateral")
        self.wbPSO      = make("apply_white_balance")
        self.acdcPSO    = make("shift_rb_channels")
        self.stretchPSO = make("apply_auto_stretch")
        self.bcPSO      = make("apply_brightness_contrast")
        self.hsPSO      = make("apply_highlights_shadows")
        self.shiftPSO   = make("sub_pixel_shift")
        self.stackPSO   = make("stack_accumulate")
        self.subPSO     = make("subtract_textures")
        self.waddPSO    = make("weighted_add")
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
    ///
    /// `preview` = true switches Wiener to a 50%-downsampled FFT (~4× faster)
    /// so the live throttle path stays under the 33 ms budget. The
    /// downsample-Wiener-upsample chain produces a slightly softer result
    /// than the full-res path; PreviewCoordinator runs a second
    /// `preview: false` pass after a 200 ms drag-end debounce to land
    /// the final full-res Wiener result.
    ///
    /// `onStageChange` is invoked synchronously on the calling (background)
    /// thread before each major pipeline stage transitions in: with
    /// `.colourLevels` before WB / ACDC, `.sharpening` before LR / Wavelet /
    /// Unsharp / Wiener / NR, `.toneCurve` before tone LUT / B/C /
    /// Saturation, and `nil` after the final blit. The PreviewCoordinator
    /// hops to `DispatchQueue.main.async` and writes the value to
    /// `AppModel.activePreviewStage`, which the SettingsPanel section
    /// headers watch.
    func process(
        input: MTLTexture,
        sharpen: SharpenSettings,
        toneCurve: ToneCurveSettings,
        toneCurveLUT: MTLTexture? = nil,
        preview: Bool = false,
        onStageChange: ((PreviewStage?) -> Void)? = nil
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

        // Stage transition: colour & levels (auto-WB + ACDC). Only emitted
        // when at least one of those toggles is on — emitting a callback
        // with .colourLevels just to flip back to nil immediately would
        // produce visible UI flicker.
        let runColourLevels = toneCurve.autoWB || toneCurve.chromaticAlignment
        if runColourLevels { onStageChange?(.colourLevels) }

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

        // Stage transition: sharpening (LR / Wavelet / Unsharp / Wiener / NR).
        // Gated on `sharpen.enabled` so the panel header doesn't flash when
        // the section is off — even one of the sub-toggles being on with
        // the master off shouldn't light up the section visually.
        if sharpen.enabled { onStageChange?(.sharpening) }

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
        //
        // `preview: true` switches to a 50%-downsampled FFT — ~4× faster
        // (FFT cost scales with pixel count) at the cost of a softer result.
        // The PreviewCoordinator runs a final `preview: false` pass after a
        // 200 ms drag-end debounce so the user lands on a full-res image.
        let needsWiener = sharpen.enabled && sharpen.wienerEnabled
        if needsWiener {
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            if preview {
                // Downsample → Wiener → upsample. Sigma scales with the
                // downsample factor (a 1 px PSF on the full-res image is
                // 0.5 px on a half-res copy). MPSImageBilinearScale runs
                // GPU-side; the Wiener readback then sees a 1/4-area
                // staging buffer, which is the actual ~4× speedup.
                let dwsW = max(2, w / 2)
                let dwsH = max(2, h / 2)
                let smallDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: input.pixelFormat, width: dwsW, height: dwsH, mipmapped: false
                )
                smallDesc.storageMode = .private
                smallDesc.usage = [.shaderRead, .shaderWrite]
                if let smallIn = device.makeTexture(descriptor: smallDesc),
                   let smallOut = device.makeTexture(descriptor: smallDesc),
                   let scaleCmd1 = commandQueue.makeCommandBuffer(),
                   let scaleCmd2 = commandQueue.makeCommandBuffer() {
                    let downscaler = MPSImageBilinearScale(device: device)
                    downscaler.encode(commandBuffer: scaleCmd1, sourceTexture: current, destinationTexture: smallIn)
                    scaleCmd1.commit()
                    scaleCmd1.waitUntilCompleted()
                    Wiener.deconvolve(
                        input: smallIn, output: smallOut,
                        sigma: Float(sharpen.wienerSigma) * 0.5,  // PSF shrinks with downsample
                        snr: Float(sharpen.wienerSNR),
                        device: device,
                        captureGamma: Float(sharpen.captureGamma),
                        processLuminanceOnly: sharpen.processLuminanceOnly
                    )
                    let upscaler = MPSImageBilinearScale(device: device)
                    upscaler.encode(commandBuffer: scaleCmd2, sourceTexture: smallOut, destinationTexture: result)
                    scaleCmd2.commit()
                    scaleCmd2.waitUntilCompleted()
                } else {
                    // Allocation failure — fall back to full-res Wiener.
                    Wiener.deconvolve(
                        input: current, output: result,
                        sigma: Float(sharpen.wienerSigma),
                        snr: Float(sharpen.wienerSNR),
                        device: device,
                        captureGamma: Float(sharpen.captureGamma),
                        processLuminanceOnly: sharpen.processLuminanceOnly
                    )
                }
            } else {
                Wiener.deconvolve(
                    input: current, output: result,
                    sigma: Float(sharpen.wienerSigma),
                    snr: Float(sharpen.wienerSNR),
                    device: device,
                    captureGamma: Float(sharpen.captureGamma),
                    processLuminanceOnly: sharpen.processLuminanceOnly
                )
            }
            current = result
        }

        // Tone curve runs on a fresh command buffer if Wiener already
        // committed the previous one.
        let cmdBuf2 = needsWiener ? commandQueue.makeCommandBuffer() : cmdBuf
        guard let finalCmd = cmdBuf2 else { return copyTexture(input, into: output) }

        // Stage transition: tone curve (LUT + B/C + Saturation). Gate on
        // toneCurve.enabled and at least one non-identity sub-control so
        // a default-on tone curve panel with everything at identity
        // doesn't light up.
        let runToneStage = toneCurve.enabled
            && (toneCurveLUT != nil || !bcIsIdentity || abs(toneCurve.saturation - 1.0) > 1e-4)
        if runToneStage { onStageChange?(.toneCurve) }

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

        // Highlights / Shadows: runs after brightness+contrast (operates on
        // the user's curve+BC-mapped values) and before saturation (so the
        // sat boost reads the recovered highlights / lifted shadows). At
        // identity (both 0) the kernel is skipped so the no-op case costs
        // nothing. Driven by the live preview's reprocessSubject sink so
        // slider drags update at ~30 fps.
        if toneCurve.enabled,
           abs(toneCurve.highlights) > 1e-4 || abs(toneCurve.shadows) > 1e-4 {
            let result = borrow(width: w, height: h, format: input.pixelFormat)
            borrowed.append(result)
            if let enc = finalCmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(hsPSO)
                enc.setTexture(current, index: 0)
                enc.setTexture(result, index: 1)
                var p = HighlightsShadowsParamsCPU(
                    highlights: Float(toneCurve.highlights),
                    shadows:    Float(toneCurve.shadows)
                )
                enc.setBytes(&p, length: MemoryLayout<HighlightsShadowsParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: result, pso: hsPSO)
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
        // Final stage transition: idle. Tells the SettingsPanel section
        // headers to drop the highlight tint after the GPU work landed.
        onStageChange?(nil)
        return output
    }

    // MARK: - Helpers

    /// Compute (blackPoint, median, whitePoint) Rec.709-luma percentiles
    /// on `input`. Downsamples to a 256-ish staging texture and sorts
    /// luma CPU-side, so reading any number of percentile points is
    /// essentially free after the sort. `lowPercentile` /
    /// `highPercentile` are 0..1 (e.g. 0.01 and 0.99). Median is always
    /// the 50th percentile. Returns nil on a degenerate uniform plane.
    func computeLumaPercentiles(
        input: MTLTexture,
        lowPercentile: Double,
        highPercentile: Double
    ) -> (black: Float, median: Float, white: Float)? {
        let w = input.width, h = input.height
        guard w > 0, h > 0 else { return nil }
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
              let cmd = commandQueue.makeCommandBuffer() else { return nil }

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

        // Per-pixel Rec.709 luma (matches the saturation kernel) so the
        // remap is computed once on luminance and applied to all RGB
        // channels uniformly — avoids per-channel imbalance artefacts.
        var luma = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            luma[i] = 0.2126 * rgba[i * 4 + 0]
                   + 0.7152 * rgba[i * 4 + 1]
                   + 0.0722 * rgba[i * 4 + 2]
        }
        luma.sort()
        let lo = max(0.0, min(1.0, lowPercentile))
        let hi = max(0.0, min(1.0, highPercentile))
        let blackIdx  = max(0, min(pixelCount - 1, Int(Double(pixelCount - 1) * lo)))
        let medianIdx = max(0, min(pixelCount - 1, Int(Double(pixelCount - 1) * 0.5)))
        let whiteIdx  = max(0, min(pixelCount - 1, Int(Double(pixelCount - 1) * hi)))
        let black  = luma[blackIdx]
        let median = luma[medianIdx]
        let white  = luma[whiteIdx]
        guard white > black + 1e-4 else { return nil }
        return (black, median, white)
    }

    /// Stack-end auto-recovery: undoes the dynamic-range compression that
    /// mean-stacking introduces (lifted dark sky + flattened bright peaks)
    /// by linearly remapping the [1%, 99%] luma window into [0, 0.97].
    /// No gamma, no contrast amplification — just refills the histogram
    /// the stack squished into the middle of the range. Always-on at the
    /// end of the LuckyStack post-pass; replaces the old user-facing
    /// `autoStretch` toggle. Returns a new caller-owned texture (matching
    /// `input`'s pixel format). On a degenerate input the helper falls
    /// back to a copy so callers never need a nil check.
    ///
    /// The remap only fires when the input histogram is dark-dominated
    /// (median < 0.30) — that's the planet-on-dark-sky case where mean-
    /// stacking visibly compresses the planet body's range. Lunar /
    /// solar / textured subjects fill the histogram natively (median ≥
    /// 0.30 — bulk of pixels are mid-tone or higher); on those a remap
    /// pushes existing wide range to extremes and produces an
    /// "unnatural over-contrast" look (failure mode reproduced on lunar
    /// 2026-04-29: stacked output had p1=0, p99=0.973 with crushed
    /// shadows + blown rims). Skipping is the right call there — the
    /// bare stack already looks natural.
    func applyOutputRemap(input: MTLTexture, whiteCap whiteCapOverride: Float? = nil, enabled: Bool = true) -> MTLTexture {
        let w = input.width, h = input.height
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat, width: w, height: h, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .private
        let output = device.makeTexture(descriptor: outDesc)!

        guard enabled else {
            NSLog("LuckyStack: subject-aware tone disabled")
            return copyTexture(input, into: output)
        }

        // Subject-aware tone (2026-05-01). User bracket on lunar + jupiter
        // confirmed:
        //   lunar (wide-range, median ≥ 0.30): bare accumulator IS the right
        //     output — gamma 1.0 / no offset preferred over every other
        //     bracket value. Identity is correct.
        //   jupiter (dark-dominated, median < 0.30): bare accumulator was
        //     too bright; gamma 1.3 picked as the favourite. That's a pure
        //     midtone compression, no clamping → no detail loss.
        //
        // Implementation: reuse the existing apply_auto_stretch kernel with
        // blackPoint=0, scale=1, whiteCap=1, gamma=1.3 — i.e. just `pow(v, gamma)`
        // per pixel. The kernel's whiteCap clamp at 1.0 leaves all in-range
        // values untouched (only would-clamp negative-resulting overshoots,
        // which gamma > 1 doesn't produce).
        //
        // Backwards-compat: `whiteCapOverride` from --white-cap CLI flag
        // overrides the gamma-only path with the legacy hard-clamp stretch.
        // Documented as "use only for the brightness bracket script."
        guard let pts = computeLumaPercentiles(input: input, lowPercentile: 0.01, highPercentile: 0.998) else {
            return copyTexture(input, into: output)
        }

        let blackPoint: Float
        let scale: Float
        let whiteCap: Float
        let gamma: Float

        if let cap = whiteCapOverride {
            // Legacy hard-clamp stretch (bracket-script only — destroys
            // highlight detail, kept behind the explicit override for
            // empirical regression testing).
            whiteCap = cap
            gamma = 1.0
            if pts.median < 0.30 {
                blackPoint = pts.black
                scale = cap / max(1e-4, pts.white - pts.black)
                NSLog("LuckyStack: legacy whiteCap stretch dark mode (cap=%.2f, median=%.3f)", cap, pts.median)
            } else if pts.white > cap {
                blackPoint = 0
                scale = cap / pts.white
                NSLog("LuckyStack: legacy whiteCap stretch wide highlight-compress (cap=%.2f)", cap)
            } else {
                NSLog("LuckyStack: legacy whiteCap stretch skipped (well-exposed)")
                return copyTexture(input, into: output)
            }
        } else if pts.white > 0.50 && pts.median >= 0.30 {
            // Wide-range bright (solar Ha, lunar close-up, textured
            // surfaces). Median high → most pixels are mid-bright.
            // White high → already filling most of the histogram.
            // User-picked file 26_stretch_g25 from /tmp/display-bracket/
            // = pow((col − p1) · (1/(p99 − p1)), 2.5). Matches the live
            // preview shader's auto path 1:1 — the baked TIF carries
            // the same tone curve the user saw during stacking. With
            // the swap chain tagged sRGB (PreviewView 2026-05-01) the
            // shader is a true pass-through when Auto OFF, so opening
            // the saved TIF in our app or any standard viewer renders
            // those pre-baked bytes directly without further encoding.
            NSLog("LuckyStack: subject-aware tone wide-bright mode (median=%.3f white=%.3f → stretch+γ=2.5)",
                  pts.median, pts.white)
            blackPoint = pts.black
            let range = max(Float(0.005), pts.white - pts.black)
            scale = 1.0 / range
            whiteCap = 1.0
            gamma = 2.5
        } else if pts.white > 0.50 {
            // Bright peak + dark-dominated median: small planet on dark
            // sky (Jupiter / Saturn / Mars). User-picked γ=1.3 — pure
            // midtone darkening, no clamp, preserves all detail.
            // Verified on jupiter (p998=0.717 → 0.654).
            NSLog("LuckyStack: subject-aware tone bright-peak mode (median=%.3f white=%.3f → gamma 1.3)",
                  pts.median, pts.white)
            blackPoint = 0
            scale = 1.0
            whiteCap = 1.0
            gamma = 1.3
        } else {
            // Highlight peak ≤ 0.5 — lunar full disc, well-exposed wide.
            // Bare accumulator is what the user wants.
            NSLog("LuckyStack: subject-aware tone identity mode (median=%.3f white=%.3f → no change)",
                  pts.median, pts.white)
            return copyTexture(input, into: output)
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            return copyTexture(input, into: output)
        }
        enc.setComputePipelineState(stretchPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        var p = AutoStretchParamsCPU(
            blackPoint: blackPoint,
            scale: scale,
            whiteCap: whiteCap,
            gamma: gamma
        )
        enc.setBytes(&p, length: MemoryLayout<AutoStretchParamsCPU>.stride, index: 0)
        let (tgC, tgS) = dispatchThreadgroups(for: output, pso: stretchPSO)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return output
    }

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

/// Mirror of the Metal `HighlightsShadowsParams` struct.
struct HighlightsShadowsParamsCPU {
    var highlights: Float
    var shadows: Float
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

/// Mirror of the Metal `AutoStretchParams` struct.
struct AutoStretchParamsCPU {
    var blackPoint: Float
    var scale: Float
    var whiteCap: Float
    var gamma: Float
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
