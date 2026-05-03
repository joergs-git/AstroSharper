// Sub-pixel image alignment via phase correlation.
//
// Reads two rgba16Float textures, converts to a power-of-two greyscale float
// buffer on CPU, runs 2D FFT (Accelerate / vDSP), computes the cross-power
// spectrum, inverse-FFTs it, and locates the correlation peak. Sub-pixel
// refinement uses a 3-point parabolic fit around the integer peak.
//
// Operating on a power-of-two-padded, Hann-windowed, luminance-downsampled
// buffer keeps runtime reasonable even for 6k frames — a 1024² FFT takes well
// under 50 ms on Apple Silicon, which is plenty for preview-rate stabilization.
import Accelerate
import Foundation
import Metal

struct AlignShift: Equatable {
    var dx: Float
    var dy: Float
}

enum Align {
    /// Pre-computed forward 2-D FFT of a luminance buffer, ready to be fed
    /// straight into the cross-power-spectrum step. Re-use across multiple
    /// correlations against the same frame avoids repeating the (expensive)
    /// FFT pass — e.g. the SER quality scanner pairs frame i with frame i+1
    /// for jitter, so the FFT of i computed for pair (i-1, i) is reused as
    /// the "reference" FFT for pair (i, i+1).
    struct FrameFFT {
        let real: [Float]
        let imag: [Float]
        let n: Int
        let log2n: Int
        let sourceWidth: Int
        let sourceHeight: Int
    }

    /// Compute the forward FFT once so it can be reused. Mirrors the
    /// preprocessing of `phaseCorrelate` (DC removal + Hann window) so
    /// downstream `phaseCorrelate(refFFT:frameFFT:)` can skip straight to
    /// the cross-power spectrum.
    static func computeFFT(of texture: MTLTexture) -> FrameFFT? {
        let maxDim = min(min(texture.width, texture.height), 1024)
        let log2n = Int(log2(Double(maxDim)))
        let n = 1 << log2n
        guard n >= 64 else { return nil }
        guard let lum = luminanceBuffer(from: texture, size: n) else { return nil }
        subtractMean(&lum.wrappedValue)
        applyHannWindow(&lum.wrappedValue, size: n)
        guard var (real, imag) = fft2dForwardOnce(input: lum.wrappedValue, log2n: log2n) else {
            return nil
        }
        // Take ownership — the helper returns owned arrays so we don't
        // re-alias `lum.wrappedValue`.
        _ = (real.count, imag.count)
        return FrameFFT(real: real, imag: imag, n: n, log2n: log2n,
                        sourceWidth: texture.width, sourceHeight: texture.height)
    }

    /// Phase-correlate two pre-computed FFTs. Skips the FFT setup +
    /// luminance extraction + windowing — those happen in `computeFFT`.
    /// Both FFTs must share the same `n` / `log2n`.
    static func phaseCorrelate(refFFT: FrameFFT, frameFFT: FrameFFT) -> AlignShift? {
        guard refFFT.log2n == frameFFT.log2n else { return nil }
        let n = refFFT.n
        guard let peak = fft2dPhaseCorrelation(refReal: refFFT.real, refImag: refFFT.imag,
                                                frmReal: frameFFT.real, frmImag: frameFFT.imag,
                                                log2n: refFFT.log2n) else {
            return nil
        }
        var dxI = peak.x, dyI = peak.y
        if dxI > n / 2 { dxI -= n }
        if dyI > n / 2 { dyI -= n }
        let scaleX = Float(frameFFT.sourceWidth) / Float(n)
        let scaleY = Float(frameFFT.sourceHeight) / Float(n)
        let subX = peak.subX * scaleX
        let subY = peak.subY * scaleY
        return AlignShift(dx: Float(dxI) * scaleX + subX, dy: Float(dyI) * scaleY + subY)
    }

    /// Compute the shift of `frame` relative to `reference` (i.e. applying
    /// `+shift` to `frame` aligns it to `reference`). Convenience wrapper —
    /// when correlating many frames against the same reference, prefer the
    /// `computeFFT` + `phaseCorrelate(refFFT:frameFFT:)` path.
    ///
    /// Runs the existing fine-resolution (up to 1024²) phase-correlation
    /// — proper PSS cascade as of 2026-05-01 (Block B.5):
    ///
    ///   1. Run a cheap coarse 256² phase correlation first.
    ///   2. Convert the coarse peak to fine-grid coordinates.
    ///   3. Run the fine FFT correlation but constrain its peak-find
    ///      to a search window around the coarse-derived centre. The
    ///      fine peak therefore can't lock to noise / aliased basins
    ///      outside that window — those are the failure modes the
    ///      previous "run both, mismatch detector" approach caught
    ///      *after* the fact. Constrained search prevents them.
    ///   4. Sub-pixel parabolic fit at the constrained peak.
    ///
    /// Falls back to global fine search if coarse computation fails;
    /// falls back to coarse-only if fine computation fails. Both
    /// failures together → returns nil (caller marks the frame
    /// rejected).
    ///
    /// Search radius is 8 fine-grid pixels by default — covers
    /// the residual jitter between the coarse-rounded peak (±0.5 ×
    /// `n_fine / 256` ≈ ±2-4 fine px on typical 512-1024² frames)
    /// plus another factor for sub-pixel content. Tighten further
    /// if a regression suggests it.
    static func phaseCorrelate(reference: MTLTexture, frame: MTLTexture) -> AlignShift? {
        // Coarse pass first. Expand `phaseCorrelateBuffers` inline so
        // the coarse Peak is in scope for the fine constrained search;
        // the helper otherwise discards the Peak after converting to
        // AlignShift.
        let coarse: AlignShift?
        let coarsePeak: Peak?
        if let coarseRefBox = luminanceBuffer(from: reference, size: 256),
           let coarseFrameBox = luminanceBuffer(from: frame, size: 256) {
            var c0 = coarseRefBox.wrappedValue
            var c1 = coarseFrameBox.wrappedValue
            prepareBuffer(&c0, size: 256)
            prepareBuffer(&c1, size: 256)
            if let cFFT0 = fft2dForwardOnce(input: c0, log2n: 8),
               let cFFT1 = fft2dForwardOnce(input: c1, log2n: 8),
               let cp = fft2dPhaseCorrelation(
                refReal: cFFT0.real, refImag: cFFT0.imag,
                frmReal: cFFT1.real, frmImag: cFFT1.imag,
                log2n: 8
               ) {
                var dxI = cp.x, dyI = cp.y
                if dxI > 128 { dxI -= 256 }
                if dyI > 128 { dyI -= 256 }
                let sx = Float(reference.width) / 256.0
                let sy = Float(reference.height) / 256.0
                coarse = AlignShift(
                    dx: (Float(dxI) + cp.subX) * sx,
                    dy: (Float(dyI) + cp.subY) * sy
                )
                coarsePeak = cp
            } else {
                coarse = nil
                coarsePeak = nil
            }
        } else {
            coarse = nil
            coarsePeak = nil
        }

        // Fine pass — constrained to the coarse peak's neighbourhood
        // when coarse succeeded; unconstrained otherwise.
        guard let r = computeFFT(of: reference),
              let f = computeFFT(of: frame),
              r.log2n == f.log2n else {
            return coarse  // fine FFT failed; coarse-only fallback
        }
        let nFine = r.n
        var searchCentre: (x: Int, y: Int)? = nil
        var searchRadius: Int = 0
        if let cp = coarsePeak {
            // Map coarse (256-grid) peak to fine-grid coords. Coarse
            // returns indices in [0, 256) with separate sub-pixel
            // offsets — combine then scale to nFine, round to int.
            let fineX = Int(((Float(cp.x) + cp.subX) * Float(nFine) / 256.0).rounded())
            let fineY = Int(((Float(cp.y) + cp.subY) * Float(nFine) / 256.0).rounded())
            searchCentre = (x: ((fineX % nFine) + nFine) % nFine,
                            y: ((fineY % nFine) + nFine) % nFine)
            searchRadius = 8
        }
        guard let peak = fft2dPhaseCorrelation(
            refReal: r.real, refImag: r.imag,
            frmReal: f.real, frmImag: f.imag,
            log2n: r.log2n,
            searchCenter: searchCentre,
            searchRadius: searchRadius
        ) else {
            return coarse  // fine peak-find failed; coarse-only fallback
        }

        // Convert fine peak (n-grid) to source-pixel shift.
        var dxI = peak.x, dyI = peak.y
        if dxI > nFine / 2 { dxI -= nFine }
        if dyI > nFine / 2 { dyI -= nFine }
        let scaleX = Float(f.sourceWidth) / Float(nFine)
        let scaleY = Float(f.sourceHeight) / Float(nFine)
        let subX = peak.subX * scaleX
        let subY = peak.subY * scaleY
        return AlignShift(
            dx: Float(dxI) * scaleX + subX,
            dy: Float(dyI) * scaleY + subY
        )
    }

    /// Phase-correlate two raw float buffers of size n×n (n = 1 << log2n).
    /// Used by chromatic-dispersion correction which extracts per-channel
    /// (R/G/B) planes from a stacked texture and aligns them against the
    /// green reference. The buffers should already be DC-removed and Hann-
    /// windowed by the caller — both are done by `prepareBuffer(_:)` below.
    /// Returns the shift in pixel units of the n×n grid.
    static func phaseCorrelateBuffers(
        reference: [Float],
        frame: [Float],
        log2n: Int
    ) -> AlignShift? {
        let n = 1 << log2n
        guard reference.count == n * n, frame.count == n * n else { return nil }
        guard let r = fft2dForwardOnce(input: reference, log2n: log2n),
              let f = fft2dForwardOnce(input: frame, log2n: log2n),
              let peak = fft2dPhaseCorrelation(
                refReal: r.real, refImag: r.imag,
                frmReal: f.real, frmImag: f.imag,
                log2n: log2n
              ) else {
            return nil
        }
        var dxI = peak.x, dyI = peak.y
        if dxI > n / 2 { dxI -= n }
        if dyI > n / 2 { dyI -= n }
        return AlignShift(dx: Float(dxI) + peak.subX, dy: Float(dyI) + peak.subY)
    }

    /// Prepare a raw plane for phase correlation: subtract the mean and
    /// apply a 2-D Hann window in place. Caller passes the buffer to
    /// `phaseCorrelateBuffers` afterwards.
    static func prepareBuffer(_ buffer: inout [Float], size n: Int) {
        subtractMean(&buffer)
        applyHannWindow(&buffer, size: n)
    }

    // MARK: - Reference quality scoring

    /// Cheap "is this frame sharp?" score. Sub-samples to 256² and
    /// computes the variance of a 3×3 Laplacian — the same metric used by
    /// the lucky-stack grader, just on a small sample. High score = lots
    /// of high-frequency detail = a good reference candidate.
    static func qualityScore(_ texture: MTLTexture) -> Float {
        guard let buf = luminanceBuffer(from: texture, size: 256) else { return 0 }
        let v = buf.wrappedValue
        let n = 256
        var sum: Double = 0, sumSq: Double = 0
        var count: Double = 0
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let c = v[j * n + i]
                let l = (-4 * c
                         + v[j * n + (i - 1)]
                         + v[j * n + (i + 1)]
                         + v[(j - 1) * n + i]
                         + v[(j + 1) * n + i])
                sum += Double(l); sumSq += Double(l * l); count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return Float(sumSq / count - mean * mean)
    }

    // MARK: - ROI phase correlation

    /// Phase correlation restricted to a normalised rect on the reference
    /// frame. Both frames are *cropped* to the same rect (taken in the
    /// reference's coordinate system) before windowing + FFT — so the
    /// shift returned aligns the rect contents, ignoring everything else.
    /// Perfect for pinning alignment to a sunspot, prominence or other
    /// localised feature.
    static func phaseCorrelateROI(reference: MTLTexture,
                                  frame: MTLTexture,
                                  normROI: CGRect) -> AlignShift? {
        // Convert normalised → pixels in reference frame; clamp.
        let refW = reference.width, refH = reference.height
        let x = max(0, min(refW - 8, Int(round(normROI.minX * Double(refW)))))
        let y = max(0, min(refH - 8, Int(round(normROI.minY * Double(refH)))))
        let w = max(8, min(refW - x, Int(round(normROI.width * Double(refW)))))
        let h = max(8, min(refH - y, Int(round(normROI.height * Double(refH)))))

        // Choose working size = largest pow-2 ≤ min(w,h,1024).
        let maxDim = min(w, h, 1024)
        let log2n = Int(log2(Double(maxDim)))
        let n = 1 << log2n
        guard n >= 64 else { return nil }

        guard let refLum = luminanceROI(from: reference, x: x, y: y, w: w, h: h, size: n),
              let frmLum = luminanceROI(from: frame,    x: x, y: y, w: w, h: h, size: n)
        else { return nil }

        subtractMean(&refLum.wrappedValue)
        subtractMean(&frmLum.wrappedValue)
        applyHannWindow(&refLum.wrappedValue, size: n)
        applyHannWindow(&frmLum.wrappedValue, size: n)

        // Forward-FFT both, then phase correlate.
        guard let r = fft2dForwardOnce(input: refLum.wrappedValue, log2n: log2n),
              let f = fft2dForwardOnce(input: frmLum.wrappedValue, log2n: log2n),
              let peak = fft2dPhaseCorrelation(refReal: r.real, refImag: r.imag,
                                                frmReal: f.real, frmImag: f.imag,
                                                log2n: log2n) else {
            return nil
        }

        var dxI = peak.x, dyI = peak.y
        if dxI > n / 2 { dxI -= n }
        if dyI > n / 2 { dyI -= n }
        // ROI scale: ROI was sampled from a w×h region into n×n. Shift
        // measured inside the ROI maps back at scale w/n × h/n.
        let scaleX = Float(w) / Float(n)
        let scaleY = Float(h) / Float(n)
        return AlignShift(dx: Float(dxI) * scaleX + peak.subX * scaleX,
                          dy: Float(dyI) * scaleY + peak.subY * scaleY)
    }

    // MARK: - Disc centroid

    /// Solar/lunar disc alignment. Threshold the luminance, compute the
    /// centre of mass of the bright pixels, return the shift that brings
    /// the frame's centroid onto the reference's. Fast (no FFT), robust
    /// against thin clouds and seeing wobble — works as long as the disc
    /// is bright relative to the surroundings, which is the entire point
    /// of solar / lunar imaging.
    static func discCentroidShift(reference: MTLTexture, frame: MTLTexture) -> AlignShift? {
        guard let refC = discCentroid(of: reference) else { return nil }
        guard let frmC = discCentroid(of: frame)     else { return nil }
        // The shift that aligns `frame` to `reference` is (refC − frmC).
        return AlignShift(dx: Float(refC.x - frmC.x), dy: Float(refC.y - frmC.y))
    }

    /// Compute the centroid of bright pixels in a downsampled luminance
    /// view of the texture. Threshold = 25 % of max — generous enough to
    /// catch the limb on overexposed shots without bleeding into the dark
    /// background. Returned in original-texture pixel coordinates.
    private static func discCentroid(of texture: MTLTexture) -> (x: Double, y: Double)? {
        // 256² downsample is plenty for centroid precision (≤ ~ 0.01 px
        // when scaled back to a 4k image).
        let n = 256
        guard let ref = luminanceBuffer(from: texture, size: n) else { return nil }
        let buf = ref.wrappedValue
        var maxV: Float = 0
        for v in buf where v > maxV { maxV = v }
        guard maxV > 0 else { return nil }
        let threshold: Float = 0.25 * maxV

        var sumX: Double = 0, sumY: Double = 0, sumW: Double = 0
        for j in 0..<n {
            for i in 0..<n {
                let v = buf[j * n + i]
                if v > threshold {
                    let w = Double(v - threshold)
                    sumX += Double(i) * w
                    sumY += Double(j) * w
                    sumW += w
                }
            }
        }
        guard sumW > 0 else { return nil }
        // luminanceBuffer sampled the centre nativeN×nativeN crop. Scale
        // back: x_native = (sumX/sumW) * (nativeN/n), then add offX.
        let srcW = texture.width, srcH = texture.height
        let nativeN = min(srcW, srcH)
        let offX = (srcW - nativeN) / 2
        let offY = (srcH - nativeN) / 2
        let s = Double(nativeN) / Double(n)
        return (Double(offX) + (sumX / sumW) * s,
                Double(offY) + (sumY / sumW) * s)
    }

    // MARK: - Luminance ROI extraction

    private static func luminanceROI(from texture: MTLTexture,
                                     x: Int, y: Int, w: Int, h: Int,
                                     size n: Int) -> Ref<[Float]>? {
        let srcW = texture.width, srcH = texture.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: srcW, height: srcH, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let staging = MetalDevice.shared.device.makeTexture(descriptor: desc) else { return nil }
        guard let cmdBuf = MetalDevice.shared.commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, to: staging)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let bytesPerPixel = 8
        let bytesPerRow = srcW * bytesPerPixel
        var rgba = [UInt16](repeating: 0, count: srcW * srcH * 4)
        rgba.withUnsafeMutableBufferPointer { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: srcW, height: srcH, depth: 1)),
                mipmapLevel: 0
            )
        }
        var out = [Float](repeating: 0, count: n * n)
        let stepX = Double(w) / Double(n)
        let stepY = Double(h) / Double(n)
        for j in 0..<n {
            let sy = y + Int(Double(j) * stepY)
            let syc = min(srcH - 1, max(0, sy))
            for i in 0..<n {
                let sx = x + Int(Double(i) * stepX)
                let sxc = min(srcW - 1, max(0, sx))
                let base = (syc * srcW + sxc) * 4
                let r = Float(Float16(bitPattern: rgba[base + 0]))
                let g = Float(Float16(bitPattern: rgba[base + 1]))
                let b = Float(Float16(bitPattern: rgba[base + 2]))
                out[j * n + i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return Ref(out)
    }

    // MARK: - Luminance extraction

    private final class Ref<T> {
        var wrappedValue: T
        init(_ v: T) { wrappedValue = v }
    }

    private static func luminanceBuffer(from texture: MTLTexture, size n: Int) -> Ref<[Float]>? {
        // Read back the texture (rgba16Float) into a shared CPU buffer.
        // We downsample on the fly by nearest-neighbor.
        let srcW = texture.width
        let srcH = texture.height

        // Make a shared-storage copy of the texture so we can read its bytes.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: srcW, height: srcH, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let staging = MetalDevice.shared.device.makeTexture(descriptor: desc) else { return nil }
        guard let cmdBuf = MetalDevice.shared.commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, to: staging)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let bytesPerPixel = 8  // rgba16Float
        let bytesPerRow = srcW * bytesPerPixel
        var rgba = [UInt16](repeating: 0, count: srcW * srcH * 4)
        rgba.withUnsafeMutableBufferPointer { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: srcW, height: srcH, depth: 1)),
                mipmapLevel: 0
            )
        }

        // Convert the centre crop of size (nativeN × nativeN) to luminance, then resize to n.
        let nativeN = min(srcW, srcH)
        let offX = (srcW - nativeN) / 2
        let offY = (srcH - nativeN) / 2
        var out = [Float](repeating: 0, count: n * n)
        let step = Double(nativeN) / Double(n)
        for j in 0..<n {
            let sy = offY + Int(Double(j) * step)
            for i in 0..<n {
                let sx = offX + Int(Double(i) * step)
                let base = (sy * srcW + sx) * 4
                let r = Float(Float16(bitPattern: rgba[base + 0]))
                let g = Float(Float16(bitPattern: rgba[base + 1]))
                let b = Float(Float16(bitPattern: rgba[base + 2]))
                out[j * n + i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return Ref(out)
    }

    // MARK: - DC removal

    private static func subtractMean(_ buffer: inout [Float]) {
        guard !buffer.isEmpty else { return }
        var mean: Float = 0
        vDSP_meanv(buffer, 1, &mean, vDSP_Length(buffer.count))
        var negMean = -mean
        vDSP_vsadd(buffer, 1, &negMean, &buffer, 1, vDSP_Length(buffer.count))
    }

    // MARK: - Hann window

    private static func applyHannWindow(_ buffer: inout [Float], size n: Int) {
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var tmp = [Float](repeating: 0, count: n * n)
        // out[j, i] = in[j, i] * win[i] * win[j]
        for j in 0..<n {
            let wj = win[j]
            for i in 0..<n {
                tmp[j * n + i] = buffer[j * n + i] * win[i] * wj
            }
        }
        buffer = tmp
    }

    // MARK: - 2D FFT phase correlation

    struct Peak {
        let x: Int
        let y: Int
        let subX: Float
        let subY: Float
    }

    /// Forward 2-D FFT only. Used by `computeFFT` so the result can be
    /// cached and reused across multiple correlations against the same
    /// frame.
    private static func fft2dForwardOnce(input: [Float], log2n: Int) -> (real: [Float], imag: [Float])? {
        let n = 1 << log2n
        var real = input
        var imag = [Float](repeating: 0, count: n * n)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n + 1), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
            }
        }
        return (real, imag)
    }

    /// Cross-power spectrum + inverse FFT + peak find. Both inputs must
    /// already be in frequency domain (use `fft2dForwardOnce`).
    ///
    /// `searchCenter` + `searchRadius` constrain the peak-find to a
    /// box around the supplied centre (PSS coarse-to-fine refinement,
    /// 2026-05-01). When nil, scan globally — same behaviour as the
    /// pre-PSS API. Coordinates wrap modulo n so the box can straddle
    /// the natural [0, n) boundary that vDSP's wrap-aware peak layout
    /// places half the shift space on the far side of.
    private static func fft2dPhaseCorrelation(refReal: [Float], refImag: [Float],
                                              frmReal: [Float], frmImag: [Float],
                                              log2n: Int,
                                              searchCenter: (x: Int, y: Int)? = nil,
                                              searchRadius: Int = 0) -> Peak? {
        let n = 1 << log2n

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n + 1), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        func fft2dInverse(_ real: inout [Float], _ imag: inout [Float]) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                }
            }
        }

        // Cross-power spectrum: CP = (F * conj(G)) / |F * conj(G)|
        // Where F = ref, G = frame. Result after IFFT peaks at the shift.
        let count = n * n
        var cpReal = [Float](repeating: 0, count: count)
        var cpImag = [Float](repeating: 0, count: count)
        for k in 0..<count {
            let fr = refReal[k], fi = refImag[k]
            let gr = frmReal[k], gi = -frmImag[k]  // conjugate of G
            // (fr + i*fi) * (gr + i*gi) = (fr*gr - fi*gi) + i*(fr*gi + fi*gr)
            let re = fr * gr - fi * gi
            let im = fr * gi + fi * gr
            let mag = max(sqrtf(re * re + im * im), 1e-12)
            cpReal[k] = re / mag
            cpImag[k] = im / mag
        }

        fft2dInverse(&cpReal, &cpImag)

        // Peak find. Either constrained (PSS — search box around the
        // coarse-derived centre) or global. Box-constrained mode
        // forbids the peak from locking to noise basins outside the
        // window, which the unconstrained scan can pick when the
        // fine-grid signal is weak relative to its own noise floor.
        var peakVal: Float = -.infinity
        var peakIdx = 0
        if let centre = searchCenter, searchRadius > 0 {
            let r = searchRadius
            for dyOff in -r...r {
                let yi = ((centre.y + dyOff) % n + n) % n
                for dxOff in -r...r {
                    let xi = ((centre.x + dxOff) % n + n) % n
                    let k = yi * n + xi
                    let v = cpReal[k]
                    if v > peakVal { peakVal = v; peakIdx = k }
                }
            }
        } else {
            for k in 0..<count {
                let v = cpReal[k]
                if v > peakVal { peakVal = v; peakIdx = k }
            }
        }
        let py = peakIdx / n
        let px = peakIdx % n

        // Sub-pixel parabolic fit using 3 samples around the peak.
        func sample(_ x: Int, _ y: Int) -> Float {
            let xi = (x + n) % n
            let yi = (y + n) % n
            return cpReal[yi * n + xi]
        }
        let cx = sample(px, py)
        let lx = sample(px - 1, py)
        let rx = sample(px + 1, py)
        let ly = sample(px, py - 1)
        let ry = sample(px, py + 1)

        func subpixel(_ l: Float, _ c: Float, _ r: Float) -> Float {
            let denom = l - 2 * c + r
            if abs(denom) < 1e-8 { return 0 }
            let off = 0.5 * (l - r) / denom
            return max(-0.5, min(0.5, off))
        }
        let sx = subpixel(lx, cx, rx)
        let sy = subpixel(ly, cx, ry)

        return Peak(x: px, y: py, subX: sx, subY: sy)
    }

    // MARK: - GPU shift

    private struct ShiftParams { var shift: SIMD2<Float> }

    /// Apply a sub-pixel shift via the `sub_pixel_shift` compute kernel.
    /// Input must be sample-usable — caller is responsible for allocating `output`.
    static func applyShift(
        input: MTLTexture,
        output: MTLTexture,
        shift: AlignShift,
        pipeline: Pipeline,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline.shiftPipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        var params = ShiftParams(shift: SIMD2(shift.dx, shift.dy))
        enc.setBytes(&params, length: MemoryLayout<ShiftParams>.stride, index: 0)
        let (tgC, tgS) = dispatchThreadgroups(for: output, pso: pipeline.shiftPipeline)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
    }
}
