// TransitProofImage — debug PNG for the transit detector. It renders the
// max-z map (the strongest σ-residual seen at each binned pixel across the
// whole capture) as grayscale, then overlays green markers on detected object
// positions, a red line along each fitted track, and a cyan cross on the target
// (Vega or the disc centre). This was essential for validating the reference
// and stays as an opt-in `--proof out.png` output.
//
// CoreGraphics + ImageIO only (no AppKit), so it links in the CLI target.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TransitProofImage {

    /// Render at the binned resolution. `target` and the maxZ map are in binned
    /// coordinates; event pixel positions are FULL-res and divided by `b` to
    /// map back onto the binned canvas.
    static func write(to url: URL, maxZ: [Float], H: Int, W: Int, b: Int,
                      target: (x: Double, y: Double), events: [TransitEvent]) {
        guard H > 0, W > 0, maxZ.count == H * W else { return }

        // Normalize the max-z map to 0…255 (clip at the 99.5th percentile so a
        // single hot pixel doesn't flatten the whole map).
        var sorted = maxZ
        sorted.sort()
        let hi = max(1e-3, Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))]))
        var rgba = [UInt8](repeating: 0, count: H * W * 4)
        for i in 0..<(H * W) {
            let v = UInt8(max(0, min(255, Int(Double(maxZ[i]) / hi * 255))))
            rgba[i*4+0] = v; rgba[i*4+1] = v; rgba[i*4+2] = v; rgba[i*4+3] = 255
        }

        func plot(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8) {
            guard x >= 0, x < W, y >= 0, y < H else { return }
            let o = (y*W + x) * 4
            rgba[o] = r; rgba[o+1] = g; rgba[o+2] = bl; rgba[o+3] = 255
        }
        func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8) {
            var x0 = x0, y0 = y0
            let dx = abs(x1 - x0), dy = -abs(y1 - y0)
            let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
            var err = dx + dy
            while true {
                plot(x0, y0, r, g, bl)
                if x0 == x1 && y0 == y1 { break }
                let e2 = 2 * err
                if e2 >= dy { err += dy; x0 += sx }
                if e2 <= dx { err += dx; y0 += sy }
            }
        }
        func ring(_ cx: Int, _ cy: Int, _ rad: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8) {
            for a in stride(from: 0.0, to: 2 * Double.pi, by: 0.15) {
                plot(cx + Int(Double(rad) * cos(a)), cy + Int(Double(rad) * sin(a)), r, g, bl)
            }
        }
        func cross(_ cx: Int, _ cy: Int, _ len: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8) {
            line(cx - len, cy, cx + len, cy, r, g, bl)
            line(cx, cy - len, cx, cy + len, r, g, bl)
        }

        // Overlays.
        for e in events {
            if e.moving, let en = e.entryPx, let ex = e.exitPx {
                let x0 = en[0] / b, y0 = en[1] / b, x1 = ex[0] / b, y1 = ex[1] / b
                line(x0, y0, x1, y1, 255, 40, 40)          // red fit line
                ring(x0, y0, 4, 40, 255, 40)               // green endpoints
                ring(x1, y1, 4, 40, 255, 40)
            } else if let en = e.entryPx {
                ring(en[0] / b, en[1] / b, 5, 40, 255, 40)  // green blob marker
            }
        }
        cross(Int(target.x.rounded()), Int(target.y.rounded()), 8, 40, 220, 255)  // cyan target

        // Encode PNG.
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8,
                bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let img = ctx.makeImage() else { return }
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
