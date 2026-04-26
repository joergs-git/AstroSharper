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
    static func load(url: URL, device: MTLDevice) throws -> MTLTexture {
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

    /// Read a texture back and write to disk. TIFF preserves 16-bit; PNG/JPEG are 8-bit.
    static func write(texture: MTLTexture, to url: URL) throws {
        let ciContext = CIContext(mtlDevice: texture.device)
        guard let ci = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            throw ImageTextureError.cannotWrite(url)
        }
        // CIImage from Metal is flipped vertically vs. ImageIO's expectations.
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tif", "tiff":
            try ciContext.writeTIFFRepresentation(of: flipped, to: url, format: .RGBA16, colorSpace: colorSpace, options: [:])
        case "png":
            try ciContext.writePNGRepresentation(of: flipped, to: url, format: .RGBA8, colorSpace: colorSpace, options: [:])
        case "jpg", "jpeg":
            try ciContext.writeJPEGRepresentation(of: flipped, to: url, colorSpace: colorSpace, options: [:])
        default:
            try ciContext.writeTIFFRepresentation(of: flipped, to: url, format: .RGBA16, colorSpace: colorSpace, options: [:])
        }
    }
}
