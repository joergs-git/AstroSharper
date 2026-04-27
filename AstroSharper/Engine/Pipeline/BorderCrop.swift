// Border crop for deconvolution outputs.
//
// Frequency-domain deconvolution produces edge artifacts: a small ring
// of less-processed pixels along each side of the output. BiggSky's
// documentation recommends cropping a configurable border (default 32
// px on the saved view, 0 on the data raster) so the user never has
// to look at the bad rim.
//
// The actual texture-level crop happens in `ImageTexture.write`; this
// module is the rect-math primitive plus the BiggSky-aligned defaults.
// Pure Foundation / CoreGraphics — no Metal, fully unit-testable.
import CoreGraphics
import Foundation

enum BorderCrop {

    /// BiggSky default for the rendered "view" output (the file users
    /// open in Photoshop / PixInsight). 32 px keeps the rim out of
    /// frame without throwing away meaningful pixels — typical
    /// planetary discs are 200-600 px across, so 32 is < 5%.
    static let defaultViewBorderCropPixels = 32

    /// BiggSky default for the linear "data" output (32-bit float TIFF
    /// destined for further pipeline processing). 0 px so downstream
    /// tools that don't share the deconv-edge pathology still get the
    /// full extent.
    static let defaultDataBorderCropPixels = 0

    /// Compute the inset CGRect a CIImage / CGImage crop needs to apply
    /// to remove `borderPixels` from each side. Negative values are
    /// treated as 0; values that would leave a non-positive dimension
    /// return `nil` so the caller can fall back to "no crop".
    static func cropRect(
        width: Int,
        height: Int,
        borderPixels: Int
    ) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        let safe = max(0, borderPixels)
        let newW = width - 2 * safe
        let newH = height - 2 * safe
        guard newW > 0, newH > 0 else { return nil }
        return CGRect(x: safe, y: safe, width: newW, height: newH)
    }

    /// Convenience: return the post-crop dimensions for telemetry /
    /// HUD display. nil when the crop wouldn't leave anything behind.
    static func croppedDimensions(
        width: Int,
        height: Int,
        borderPixels: Int
    ) -> (width: Int, height: Int)? {
        guard let rect = cropRect(width: width, height: height, borderPixels: borderPixels) else {
            return nil
        }
        return (Int(rect.width), Int(rect.height))
    }
}
