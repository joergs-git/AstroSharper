// Saturn-style auto-ROI: bounding box of all bright pixels.
//
// Standard AutoROI (high-LAPD-contrast window) fails on Saturn
// because the rings dominate the contrast measure but the regular
// window then either lands on the rings only (missing the globe) or
// gets confused by the ring-globe gap. BiggSky's documented
// workaround is to manually drag the ROI to include both the globe
// AND the rings — a step we automate here by computing a single
// bounding rectangle that covers every "bright" pixel.
//
// Algorithm:
//   1. Find the max luma value in the (downsampled) frame.
//   2. Treat any pixel ≥ `brightnessThreshold × max` as foreground.
//   3. Track min/max x and y across foreground pixels.
//   4. Pad by `padding` and clamp to image bounds.
//   5. Return the bounding ROIRect (or nil if no foreground exists).
//
// No connected-component analysis is needed: even when the rings and
// globe aren't pixel-connected on a sparse-sampled disc, taking the
// bbox of *all* foreground pixels still gives the right answer
// because both regions are bright. This is the BiggSky-recommended
// behaviour for ringed bodies and is also a sane fallback for any
// target where AutoROI's window-based search returns nil.
//
// Pure-CPU + Foundation. The result is in the same coordinate space
// as the input buffer; callers running it on a downsampled probe
// scale the output back to full-res.
import Foundation

enum SaturnROI {

    /// Default brightness fraction. 0.30 of the peak picks up the limb-
    /// darkened ring as well as the globe. Tuned conservatively so a
    /// faint moon transit doesn't silently get clipped into the bbox.
    static let defaultBrightnessThreshold: Float = 0.30

    /// Default padding (pixels) added to each side of the bbox before
    /// the bound clamp. Gives the deconvolution PSF a margin of dark
    /// sky around the bright edges.
    static let defaultPadding: Int = 8

    /// Compute the bounding box of bright pixels.
    ///
    /// - Parameters:
    ///   - luma: row-major luminance buffer (`width * height` Floats).
    ///   - width, height: image dimensions.
    ///   - brightnessThreshold: fraction of the per-frame maximum that
    ///     counts as foreground. Default 0.30. Set lower (0.1) to
    ///     include faint outer rings; higher (0.5) to focus on the
    ///     globe alone.
    ///   - padding: extra pixels added to each side of the bbox.
    /// - Returns: an `ROIRect` for the bright extent, or nil when:
    ///     * the buffer is empty / dimensions invalid
    ///     * the max luma is at-or-below 0 (all-dark image)
    ///     * no foreground pixels are detected (shouldn't happen when
    ///       max > 0 and threshold ≤ 1.0).
    static func bestROI(
        luma: [Float],
        width: Int,
        height: Int,
        brightnessThreshold: Float = defaultBrightnessThreshold,
        padding: Int = defaultPadding
    ) -> ROIRect? {
        precondition(luma.count == width * height, "buffer size mismatch")
        guard width > 0, height > 0 else { return nil }
        guard brightnessThreshold > 0 else { return nil }

        // Pass 1: peak.
        var peak: Float = 0
        for v in luma {
            if v > peak { peak = v }
        }
        guard peak > 0 else { return nil }

        let cutoff = brightnessThreshold * peak

        // Pass 2: bbox of foreground pixels.
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let off = y * width
            for x in 0..<width {
                if luma[off + x] >= cutoff {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Pad + clamp.
        let safePad = max(0, padding)
        let x0 = max(0, minX - safePad)
        let y0 = max(0, minY - safePad)
        let x1 = min(width  - 1, maxX + safePad)
        let y1 = min(height - 1, maxY + safePad)
        return ROIRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }
}
