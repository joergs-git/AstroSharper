// Tone curve: build a 1D 1024-entry LUT from Catmull-Rom-interpolated control
// points, then apply it per-channel in Metal.
import Metal

enum ToneCurveApply {
    static func run(
        input: MTLTexture,
        lut: MTLTexture,
        output: MTLTexture,
        pipeline: Pipeline,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline.tonePipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        enc.setTexture(lut, index: 2)
        let (tgC, tgS) = dispatchThreadgroups(for: output, pso: pipeline.tonePipeline)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
    }
}

/// Per-channel LUT for the Coloring section's Affinity-style curves
/// editor. Builds a 1D `rgba16Float` texture where each input
/// intensity i maps to (R, G, B, 1):
///
///   masterOut(i)  = master_curve(i)
///   LUT[i].r      = r_curve(masterOut(i))
///   LUT[i].g      = g_curve(masterOut(i))
///   LUT[i].b      = b_curve(masterOut(i))
///
/// The Metal `apply_coloring` kernel reads this LUT once per channel
/// (`sample(...).r/.g/.b` separately) — same lookup pattern as the
/// tone-curve LUT, just RGBA-channel-separated instead of broadcast.
enum ColoringLUT {
    static func build(_ coloring: ColoringSettings, device: MTLDevice, size: Int = 1024) -> MTLTexture {
        // Sort + sentinel each curve so the Catmull-Rom evaluator
        // never has to extrapolate past its endpoints.
        let master = endpoint(coloring.masterPoints)
        let r = endpoint(coloring.rPoints)
        let g = endpoint(coloring.gPoints)
        let b = endpoint(coloring.bPoints)

        // Float16 (UInt16 bit pattern) per channel × 4 channels × size.
        var data = [UInt16](repeating: 0, count: size * 4)
        for i in 0..<size {
            let t = Double(i) / Double(size - 1)
            let m = ToneCurveLUT.evaluate(t: t, points: master)
            let rv = Float(ToneCurveLUT.evaluate(t: m, points: r))
            let gv = Float(ToneCurveLUT.evaluate(t: m, points: g))
            let bv = Float(ToneCurveLUT.evaluate(t: m, points: b))
            data[i * 4 + 0] = Float16(rv).bitPattern
            data[i * 4 + 1] = Float16(gv).bitPattern
            data[i * 4 + 2] = Float16(bv).bitPattern
            data[i * 4 + 3] = Float16(1).bitPattern
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D
        desc.pixelFormat = .rgba16Float
        desc.width = size
        desc.height = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        data.withUnsafeBufferPointer { buf in
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: size, height: 1, depth: 1)),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: size * MemoryLayout<UInt16>.size * 4
            )
        }
        return tex
    }

    /// Sort + add (0, y0) / (1, y1) sentinels if missing, so the
    /// Catmull-Rom evaluator never has to extrapolate past the
    /// endpoints. Mirrors ToneCurveLUT.build's behaviour.
    private static func endpoint(_ raw: [CGPoint]) -> [CGPoint] {
        let sorted = raw.sorted { $0.x < $1.x }
        var pts = sorted
        if pts.first?.x != 0 {
            pts.insert(CGPoint(x: 0, y: sorted.first?.y ?? 0), at: 0)
        }
        if pts.last?.x != 1 {
            pts.append(CGPoint(x: 1, y: sorted.last?.y ?? 1))
        }
        return pts
    }
}

enum ToneCurveLUT {
    /// Build a 1D texture of `size` entries (default 1024) representing
    /// a monotonic(-ish) curve that passes through `points` (sorted by x).
    /// Uses a Catmull-Rom interpolation clipped to [0,1].
    static func build(points raw: [CGPoint], device: MTLDevice, size: Int = 1024) -> MTLTexture {
        let sorted = raw.sorted { $0.x < $1.x }
        var pts = sorted
        if pts.first?.x != 0 { pts.insert(CGPoint(x: 0, y: sorted.first?.y ?? 0), at: 0) }
        if pts.last?.x != 1  { pts.append(CGPoint(x: 1, y: sorted.last?.y ?? 1)) }

        var values = [Float](repeating: 0, count: size)
        for i in 0..<size {
            let t = Double(i) / Double(size - 1)
            values[i] = Float(sampleCatmullRom(t: t, points: pts))
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D
        desc.pixelFormat = .r32Float
        desc.width = size
        desc.height = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        values.withUnsafeBufferPointer { buf in
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: size, height: 1, depth: 1)),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: size * MemoryLayout<Float>.size
            )
        }
        return tex
    }

    /// Solar Dual-Zone LUT (validated 2026-05-24 on
    /// TESTIMAGES/sun/14_09_57_fulldisc.ser): a solar Hα capture has its
    /// disc fill the upper-half of the [0,1] range and its faint off-limb
    /// prominences in the lower-half. The standard linear-display crushes
    /// off-limb into pure black. This LUT compresses the dark off-limb
    /// data via asinh so prominences pop, while preserving the disc
    /// surface (granulation, sunspots) via a linear pass-through of the
    /// upper half. Spatial decision is value-based (any pixel < 0.5 =
    /// off-limb), so a per-pixel LUT works — no segmentation needed.
    static func buildSolarDualZone(device: MTLDevice, size: Int = 1024) -> MTLTexture {
        var values = [Float](repeating: 0, count: size)
        let beta: Float = 20.0
        let asinhBeta = log(beta + sqrt(beta * beta + 1))   // arsinh(beta) precomputed
        for i in 0..<size {
            let t = Float(i) / Float(size - 1)   // 0..1 input value
            if t < 0.5 {
                // Off-limb: asinh-stretch [0..0.5] → [0..0.5] output.
                // The stretch lifts low values (faint prominences) while
                // compressing very-low values (noise floor) so the
                // background stays dark grey, not noisy grey.
                let n = t * 2.0                  // 0..1 in off-limb space
                let stretched = log(n * beta + sqrt((n * beta) * (n * beta) + 1)) / asinhBeta
                values[i] = stretched * 0.5
            } else {
                // Disc: linear [0.5..1.0] input → [0.5..1.0] output.
                // Granulation and sunspot detail pass through unchanged.
                values[i] = t
            }
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D
        desc.pixelFormat = .r32Float
        desc.width = size
        desc.height = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        values.withUnsafeBufferPointer { buf in
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: size, height: 1, depth: 1)),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: size * MemoryLayout<Float>.size
            )
        }
        return tex
    }

    /// Piecewise Catmull-Rom. `t` is in [0,1], uses the segment that contains t.
    /// Internal-ish — exposed via `evaluate(t:points:)` so the Coloring
    /// LUT builder (which composes 2 curves per channel) can reuse the
    /// same interpolation as the tone curve editor preview.
    static func evaluate(t: Double, points: [CGPoint]) -> Double {
        sampleCatmullRom(t: t, points: points)
    }

    private static func sampleCatmullRom(t: Double, points: [CGPoint]) -> Double {
        guard points.count >= 2 else { return t }
        // Find segment [i, i+1] such that p[i].x <= t <= p[i+1].x
        var i = 0
        for k in 0..<(points.count - 1) where t >= Double(points[k].x) && t <= Double(points[k + 1].x) {
            i = k; break
        }
        let p0 = points[max(i - 1, 0)]
        let p1 = points[i]
        let p2 = points[min(i + 1, points.count - 1)]
        let p3 = points[min(i + 2, points.count - 1)]

        let segLen = max(Double(p2.x - p1.x), 1e-6)
        let u = (t - Double(p1.x)) / segLen  // 0..1 inside segment

        // Centripetal Catmull-Rom (alpha=0.5) — stable, no self-intersections.
        let y = 0.5 * (
            (2.0 * Double(p1.y)) +
            (-Double(p0.y) + Double(p2.y)) * u +
            (2.0 * Double(p0.y) - 5.0 * Double(p1.y) + 4.0 * Double(p2.y) - Double(p3.y)) * u * u +
            (-Double(p0.y) + 3.0 * Double(p1.y) - 3.0 * Double(p2.y) + Double(p3.y)) * u * u * u
        )
        return max(0.0, min(1.0, y))
    }
}
