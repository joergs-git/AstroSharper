// Runs processing across a set of files.
//
// Flow:
//   1. Load all input files into MTLTextures (lazily, one at a time, so a
//      10-frame batch doesn't OOM on huge astro frames).
//   2. If Stabilize is enabled (≥2 files): compute shifts against the
//      reference frame, apply sub-pixel shift, optionally stack-average.
//   3. Run the per-frame pipeline (L-R → Unsharp → Tone).
//   4. Write output as 16-bit TIFF into `<folder>/_processed/`.
//
// Status is fed back to AppModel via an `onProgress` callback — the UI shows
// per-file status in the list and overall progress in the status bar.
import Foundation
import Metal

final class BatchJob {
    struct Input {
        let id: UUID
        let url: URL
        let meridianFlipped: Bool
        init(id: UUID, url: URL, meridianFlipped: Bool = false) {
            self.id = id; self.url = url; self.meridianFlipped = meridianFlipped
        }
    }

    struct Config {
        var sharpen: SharpenSettings
        var stabilize: StabilizeSettings
        var toneCurve: ToneCurveSettings
    }

    enum Event {
        case started(total: Int)
        case fileStarted(id: UUID)
        case fileDone(id: UUID)
        case fileFailed(id: UUID, message: String)
        case finished(processed: Int)
        case cancelled
    }

    private let pipeline = Pipeline()
    private var cancelled = false
    private var task: Task<Void, Never>?

    func cancel() { cancelled = true; task?.cancel() }

    func run(
        inputs: [Input],
        outputDir: URL,
        config: Config,
        onEvent: @escaping @MainActor (Event) -> Void
    ) {
        guard !inputs.isEmpty else { return }
        let total = inputs.count

        task = Task.detached(priority: .userInitiated) { [pipeline] in
            await onEvent(.started(total: total))

            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            } catch {
                await onEvent(.finished(processed: 0))
                return
            }

            // Build tone-curve LUT once.
            let lut: MTLTexture? = config.toneCurve.enabled
                ? ToneCurveLUT.build(points: config.toneCurve.controlPoints, device: MetalDevice.shared.device)
                : nil

            // Stabilization: compute shifts up front and optionally derive a
            // crop rectangle that's the intersection of all shifted frames.
            var shifts: [UUID: AlignShift] = [:]
            var stackTexture: MTLTexture? = nil
            var stackFrameCount = 0
            var cropOrigin: (x: Int, y: Int) = (0, 0)
            var cropSize: (w: Int, h: Int)? = nil  // nil = no cropping

            if config.stabilize.enabled, let refInput = inputs.first, inputs.count >= 2 {
                guard let refTex = try? ImageTexture.load(url: refInput.url, device: MetalDevice.shared.device) else {
                    await onEvent(.finished(processed: 0))
                    return
                }
                let srcW = refTex.width, srcH = refTex.height
                let refID = refInput.id
                for input in inputs {
                    if await BatchJob.isCancelled() { await onEvent(.cancelled); return }
                    if input.id == refID {
                        shifts[input.id] = AlignShift(dx: 0, dy: 0)
                        continue
                    }
                    guard var tex = try? ImageTexture.load(url: input.url, device: MetalDevice.shared.device) else {
                        continue
                    }
                    if input.meridianFlipped {
                        tex = RotateTexture.rotate180(tex, device: MetalDevice.shared.device)
                    }
                    let shift = Align.phaseCorrelate(reference: refTex, frame: tex) ?? AlignShift(dx: 0, dy: 0)
                    shifts[input.id] = shift
                }

                if config.stabilize.cropMode == .crop {
                    // Intersection of all shifted frames' valid content regions.
                    // Positive dx pushes content right → left-side black band of
                    // ceil(dx) pixels. Negative dx → right-side band of floor|dx|.
                    let dxs = shifts.values.map { $0.dx }
                    let dys = shifts.values.map { $0.dy }
                    let maxDxPos = max(0, dxs.max() ?? 0)
                    let maxDxNeg = min(0, dxs.min() ?? 0)  // most negative
                    let maxDyPos = max(0, dys.max() ?? 0)
                    let maxDyNeg = min(0, dys.min() ?? 0)
                    let left = Int(ceil(Double(maxDxPos)))
                    let right = srcW + Int(floor(Double(maxDxNeg)))
                    let top = Int(ceil(Double(maxDyPos)))
                    let bottom = srcH + Int(floor(Double(maxDyNeg)))
                    let w = max(1, right - left)
                    let h = max(1, bottom - top)
                    cropOrigin = (left, top)
                    cropSize = (w, h)
                }
            }

            var processedCount = 0
            for input in inputs {
                if Task.isCancelled { await onEvent(.cancelled); return }
                await onEvent(.fileStarted(id: input.id))

                guard var srcTex = try? ImageTexture.load(url: input.url, device: MetalDevice.shared.device) else {
                    await onEvent(.fileFailed(id: input.id, message: "decode failed"))
                    continue
                }
                if input.meridianFlipped {
                    srcTex = RotateTexture.rotate180(srcTex, device: MetalDevice.shared.device)
                }

                // Apply stabilization shift if any, then (if crop mode) crop
                // to the common overlap region.
                var frameTex: MTLTexture = srcTex
                if let shift = shifts[input.id], shift != AlignShift(dx: 0, dy: 0) {
                    let shifted = pipeline.borrow(width: srcTex.width, height: srcTex.height, format: srcTex.pixelFormat)
                    if let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer() {
                        Align.applyShift(input: srcTex, output: shifted, shift: shift, pipeline: pipeline, commandBuffer: cmd)
                        cmd.commit()
                        cmd.waitUntilCompleted()
                    }
                    frameTex = shifted
                }

                if let crop = cropSize, config.stabilize.enabled {
                    let cropped = pipeline.borrow(width: crop.w, height: crop.h, format: frameTex.pixelFormat)
                    if let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(),
                       let blit = cmd.makeBlitCommandEncoder() {
                        blit.copy(
                            from: frameTex,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: cropOrigin.x, y: cropOrigin.y, z: 0),
                            sourceSize: MTLSize(width: crop.w, height: crop.h, depth: 1),
                            to: cropped,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                        blit.endEncoding()
                        cmd.commit()
                        cmd.waitUntilCompleted()
                    }
                    frameTex = cropped
                }

                // Stack-average path: accumulate into stackTexture, don't run per-frame pipeline.
                if config.stabilize.enabled && config.stabilize.stackAverage && inputs.count >= 2 {
                    if stackTexture == nil {
                        let desc = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: frameTex.pixelFormat, width: frameTex.width, height: frameTex.height, mipmapped: false
                        )
                        desc.usage = [.shaderRead, .shaderWrite]
                        desc.storageMode = .private
                        stackTexture = MetalDevice.shared.device.makeTexture(descriptor: desc)
                        if let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
                            blit.copy(from: frameTex, to: stackTexture!)
                            blit.endEncoding()
                            cmd.commit()
                            cmd.waitUntilCompleted()
                        }
                        stackFrameCount = 1
                    } else {
                        stackFrameCount += 1
                        let weight = Float(1.0) / Float(stackFrameCount)
                        if let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer() {
                            BatchJob.encodeAccumulate(frame: frameTex, accum: stackTexture!, weight: weight, pipeline: pipeline, commandBuffer: cmd)
                            cmd.commit()
                            cmd.waitUntilCompleted()
                        }
                    }
                    await onEvent(.fileDone(id: input.id))
                    processedCount += 1
                    continue
                }

                // Normal per-frame path: run pipeline, write output.
                let processed = pipeline.process(
                    input: frameTex,
                    sharpen: config.sharpen,
                    toneCurve: config.toneCurve,
                    toneCurveLUT: lut
                )

                let suffix = BatchJob.suffix(for: config)
                let outName = input.url.deletingPathExtension().lastPathComponent + suffix + ".tif"
                let outURL = outputDir.appendingPathComponent(outName)
                do {
                    try ImageTexture.write(texture: processed, to: outURL)
                    await onEvent(.fileDone(id: input.id))
                    processedCount += 1
                } catch {
                    await onEvent(.fileFailed(id: input.id, message: "write failed"))
                }
            }

            // If stacking was enabled, run sharpen/tone on the stacked result, write one output.
            if let stack = stackTexture, config.stabilize.enabled && config.stabilize.stackAverage {
                let processed = pipeline.process(
                    input: stack,
                    sharpen: config.sharpen,
                    toneCurve: config.toneCurve,
                    toneCurveLUT: lut
                )
                let outURL = outputDir.appendingPathComponent("stacked_\(Int(Date().timeIntervalSince1970)).tif")
                try? ImageTexture.write(texture: processed, to: outURL)
            }

            await onEvent(.finished(processed: processedCount))
        }
    }

    static func isCancelled() async -> Bool { Task.isCancelled }

    private static func suffix(for config: Config) -> String {
        var parts: [String] = []
        if config.stabilize.enabled { parts.append("aligned") }
        if config.sharpen.enabled && (config.sharpen.unsharpEnabled || config.sharpen.lrEnabled) { parts.append("sharp") }
        if config.toneCurve.enabled { parts.append("tone") }
        return parts.isEmpty ? "_out" : ("_" + parts.joined(separator: "-"))
    }

    // Encodes a single Welford-style accumulation step.
    private static func encodeAccumulate(frame: MTLTexture, accum: MTLTexture, weight: Float, pipeline: Pipeline, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline.stackPipeline)
        enc.setTexture(frame, index: 0)
        enc.setTexture(accum, index: 1)
        var w = weight
        enc.setBytes(&w, length: MemoryLayout<Float>.stride, index: 0)
        let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: pipeline.stackPipeline)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
    }
}
