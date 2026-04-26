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
        /// How shifts are computed. Full-frame phase correlation, disc
        /// centroid (solar/lunar with bright disc on dark sky), or phase
        /// correlation restricted to a normalised ROI on the reference.
        let alignmentMode: StabilizeSettings.AlignmentMode
        /// User-selected reference frame ID. Must match one of the entries
        /// in `urls`. If `pickBestReference` is true this is overridden
        /// after a quality-grading pass.
        let referenceID: UUID
        /// When true, the Stabilizer scores every input by Laplacian-
        /// variance and uses the sharpest frame as reference instead of
        /// the supplied `referenceID`.
        let pickBestReference: Bool
        /// Optional ROI rect in *normalised* reference-frame coordinates
        /// (0…1, top-left origin). Only consulted when
        /// `alignmentMode == .referenceROI`.
        let roi: CGRect?
        /// Pre-loaded textures keyed by ID. When present for an entry,
        /// Stabilizer uses the texture directly instead of reading the
        /// file from disk — this is what preserves any in-memory edits
        /// (sharpen / tone) when stabilizing from the Memory tab.
        let preloadedTextures: [UUID: MTLTexture]

        // Convenience initialiser preserving the historical call-site
        // ergonomics; new code goes through the full memberwise init.
        init(urls: [(id: UUID, url: URL, meridianFlipped: Bool)],
             cropMode: StabilizeSettings.CropMode,
             alignmentMode: StabilizeSettings.AlignmentMode = .fullFrame,
             referenceID: UUID? = nil,
             pickBestReference: Bool = false,
             roi: CGRect? = nil,
             preloadedTextures: [UUID: MTLTexture] = [:]) {
            self.urls = urls
            self.cropMode = cropMode
            self.alignmentMode = alignmentMode
            self.referenceID = referenceID ?? urls.first?.id ?? UUID()
            self.pickBestReference = pickBestReference
            self.roi = roi
            self.preloadedTextures = preloadedTextures
        }
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

            // Helper: fetch texture for one entry. Prefers a preloaded
            // memory texture, falls back to disk-load + meridian-flip.
            func fetchTexture(for entry: (id: UUID, url: URL, meridianFlipped: Bool)) -> MTLTexture? {
                if let pre = inputs.preloadedTextures[entry.id] { return pre }
                guard var t = try? ImageTexture.load(url: entry.url, device: device) else { return nil }
                if entry.meridianFlipped {
                    t = RotateTexture.rotate180(t, device: device)
                }
                return t
            }

            // Pick the reference: either user-pinned, or auto-best by
            // Laplacian variance score across all candidates.
            var refIdx: Int = urls.firstIndex { $0.id == inputs.referenceID } ?? 0
            if inputs.pickBestReference {
                var bestScore: Float = -.infinity
                for (i, entry) in urls.enumerated() {
                    guard let t = fetchTexture(for: entry) else { continue }
                    let s = Align.qualityScore(t)
                    if s > bestScore { bestScore = s; refIdx = i }
                }
            }

            guard let refTex = fetchTexture(for: urls[refIdx]) else {
                await completion(nil)
                return
            }

            // Compute shifts. The reference shift is always (0,0).
            var shifts: [UUID: AlignShift] = [urls[refIdx].id: AlignShift(dx: 0, dy: 0)]
            for i in 0..<urls.count where i != refIdx {
                if Task.isCancelled { await completion(nil); return }
                guard let tex = fetchTexture(for: urls[i]) else {
                    shifts[urls[i].id] = AlignShift(dx: 0, dy: 0)
                    continue
                }
                let s: AlignShift
                switch inputs.alignmentMode {
                case .fullFrame:
                    s = Align.phaseCorrelate(reference: refTex, frame: tex) ?? AlignShift(dx: 0, dy: 0)
                case .discCentroid:
                    s = Align.discCentroidShift(reference: refTex, frame: tex) ?? AlignShift(dx: 0, dy: 0)
                case .referenceROI:
                    let roi = inputs.roi ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    s = Align.phaseCorrelateROI(reference: refTex, frame: tex, normROI: roi)
                        ?? AlignShift(dx: 0, dy: 0)
                }
                shifts[urls[i].id] = s
                await onProgress(.computingShifts(done: i + 1, total: urls.count))
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
                guard let srcTex = fetchTexture(for: item) else { continue }
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
