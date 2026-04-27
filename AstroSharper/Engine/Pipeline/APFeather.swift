// Raised-cosine feather weights for alignment-point patch blending.
//
// The current `lucky_accumulate_with_shifts` Metal kernel blends
// adjacent AP patches with a hard bilinear boundary, which can leave
// visible grid seams on smooth subjects (Jupiter zone boundaries are
// the most-reported case). PSS uses a tapered "feather" so the
// contribution of an AP fades from 1.0 at the centre to 0.0 at the
// far edge of the feather radius — neighbour APs cover the gap, and
// the accumulator divides by the per-pixel weight sum to keep the
// brightness right.
//
// This module provides the CPU reference for the feather profile and
// for the 2D weight map. The Metal kernel that lands when B.2 wires
// into the accumulator mirrors the same maths so visual diffs against
// CPU outputs stay clean.
//
// Pure-Swift / Foundation. No Metal.
import Foundation

enum APFeather {

    /// Raised-cosine weight at a unit distance `t` from the AP centre.
    /// `t = 0` means "centre of AP" → returns 1.0. `t = 1` means "edge
    /// of feather radius" → returns 0.0. Beyond t = 1 returns 0.
    ///
    /// Profile: `0.5 * (1 + cos(π · t))`. Smooth, monotonically
    /// decreasing, derivatives match at the boundary so the feather
    /// blends seamlessly with adjacent APs.
    @inline(__always)
    static func cosineWeight(unitDistance t: Float) -> Float {
        if t <= 0 { return 1 }
        if t >= 1 { return 0 }
        return 0.5 * (1.0 + Foundation.cos(Float.pi * t))
    }

    /// Compute the feather weight for an offset (`dx`, `dy`) from an
    /// AP centre, given the AP's `halfSize` (half the AP edge length
    /// in pixels) and `featherRadius` (additional fall-off zone in
    /// pixels). The profile is rectangular within the inner core
    /// (weight 1.0) and tapers cosine-style across the outer ring.
    ///
    /// Distance metric is Chebyshev (max(|dx|, |dy|)) to match the
    /// rectangular AP cell shape — Euclidean would round the corners
    /// and produce a tighter coverage that doesn't tile.
    static func weight(
        dx: Float,
        dy: Float,
        halfSize: Float,
        featherRadius: Float
    ) -> Float {
        let r = Swift.max(abs(dx), abs(dy))   // Chebyshev distance
        if r <= halfSize { return 1.0 }
        if featherRadius <= 0 { return 0.0 }
        let t = (r - halfSize) / featherRadius
        return cosineWeight(unitDistance: t)
    }

    /// Build a 2D weight map for one AP patch.
    ///
    /// - Parameters:
    ///   - size: edge length of the patch in pixels (full AP size,
    ///     centre at `size / 2`).
    ///   - featherRadius: pixels of feather around the inner core.
    ///     Set 0 to get a hard square (every pixel weight 1.0). Set to
    ///     `size / 2` for "feather all the way to the corners".
    /// - Returns: row-major Float buffer of length `size * size`.
    static func buildWeightMap(
        size: Int,
        featherRadius: Int
    ) -> [Float] {
        guard size > 0 else { return [] }
        var out = [Float](repeating: 0, count: size * size)
        let halfFloat = Float(size) * 0.5
        // Inner-core "halfSize" is how far the weight stays at 1.0.
        // size = innerCore × 2 + featherRadius × 2  → innerCore = halfFloat - featherRadius.
        let innerCore = Swift.max(0, halfFloat - Float(featherRadius))
        let centre = halfFloat - 0.5     // pixel-centre offset
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) - centre
                let dy = Float(y) - centre
                out[y * size + x] = weight(
                    dx: dx, dy: dy,
                    halfSize: innerCore,
                    featherRadius: Float(featherRadius)
                )
            }
        }
        return out
    }

    /// Default feather radius as a fraction of the AP size. The plan
    /// (per `tasks/todo.md`) anchors at `apFeatherRadius = AP_size ×
    /// 0.25`. Surfaced as a constant so the GPU kernel and CPU
    /// reference share one source of truth.
    static let defaultFeatherFraction: Double = 0.25

    /// Convenience: feather radius for a given AP size at the
    /// `defaultFeatherFraction`.
    static func defaultFeatherRadius(forAPSize apSize: Int) -> Int {
        Swift.max(0, Int((Double(apSize) * defaultFeatherFraction).rounded()))
    }
}
