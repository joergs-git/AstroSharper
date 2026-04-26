// Represents the open folder and its image files. Held as a value on AppModel
// so SwiftUI picks up changes through the single enclosing @Published.
import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileEntry: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    let sizeBytes: Int64
    /// Filesystem creation date (or modification date as fallback). Shown in
    /// the list so the user can match outputs to capture sessions.
    let creationDate: Date?
    var status: Status = .idle
    var thumbnail: NSImage?

    /// User flag: this capture was taken after a meridian flip and is
    /// rotated 180° relative to the rest of the session. We rotate at load
    /// time so every consumer (preview, stabilize, lucky-stack, export) sees
    /// a consistent orientation.
    var meridianFlipped: Bool = false

    /// Cached sharpness (variance of Laplacian) for static images. nil for
    /// SER / AVI — those use the distribution-based scan instead. Loaded
    /// in the background after thumbnails so the column populates without
    /// blocking the file list.
    var sharpness: Float? = nil

    /// Lower-cased file extension, exposed for table-column sorting so a
    /// mixed bag of .ser / .tif / .png groups by type when the user clicks
    /// the column header.
    var typeKey: String { url.pathExtension.lowercased() }

    var isSER: Bool { url.pathExtension.lowercased() == FileCatalog.serExtension }
    var isAVI: Bool { url.pathExtension.lowercased() == FileCatalog.aviExtension }
    /// Any frame-sequence container (SER or AVI). Lucky-Stack and the
    /// auto-batch flow both branch on this — the underlying reader is
    /// chosen by the consumer.
    var isFrameSequence: Bool { isSER || isAVI }

    /// Sortable proxy for `creationDate` — Date isn't directly Comparable
    /// against optional. Files with no date sort to the bottom.
    var creationSortKey: TimeInterval {
        creationDate?.timeIntervalSince1970 ?? .infinity
    }

    /// Sortable proxy for `sharpness`. SER / files-without-a-score sort to
    /// the bottom on ascending order so the user sees them last when
    /// looking for the sharpest static frames.
    var sharpnessSortKey: Float {
        sharpness ?? -.infinity
    }

    enum Status: Equatable, Hashable {
        case idle
        case queued
        case processing(progress: Double)
        case done
        case error(String)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: FileEntry, b: FileEntry) -> Bool { a.id == b.id }
}

struct FileCatalog {
    var rootURL: URL?
    var files: [FileEntry] = []

    static let supportedExtensions: Set<String> = [
        "tif", "tiff", "png", "jpg", "jpeg",
        "ser",
        "avi",
    ]
    static let serExtension = "ser"
    static let aviExtension = "avi"

    mutating func load(from folder: URL) {
        rootURL = folder
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            files = []
            return
        }

        files = contents
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in Self.makeEntry(url: url) }
    }

    static func makeEntry(url: URL) -> FileEntry {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: Set(keys))
        let size = (values?.fileSize).flatMap { Int64($0) } ?? 0
        let date = values?.creationDate ?? values?.contentModificationDate
        return FileEntry(id: UUID(), url: url, name: url.lastPathComponent, sizeBytes: size, creationDate: date)
    }

    func index(of id: FileEntry.ID) -> Int? {
        files.firstIndex { $0.id == id }
    }

    /// Replace the catalog with the given list of file URLs (must already be
    /// supported types — the caller filters). The optional root is shown in
    /// the path bar; pass the common parent or the first folder selected.
    mutating func loadURLs(_ urls: [URL], root: URL?) {
        self.rootURL = root
        files = urls
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { Self.makeEntry(url: $0) }
    }
}

// Thumbnail generation — off the main actor, result fed back via callback.
enum ThumbnailLoader {
    static func load(url: URL, maxDimension: CGFloat) -> NSImage? {
        if url.pathExtension.lowercased() == FileCatalog.serExtension {
            return loadSER(url: url, maxDimension: maxDimension)
        }
        // Allow float-component sources — without this, 16-bit RGBA Float
        // TIFFs (which AstroSharper itself writes) can come back saturated
        // white because ImageIO's default thumbnail path skips the tone
        // conversion for float sources.
        let srcOpts: [CFString: Any] = [
            kCGImageSourceShouldAllowFloat: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension * 2,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        // Re-render through an 8-bit RGB context to normalise the dynamic
        // range. CGImage thumbnails of float TIFFs sometimes preserve the
        // raw sample values (e.g. >1.0) and display saturated; rendering
        // into an 8-bit context implicitly clamps to [0,1].
        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: info
        ) {
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let normalised = ctx.makeImage() {
                return NSImage(cgImage: normalised, size: NSSize(width: maxDimension, height: maxDimension))
            }
        }
        return NSImage(cgImage: cg, size: NSSize(width: maxDimension, height: maxDimension))
    }

    /// Read frame 0 of a SER and produce an 8-bit thumbnail. Mono and Bayer
    /// (RGGB / GRBG / GBRG / BGGR) supported — Bayer is downsampled by
    /// stepping in 2-px units across the pattern so each thumbnail pixel
    /// integrates one full RGGB tile (cheap approximation, plenty for the
    /// list view).
    private static func loadSER(url: URL, maxDimension: CGFloat) -> NSImage? {
        guard let reader = try? SerReader(url: url) else { return nil }
        let h = reader.header
        guard h.colorID.isMono || h.colorID.isBayer else { return nil }

        let srcW = h.imageWidth, srcH = h.imageHeight
        let scale = max(1.0, max(Double(srcW), Double(srcH)) / Double(maxDimension * 2))
        let dstW = max(1, Int(Double(srcW) / scale))
        let dstH = max(1, Int(Double(srcH) / scale))

        // For Bayer we need to read 2×2 tiles to recover colour. Snap source
        // step to even multiples so each tile is captured cleanly.
        let bayer = h.colorID.isBayer
        let rOff: (x: Int, y: Int) = {
            switch h.colorID {
            case .bayerRGGB: return (0, 0)
            case .bayerGRBG: return (1, 0)
            case .bayerGBRG: return (0, 1)
            case .bayerBGGR: return (1, 1)
            default:         return (0, 0)
            }
        }()

        var rgba = [UInt8](repeating: 0, count: dstW * dstH * 4)
        reader.withFrameBytes(at: 0) { ptr, _ in
            func sample(_ x: Int, _ y: Int) -> UInt8 {
                let xi = min(srcW - 1, max(0, x))
                let yi = min(srcH - 1, max(0, y))
                let idx = yi * srcW + xi
                if h.bytesPerPlane == 2 {
                    let p16 = ptr.advanced(by: idx * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
                    return UInt8(min(UInt32(p16) >> 8, 255))
                } else {
                    return ptr[idx]
                }
            }

            for y in 0..<dstH {
                let sy = min(srcH - 1, Int(Double(y) * scale))
                for x in 0..<dstW {
                    let sx = min(srcW - 1, Int(Double(x) * scale))
                    let outIdx = (y * dstW + x) * 4
                    if bayer {
                        // Snap to even tile origin for predictable colour.
                        let tx = sx - (sx & 1)
                        let ty = sy - (sy & 1)
                        let r = sample(tx + rOff.x,           ty + rOff.y)
                        let b = sample(tx + (1 - rOff.x),     ty + (1 - rOff.y))
                        let g1 = sample(tx + (1 - rOff.x),    ty + rOff.y)
                        let g2 = sample(tx + rOff.x,          ty + (1 - rOff.y))
                        let g = UInt8((Int(g1) + Int(g2)) >> 1)
                        rgba[outIdx + 0] = r
                        rgba[outIdx + 1] = g
                        rgba[outIdx + 2] = b
                        rgba[outIdx + 3] = 255
                    } else {
                        let v = sample(sx, sy)
                        rgba[outIdx + 0] = v
                        rgba[outIdx + 1] = v
                        rgba[outIdx + 2] = v
                        rgba[outIdx + 3] = 255
                    }
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: dstW, height: dstH, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: dstW * 4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: maxDimension, height: maxDimension))
    }
}
