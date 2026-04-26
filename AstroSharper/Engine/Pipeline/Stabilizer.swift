// In-memory stabilization: loads a list of files, computes phase-correlation
// shifts against a reference frame, applies the (sub-pixel) shifts on GPU,
// and optionally crops to the common-overlap region.
//
// The result is a list of aligned MTLTextures the caller keeps in RAM for
// playback / scrubbing / on-screen verification BEFORE deciding to export.
import Foundation
import Metal

enum Stabilizer {
    struct Inputs {
        /// Each entry: (id, url, meridianFlipped). Files marked as flipped get
        /// rotated 180° in memory so phase-correlation and crop computation
        /// see a consistent orientation across the whole session.
        let urls: [(id: UUID, url: URL, meridianFlipped: Bool)]
        let cropMode: StabilizeSettings.CropMode
    }

    struct Result {
        let aligned: [(id: UUID, url: URL, texture: MTLTexture)]
        let outputSize: (w: Int, h: Int)
    }

    enum Progress {
        case loadingReference
        case computingShifts(done: Int, total: Int)
        case applyingShifts(done: Int, total: Int)
        case finished
    }

    /// Runs end-to-end on a background priority. Calls `onProgress` on the
    /// main actor at each stage so the UI can show a progress bar.
    static func run(
        inputs: Inputs,
        pipeline: Pipeline,
        onProgress: @escaping @MainActor (Progress) -> Void,
        completion: @escaping @MainActor (Result?) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            let urls = inputs.urls
            guard urls.count >= 2 else {
                await completion(nil)
                return
            }

            await onProgress(.loadingReference)
            let device = MetalDevice.shared.device
            // Reference: load + apply flip if flagged.
            var refTex0: MTLTexture? = try? ImageTexture.load(url: urls[0].url, device: device)
            if urls[0].meridianFlipped, let t = refTex0 {
                refTex0 = RotateTexture.rotate180(t, device: device)
            }
            guard let refTex = refTex0 else {
                await completion(nil)
                return
            }

            // Compute shifts.
            var shifts: [UUID: AlignShift] = [urls[0].id: AlignShift(dx: 0, dy: 0)]
            for i in 1..<urls.count {
                if Task.isCancelled { await completion(nil); return }
                guard var tex = try? ImageTexture.load(url: urls[i].url, device: device) else {
                    shifts[urls[i].id] = AlignShift(dx: 0, dy: 0)
                    continue
                }
                if urls[i].meridianFlipped {
                    tex = RotateTexture.rotate180(tex, device: device)
                }
                let s = Align.phaseCorrelate(reference: refTex, frame: tex) ?? AlignShift(dx: 0, dy: 0)
                shifts[urls[i].id] = s
                let done = i
                await onProgress(.computingShifts(done: done, total: urls.count))
            }

            // Crop rectangle (if mode = crop).
            let srcW = refTex.width, srcH = refTex.height
            var cropOrigin: (x: Int, y: Int) = (0, 0)
            var cropSize: (w: Int, h: Int) = (srcW, srcH)
            if inputs.cropMode == .crop {
                let dxs = shifts.values.map { $0.dx }
                let dys = shifts.values.map { $0.dy }
                let maxDxPos = max(0, dxs.max() ?? 0)
                let maxDxNeg = min(0, dxs.min() ?? 0)
                let maxDyPos = max(0, dys.max() ?? 0)
                let maxDyNeg = min(0, dys.min() ?? 0)
                let left = Int(ceil(Double(maxDxPos)))
                let right = srcW + Int(floor(Double(maxDxNeg)))
                let top = Int(ceil(Double(maxDyPos)))
                let bottom = srcH + Int(floor(Double(maxDyNeg)))
                cropOrigin = (left, top)
                cropSize = (max(1, right - left), max(1, bottom - top))
            }

            // Apply shifts → aligned textures.
            var aligned: [(id: UUID, url: URL, texture: MTLTexture)] = []
            aligned.reserveCapacity(urls.count)

            let queue = MetalDevice.shared.commandQueue
            for (idx, item) in urls.enumerated() {
                if Task.isCancelled { await completion(nil); return }
                guard var srcTex = try? ImageTexture.load(url: item.url, device: device) else { continue }
                if item.meridianFlipped {
                    srcTex = RotateTexture.rotate180(srcTex, device: device)
                }
                let shift = shifts[item.id] ?? AlignShift(dx: 0, dy: 0)

                // Allocate a private-storage destination at output size.
                let outDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: srcTex.pixelFormat, width: cropSize.w, height: cropSize.h, mipmapped: false
                )
                outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
                outDesc.storageMode = .private
                guard let outTex = device.makeTexture(descriptor: outDesc) else { continue }

                if let cmd = queue.makeCommandBuffer() {
                    if shift == AlignShift(dx: 0, dy: 0) && inputs.cropMode == .pad {
                        // No shift, no crop: straight blit.
                        if let blit = cmd.makeBlitCommandEncoder() {
                            blit.copy(from: srcTex, to: outTex)
                            blit.endEncoding()
                        }
                    } else {
                        // Shift first into a same-size buffer, then crop to outTex.
                        let shifted = pipeline.borrow(width: srcW, height: srcH, format: srcTex.pixelFormat)
                        Align.applyShift(input: srcTex, output: shifted, shift: shift, pipeline: pipeline, commandBuffer: cmd)
                        if let blit = cmd.makeBlitCommandEncoder() {
                            blit.copy(
                                from: shifted,
                                sourceSlice: 0, sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: cropOrigin.x, y: cropOrigin.y, z: 0),
                                sourceSize: MTLSize(width: cropSize.w, height: cropSize.h, depth: 1),
                                to: outTex,
                                destinationSlice: 0, destinationLevel: 0,
                                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                            )
                            blit.endEncoding()
                        }
                        cmd.addCompletedHandler { _ in
                            // shifted is no longer referenced after this point.
                            // Recycle is safe (Pipeline.recycle is locked).
                            pipeline.recycle(shifted)
                        }
                    }
                    cmd.commit()
                    cmd.waitUntilCompleted()
                }

                aligned.append((id: item.id, url: item.url, texture: outTex))

                let done = idx + 1
                await onProgress(.applyingShifts(done: done, total: urls.count))
            }

            await onProgress(.finished)
            await completion(Result(aligned: aligned, outputSize: cropSize))
        }
    }
}
