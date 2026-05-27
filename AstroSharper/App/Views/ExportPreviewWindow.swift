// Post-export preview window — shown after SerExportPanel writes a
// new file. Lets the user inspect the result at native 1:1 and
// decide whether to keep it (move into the project's outputs) or
// discard (delete the file). Until the user picks, the file sits
// in the outputs folder unregistered — Keep just registers it,
// Discard deletes it.
//
// File types handled:
//   - .gif  → animated GIF via NSImageView (built-in animation)
//   - .ser  → static first-frame render via SerFrameLoader, plus a
//             metadata card. SERs aren't natively viewable, so we
//             show frame 0 as a sanity-check on crop/rotation +
//             surface dims / frame count / file size for the
//             keep-or-discard decision.
import SwiftUI
import AppKit
import Metal
import UniformTypeIdentifiers

struct ExportPreviewWindow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// SER-only: the first frame rendered to an NSImage. nil while
    /// loading or for GIF / unknown types.
    @State private var serFrameImage: NSImage? = nil
    @State private var fileSize: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header — what file we're previewing.
            if let url = app.exportPreviewURL {
                HStack(alignment: .firstTextBaseline) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(metadataLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // Body — type-specific preview.
            ZStack {
                Color.black
                if let url = app.exportPreviewURL {
                    if url.pathExtension.lowercased() == "gif" {
                        AnimatedGIFView(url: url)
                    } else if url.pathExtension.lowercased() == "ser" {
                        if let img = serFrameImage {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView("Decoding first frame…")
                                .foregroundColor(.white)
                        }
                    } else {
                        Text("Unknown file type")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minWidth: 400, minHeight: 300)

            // Footer — Keep / Discard buttons.
            HStack {
                Button("Discard") {
                    discardFile()
                }
                .help("Delete the exported file and close this window. Use this when the result isn't what you wanted — go back to the export panel, change settings, and re-export.")
                Spacer()
                Text(actionHint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Keep") {
                    keepFile()
                }
                .keyboardShortcut(.defaultAction)
                .help("Add the exported file to the project's outputs.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear { loadPreview() }
        .onChange(of: app.exportPreviewURL) { _, _ in loadPreview() }
    }

    // MARK: - Actions

    private func keepFile() {
        guard let url = app.exportPreviewURL else { return }
        // Register without auto-switching — keeps the main preview on
        // the source SER so the user can immediately re-export with
        // different settings if they want.
        app.registerOutput(url: url, autoSwitch: false)
        cleanupAndClose()
    }

    private func discardFile() {
        guard let url = app.exportPreviewURL else {
            cleanupAndClose(); return
        }
        try? FileManager.default.removeItem(at: url)
        cleanupAndClose()
    }

    private func cleanupAndClose() {
        app.exportPreviewURL = nil
        serFrameImage = nil
        dismissWindow(id: "export-preview")
    }

    // MARK: - Preview loading

    private func loadPreview() {
        serFrameImage = nil
        guard let url = app.exportPreviewURL else { return }
        // File size for the metadata line.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let sz = (attrs[.size] as? NSNumber)?.int64Value {
            fileSize = sz
        }
        // SER first frame on a background queue — same SerFrameLoader
        // the main preview uses, so format / colour ID / Bayer pattern
        // handling is identical.
        guard url.pathExtension.lowercased() == "ser" else { return }
        let device = MetalDevice.shared.device
        DispatchQueue.global(qos: .userInitiated).async {
            guard let tex = try? SerFrameLoader.loadFrame(url: url, frameIndex: 0, device: device),
                  let img = nsImage(fromMTLTexture: tex)
            else { return }
            DispatchQueue.main.async { self.serFrameImage = img }
        }
    }

    // MARK: - Metadata

    private var actionHint: String {
        guard let url = app.exportPreviewURL else { return "" }
        if url.pathExtension.lowercased() == "gif" {
            return "Animated GIF · loops continuously"
        }
        return "SER · frame 0 shown"
    }

    private var metadataLine: String {
        let sz = formatBytes(fileSize)
        return sz
    }

    private func formatBytes(_ b: Int64) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(b) / (1024.0 * 1024.0)) }
        return String(format: "%.2f GB", Double(b) / (1024.0 * 1024.0 * 1024.0))
    }
}

// MARK: - Animated GIF (NSImageView wrapped)

private struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.image = NSImage(contentsOf: url)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = NSImage(contentsOf: url)
        v.animates = true
    }
}

// MARK: - Metal texture → NSImage (SER first-frame snapshot)

/// Read back an `rgba16Float` MTLTexture into an 8-bit NSImage for
/// display in NSImageView. Used only for the static SER first-frame
/// snapshot, so a slow blit + getBytes is fine.
private func nsImage(fromMTLTexture tex: MTLTexture) -> NSImage? {
    let w = tex.width
    let h = tex.height
    let device = MetalDevice.shared.device
    // Blit into a .shared rgba16Float texture so we can getBytes.
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
    )
    desc.storageMode = .shared
    desc.usage = [.shaderRead, .shaderWrite]
    guard let staging = device.makeTexture(descriptor: desc),
          let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(),
          let blit = cmd.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1),
              to: staging, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let stride = MemoryLayout<UInt16>.stride * 4
    var f16 = [UInt16](repeating: 0, count: w * h * 4)
    f16.withUnsafeMutableBufferPointer { buf in
        staging.getBytes(
            buf.baseAddress!,
            bytesPerRow: w * stride,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: w, height: h, depth: 1)),
            mipmapLevel: 0
        )
    }
    var rgba8 = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        let r = clamp01(Float(Float16(bitPattern: f16[i * 4 + 0])))
        let g = clamp01(Float(Float16(bitPattern: f16[i * 4 + 1])))
        let b = clamp01(Float(Float16(bitPattern: f16[i * 4 + 2])))
        rgba8[i * 4 + 0] = UInt8((r * 255).rounded())
        rgba8[i * 4 + 1] = UInt8((g * 255).rounded())
        rgba8[i * 4 + 2] = UInt8((b * 255).rounded())
        rgba8[i * 4 + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(rgba8) as CFData) else { return nil }
    guard let cg = CGImage(
        width: w, height: h,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent
    ) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
}

@inline(__always)
private func clamp01(_ x: Float) -> Float { max(0, min(1, x)) }
