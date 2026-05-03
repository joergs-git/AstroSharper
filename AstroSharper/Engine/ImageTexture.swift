// Robust image I/O: decode any ImageIO-supported file (including single-channel
// 16-bit TIFF as produced by AutoStakkert / FireCapture / PIPP) into a
// rgba16Float Metal texture, and write textures back as 16-bit TIFF / PNG / JPEG.
//
// The loader uses ImageIO + CGImage, then renders into a fresh 16-bit RGBA
// bitmap context. This explicit path handles grayscale by implicitly
// broadcasting luminance to R, G and B — safer than MTKTextureLoader's
// auto-conversion which can end up in r16 formats our pipeline doesn't expect.
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

enum ImageTextureError: Error {
    case cannotOpen(URL)
    case cannotDecode(URL)
    case cannotCreateTexture
    case cannotWrite(URL)
}

enum ImageTexture {
    /// Load an image into an rgba16Float texture. Grayscale sources are
    /// broadcast to R, G, B (alpha = 1). Colour sources use device RGB.
    /// FITS files (`.fits` / `.fit`) skip the CGImageSource path entirely
    /// and delegate to `FitsFrameReader.loadFrame` since CoreGraphics
    /// doesn't grok FITS — without this branch the preview would fail
    /// with `cannotOpen` on every astronomical file from PixInsight /
    /// Siril.
    static func load(url: URL, device: MTLDevice) throws -> MTLTexture {
        let ext = url.pathExtension.lowercased()
        if ext == "fits" || ext == "fit" {
            do {
                let reader = try FitsFrameReader(url: url)
                return try reader.loadFrame(at: 0, device: device)
            } catch {
                throw ImageTextureError.cannotDecode(url)
            }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageTextureError.cannotOpen(url)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageTextureError.cannotDecode(url)
        }

        let w = cg.width
        let h = cg.height

        // Render into a 16-bit-per-channel RGBA bitmap context. Float16 is
        // represented the same way on Apple Silicon; we convert on GPU upload.
        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // kCGBitmapByteOrder16Host + premultipliedLast + FloatComponents
        // gives us 16-bit half-float RGBA in host byte order — exactly what
        // MTLPixelFormat.rgba16Float expects.
        // 16-bit half-float RGBA, host byte order, premultiplied alpha.
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue |
            CGBitmapInfo.floatComponents.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageTextureError.cannotCreateTexture
        }

        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else {
            throw ImageTextureError.cannotDecode(url)
        }

        // Create the destination GPU texture.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private

        guard let dst = device.makeTexture(descriptor: desc) else {
            throw ImageTextureError.cannotCreateTexture
        }

        // Upload via a shared staging texture (private storage can't be written
        // directly from CPU bytes).
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stageDesc) else {
            throw ImageTextureError.cannotCreateTexture
        }
        staging.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        guard
            let queue = device.makeCommandQueue(),
            let cmd = queue.makeCommandBuffer(),
            let blit = cmd.makeBlitCommandEncoder()
        else {
            throw ImageTextureError.cannotCreateTexture
        }
        blit.copy(from: staging, to: dst)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return dst
    }

    /// Cheap variant for analysis-only paths: load via ImageIO's thumbnail
    /// pipeline, capping the longest side at `maxDimension`. Used by the
    /// per-file sharpness probe so a 6 K TIFF doesn't trigger a full decode
    /// just to score a sharpness number — variance-of-Laplacian is largely
    /// scale-invariant on natural content, so 512² is plenty.
    ///
    /// The thumbnail produced by ImageIO is 8-bit RGBA; we promote into the
    /// rgba16Float pipeline format so probe / display code paths don't need
    /// to branch on bit depth. ImageIO does the resampling, so the call is
    /// dominated by I/O rather than CPU.
    static func loadDownsampled(url: URL, maxDimension: Int, device: MTLDevice) throws -> MTLTexture {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageTextureError.cannotOpen(url)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageTextureError.cannotDecode(url)
        }
        let w = cg.width
        let h = cg.height

        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue |
            CGBitmapInfo.floatComponents.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageTextureError.cannotCreateTexture
        }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else {
            throw ImageTextureError.cannotDecode(url)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw ImageTextureError.cannotCreateTexture
        }
        tex.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: w, height: h, depth: 1)),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return tex
    }

    /// Output bit depth for raster file writes.
    ///
    /// - `.uint16`: 16-bit unsigned int per channel. Default for TIFF and
    ///   PNG; pixel values clamp into [0, 65535] before encoding.
    /// - `.float32`: 32-bit float per channel. TIFF only. Required when
    ///   downstream pipeline stages — most notably blind deconvolution —
    ///   push peak intensities above the 16-bit ceiling (BiggSky reports
    ///   peaks routinely 50–100% over the original 16-bit range, i.e.
    ///   well past 65535). Linear-light data is preserved so external
    ///   processing tools (Siril, PixInsight) can apply their own tone
    ///   curves without our 16-bit clamp throwing detail away.
    ///
    /// PNG and JPEG ignore `.float32` and always write 8-bit per the
    /// format spec.
    enum BitDepth: String, Codable {
        case uint16
        case float32
    }

    /// Read a texture back and write to disk.
    ///
    /// TIFF supports `uint16` (default, current pipeline behaviour) and
    /// `float32` (new, for high-dynamic-range deconv outputs). PNG/JPEG
    /// remain 8-bit per the format spec regardless of `bitDepth`.
    ///
    /// `borderCropPixels` removes that many pixels from each side of
    /// the output — used after deconvolution to drop the frequency-
    /// domain edge artifact (BiggSky default 32 for view, 0 for data).
    /// 0 = no crop (default behaviour). Values that would leave a
    /// non-positive dimension are silently ignored.
    static func write(
        texture: MTLTexture,
        to url: URL,
        bitDepth: BitDepth = .uint16,
        borderCropPixels: Int = 0
    ) throws {
        let ciContext = CIContext(mtlDevice: texture.device)
        guard let ci = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            throw ImageTextureError.cannotWrite(url)
        }
        // CIImage from Metal is flipped vertically vs. ImageIO's expectations.
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))

        // Optional border crop. Skipped silently when it would leave a
        // non-positive dimension — caller's intent in that case is "no
        // useful crop possible," fall back to the full image.
        let toEncode: CIImage
        if borderCropPixels > 0,
           let rect = BorderCrop.cropRect(
            width: texture.width,
            height: texture.height,
            borderPixels: borderCropPixels
           ) {
            toEncode = flipped.cropped(to: rect)
        } else {
            toEncode = flipped
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tif", "tiff":
            let format: CIFormat = (bitDepth == .float32) ? .RGBAf : .RGBA16
            try ciContext.writeTIFFRepresentation(of: toEncode, to: url, format: format, colorSpace: colorSpace, options: [:])
        case "png":
            // PNG is always 8-bit; bitDepth has no effect.
            try ciContext.writePNGRepresentation(of: toEncode, to: url, format: .RGBA8, colorSpace: colorSpace, options: [:])
        case "jpg", "jpeg":
            try ciContext.writeJPEGRepresentation(of: toEncode, to: url, colorSpace: colorSpace, options: [:])
        case "fits", "fit":
            // FITS export. Re-renders the (possibly border-cropped)
            // CIImage into a 32-bit float RGBA CPU buffer, collapses to
            // mono via Rec. 709 luma (0.2126/0.7152/0.0722), then hands
            // off to FitsWriter. Linear-light values flow straight
            // through — no sRGB encode — so PixInsight / Siril round-
            // trip the float pixel data without our display-side
            // gamma sneaking in.
            try writeFITS(ci: toEncode, ciContext: ciContext, url: url)
        default:
            // Unknown extension → fall back to TIFF, honouring bit depth.
            let format: CIFormat = (bitDepth == .float32) ? .RGBAf : .RGBA16
            try ciContext.writeTIFFRepresentation(of: toEncode, to: url, format: format, colorSpace: colorSpace, options: [:])
        }
    }

    /// FITS export helper. Pixel values come straight off the CIImage
    /// in linear-light Float32 RGBA, get collapsed to mono, and land
    /// in `FitsImage` with `BITPIX=-32 NAXIS=2`. Metadata: filename
    /// stamp + creator tag so external tools see what produced this.
    private static func writeFITS(ci: CIImage, ciContext: CIContext, url: URL) throws {
        let extent = ci.extent
        let w = Int(extent.width.rounded())
        let h = Int(extent.height.rounded())
        guard w > 0, h > 0 else { throw ImageTextureError.cannotWrite(url) }
        // 4 channels × 4 bytes each. CIContext.render writes RGBA in
        // the supplied colorspace; sticking with linearSRGB keeps the
        // values linear (the same domain the accumulator works in).
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let bytesPerRow = w * 4 * MemoryLayout<Float>.size
        let linearCS = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            ciContext.render(
                ci,
                toBitmap: base,
                rowBytes: bytesPerRow,
                bounds: extent,
                format: .RGBAf,
                colorSpace: linearCS
            )
        }
        // RGBA → mono (Rec. 709 luma). FITS is single-channel; mono
        // captures most of the visible content for the typical
        // monochrome / planetary lucky-stack output.
        var mono = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let off = i * 4
            mono[i] = 0.2126 * rgba[off + 0]
                    + 0.7152 * rgba[off + 1]
                    + 0.0722 * rgba[off + 2]
        }
        let metadata: [String: String] = [
            "CREATOR": "AstroSharper",
            "OBJECT":  url.deletingPathExtension().lastPathComponent,
        ]
        let image = FitsImage(width: w, height: h, pixels: mono, metadata: metadata)
        do {
            try FitsWriter.write(image, to: url)
        } catch {
            throw ImageTextureError.cannotWrite(url)
        }
    }
}
