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
    /// Compute the shift of `frame` relative to `reference` (i.e. applying
    /// `+shift` to `frame` aligns it to `reference`).
    static func phaseCorrelate(reference: MTLTexture, frame: MTLTexture) -> AlignShift? {
        // Choose a power-of-two working size: largest 2^k <= min(min(dim), 1024).
        let maxDim = min(min(reference.width, reference.height), min(frame.width, frame.height), 1024)
        let log2n = Int(log2(Double(maxDim)))
        let n = 1 << log2n
        guard n >= 64 else { return nil }

        guard let refLum = luminanceBuffer(from: reference, size: n),
              let frameLum = luminanceBuffer(from: frame, size: n)
        else { return nil }

        // Remove DC before windowing. For solar/lunar imagery a bright disk
        // against a black background creates a huge low-frequency component
        // that dominates the cross-power spectrum and pushes the correlation
        // peak around frame-to-frame as the disk's mean brightness changes.
        // Subtracting the mean whitens the spectrum and makes the peak track
        // surface detail (granulation, sunspots, limb edge) rather than the
        // disk's overall luminance.
        subtractMean(&refLum.wrappedValue)
        subtractMean(&frameLum.wrappedValue)

        applyHannWindow(&refLum.wrappedValue, size: n)
        applyHannWindow(&frameLum.wrappedValue, size: n)

        guard let peak = fft2dPhaseCorrelation(ref: refLum.wrappedValue, frame: frameLum.wrappedValue, log2n: log2n) else {
            return nil
        }

        // Integer peak wraps: if >n/2, subtract n (negative shift).
        var dxI = peak.x
        var dyI = peak.y
        if dxI > n / 2 { dxI -= n }
        if dyI > n / 2 { dyI -= n }

        // Scale the shift back to original texture coordinates.
        let scaleX = Float(frame.width) / Float(n)
        let scaleY = Float(frame.height) / Float(n)

        // Parabolic sub-pixel offset around the integer peak uses the correlation surface.
        let subX = peak.subX * scaleX
        let subY = peak.subY * scaleY

        return AlignShift(dx: Float(dxI) * scaleX + subX, dy: Float(dyI) * scaleY + subY)
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

        guard let peak = fft2dPhaseCorrelation(ref: refLum.wrappedValue, frame: frmLum.wrappedValue, log2n: log2n) else {
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

    private static func fft2dPhaseCorrelation(ref: [Float], frame: [Float], log2n: Int) -> Peak? {
        let n = 1 << log2n

        // vDSP splits real arrays into real + imaginary halves for packed format.
        // We take the complex FFT of each image (imag = 0 at input).
        var refReal = ref
        var refImag = [Float](repeating: 0, count: n * n)
        var frmReal = frame
        var frmImag = [Float](repeating: 0, count: n * n)

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n + 1), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        func fft2dForward(_ real: inout [Float], _ imag: inout [Float]) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
        }
        func fft2dInverse(_ real: inout [Float], _ imag: inout [Float]) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                }
            }
        }

        fft2dForward(&refReal, &refImag)
        fft2dForward(&frmReal, &frmImag)

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

        // Peak = max of |cpReal| (imag is noise for a real cross-correlation).
        var peakVal: Float = -.infinity
        var peakIdx = 0
        for k in 0..<count {
            let v = cpReal[k]
            if v > peakVal { peakVal = v; peakIdx = k }
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
