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

    /// Piecewise Catmull-Rom. `t` is in [0,1], uses the segment that contains t.
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
