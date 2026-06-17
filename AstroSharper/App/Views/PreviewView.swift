// Metal-backed preview with Photoshop-style zoom/pan interaction.
//
//   - Left-drag horizontal: zoom (right = zoom in, left = zoom out).
//   - Double-click: reset to fit.
//   - Option + drag: pan.
//   - Trackpad pinch (magnify): zoom around the cursor.
//   - Scroll wheel when zoomed: pan.
//   - Before/After toggle shows the original or the processed texture fullscreen.
//
// Processing is throttled to ~30 Hz during continuous slider drag with the
// "latest value wins" semantic, so the preview never blocks the UI thread.
import AppKit
import Combine
import MetalKit
import SwiftUI

struct PreviewView: View {
    @EnvironmentObject private var app: AppModel

    /// Thumbnail of the previewed file. Currently unused (mini-map is
    /// disabled) — kept for the eventual revival of `PreviewMiniMap`.
    private var currentThumbnail: NSImage? {
        guard let id = app.previewFileID else { return nil }
        return app.catalog.files.first(where: { $0.id == id })?.thumbnail
    }

    /// Drives whether the HUD's "Calculate Video Quality" button is
    /// offered — quality scanning is currently SER-only.
    private var currentEntryIsSER: Bool {
        guard let id = app.previewFileID else { return false }
        return app.catalog.files.first(where: { $0.id == id })?.isSER ?? false
    }

    var body: some View {
        MetalPreviewRepresentable()
            .background(Color.black)
            .overlay(placeholderOverlay)
            .overlay {
                // Live crop overlay — only when the user has set a crop
                // rect via the Export panel. The source pixel coords get
                // mapped to view coords using the same uniform letterbox
                // fit logic the Metal shader uses (no distortion).
                if let r = app.serCropRect,
                   let dim = app.previewStats.dimensions,
                   dim.width > 0 && dim.height > 0 {
                    Self.cropOverlay(rectInSource: r, srcW: dim.width, srcH: dim.height)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if app.hudVisible && app.previewFileID != nil {
                    PreviewStatsHUD(
                        stats: app.previewStats,
                        onCalculateVideoQuality: currentEntryIsSER && app.previewStats.totalFrames > 1
                            ? { app.calculateVideoQualityForCurrentFile() }
                            : nil,
                        isScanning: app.isCalculatingVideoQuality,
                        stabilizerShifts: app.lastStabilizerShifts
                    )
                    .transition(.opacity)
                }
            }
            // Top-right activity indicator. The preview pipeline already
            // ran async on a background queue, but the user had no
            // visual signal that work was happening — slider drags felt
            // sluggish even when the result was actually being computed.
            // The spinner fades in via animation so a sub-50 ms pass
            // doesn't even render it; on slower passes (Wiener at full-
            // res, big LR loop) it sits there until the result lands.
            .overlay(alignment: .topTrailing) {
                if app.processingInFlight {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                        Text("Processing…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: app.processingInFlight)
            // Centered job-progress overlay. Different from the top-right
            // "Processing…" capsule (which is for sub-second live-preview
            // re-runs) — this one fires on multi-file batch jobs (Lucky
            // Stack, Apply, Stabilize). Big circular spinner + processed/
            // total + linear bar so the user sees from any zoom level
            // exactly how much is left. Fades in/out via animation.
            .overlay {
                if case let .running(processed, total) = app.jobStatus {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.6)
                            .controlSize(.large)
                        Text(jobOverlayLabel(processed: processed, total: total))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                        ProgressView(
                            value: Double(processed),
                            total: Double(max(total, 1))
                        )
                        .progressViewStyle(.linear)
                        .frame(width: 280, height: 6)
                        .tint(AppPalette.accent)

                        // Stop button — aborts the in-flight stack. The
                        // engine polls cancellation per frame, so it
                        // unwinds promptly and removes any partial output.
                        Button(role: .destructive) {
                            app.cancelLuckyStack()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.regular)
                        .padding(.top, 2)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: app.jobStatus)
            // Preview-loading overlay. Shows while a freshly-clicked
            // frame-sequence file is being read into a texture — critical
            // for NAS-mounted SERs where the first-frame page-fault read
            // can take 1-3 seconds. Without this the user sees a black
            // canvas and assumes the app is broken. Indeterminate bar
            // because we don't know the actual byte progress (Foundation
            // mmap doesn't expose it).
            .overlay {
                if app.isLoadingPreview {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.4)
                            .controlSize(.large)
                        Text("Loading preview…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        if let label = app.loadingPreviewLabel {
                            Text(label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(width: 280)
                            .tint(AppPalette.accent)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: app.isLoadingPreview)
            // Preview-load error banner. Surfaces SerFrameLoader /
            // SerReader / AviReader / ImageTexture failures (unsupported
            // ColorID, corrupt header, RGB SER not yet implemented) so
            // the user sees what went wrong instead of a black canvas
            // with the file silently rejected. Auto-clears the next time
            // a successful load lands.
            .overlay(alignment: .top) {
                if let err = app.previewError, !app.isLoadingPreview {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 16, weight: .semibold))
                        Text(err)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            app.previewError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 540)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.yellow.opacity(0.55), lineWidth: 1)
                    )
                    .padding(.top, 16)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: app.previewError)
            // Preemptive "pick a target" banner. Appears any time the user
            // has SER input loaded but hasn't picked a target preset —
            // before they press Run Lucky Stack and bounce off the
            // .error("Pick a target first") status-bar message that was
            // too easy to miss (low contrast text in the menubar). Big +
            // red + dead centre over the preview makes the next step
            // unmistakable. Auto-clears the moment the user clicks a
            // target chip; never blocks the preview itself (lower z).
            .overlay(alignment: .top) {
                if needsTargetPickWarning {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 22, weight: .bold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pick a target first")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Text("Click one of the planet / Sun / Moon chips at the top of the window before Run Lucky Stack.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 620)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.30), lineWidth: 1)
                    )
                    .padding(.top, 56)   // sit below the previewError banner if both fire
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)   // never block the preview underneath
                }
            }
            .animation(.easeInOut(duration: 0.22), value: needsTargetPickWarning)
            // Mini-map overlay was disabled — pan/zoom recomputed it on
            // every drag tick, and the user found it slow without
            // commensurate value. The view + computation helpers stay in
            // the codebase (PreviewMiniMap.swift, publishViewport()) for
            // future revival.
            .environmentObject(app)
    }

    /// True when the user has SER input visible (Inputs section + at
    /// least one .ser in the catalog) but no target preset is active.
    /// The Lucky Stack run will reject in that state — surface it
    /// preemptively so the user can fix it before pressing Run.
    private var needsTargetPickWarning: Bool {
        guard app.displayedSection == .inputs else { return false }
        guard app.presets.activeID == nil else { return false }
        return app.catalog.files.contains { $0.isSER }
    }

    private func jobOverlayLabel(processed: Int, total: Int) -> String {
        if total <= 0 { return "Working…" }
        let pct = Int(Double(processed) / Double(total) * 100)
        return "\(processed)/\(total)  ·  \(pct)%"
    }

    @ViewBuilder
    private var placeholderOverlay: some View {
        if app.previewFileID == nil {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No file selected")
                    .foregroundColor(.secondary)
                Text("Open a folder with ⌘O or drag one in")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    /// Visualise the crop rect over the preview. The Metal shader uses
    /// a uniform letterbox fit (no axis distortion), so we replicate
    /// that math here: scale = min(viewW/srcW, viewH/srcH), then center
    /// the fitted content. Outside the rect we tint dim, inside we draw
    /// a thin yellow stroke with corner ticks so the user can see crop
    /// edges even at low zoom.
    @ViewBuilder
    static func cropOverlay(rectInSource r: CGRect, srcW: Int, srcH: Int) -> some View {
        GeometryReader { geo in
            let viewW = geo.size.width
            let viewH = geo.size.height
            let sw = CGFloat(srcW)
            let sh = CGFloat(srcH)
            let scale = min(viewW / sw, viewH / sh)
            let fittedW = sw * scale
            let fittedH = sh * scale
            let offsetX = (viewW - fittedW) * 0.5
            let offsetY = (viewH - fittedH) * 0.5
            let cropX = offsetX + r.origin.x * scale
            let cropY = offsetY + r.origin.y * scale
            let cropW = r.width * scale
            let cropH = r.height * scale

            ZStack(alignment: .topLeading) {
                // Dim outside the crop window. A single black-with-alpha
                // mask, with the crop rect blendModed back to clear so
                // only the surround stays dimmed.
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .mask {
                        Rectangle()
                            .overlay(
                                Rectangle()
                                    .frame(width: max(0, cropW), height: max(0, cropH))
                                    .position(x: cropX + cropW * 0.5, y: cropY + cropH * 0.5)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    }
                // Inside-rect stroke.
                Rectangle()
                    .stroke(Color.yellow.opacity(0.9), lineWidth: 1.5)
                    .frame(width: max(0, cropW), height: max(0, cropH))
                    .position(x: cropX + cropW * 0.5, y: cropY + cropH * 0.5)
            }
        }
    }
}

// MARK: - Representable

private struct MetalPreviewRepresentable: NSViewRepresentable {
    @EnvironmentObject private var app: AppModel

    func makeCoordinator() -> PreviewCoordinator {
        PreviewCoordinator(app: app)
    }

    func makeNSView(context: Context) -> ZoomableMTKView {
        let view = ZoomableMTKView(frame: .zero, device: MetalDevice.shared.device)
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        // Tag the swap chain as plain sRGB. With `rgba16Float` the default
        // is `extendedLinearSRGB`, which makes the compositor apply an
        // implicit sRGB encode (pow ., 1/2.2) on the shader's output. That
        // double-encodes any sRGB-tagged data we already loaded straight
        // from a TIFF (CoreGraphics linearises on decode → pow back in
        // shader → compositor encodes again), and the displayed image
        // ends up either too dark or too bright depending on which side
        // of the chain we touched. Setting the layer colorspace to sRGB
        // makes the compositor a pass-through: whatever bytes the shader
        // writes are interpreted directly as sRGB display values, exactly
        // like Preview.app / Photoshop drawing the same TIFF.
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        // Drive on demand. Continuous 60 fps was redundant — the display
        // shader only changes when textures or zoom/pan do, and free-running
        // burned cycles during window resize, making large SERs feel sluggish
        // to drag-resize. Every mutation site already calls needsDisplay = true.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: ZoomableMTKView, context: Context) {
        context.coordinator.syncFromModel()
    }
}

// MARK: - Coordinator (renderer + reprocessor)

@MainActor
final class PreviewCoordinator: NSObject, MTKViewDelegate {
    weak var view: ZoomableMTKView?
    private unowned let app: AppModel
    private var cancellables: Set<AnyCancellable> = []

    private let pipeline: Pipeline
    private var displayPSO: MTLRenderPipelineState?

    // Textures
    private var beforeTex: MTLTexture?
    private var afterTex: MTLTexture?
    private var currentFileID: UUID?

    // HUD support — opt-in SER distribution scanner only. The previous
    // per-frame sharpness probe was removed in favour of explicit "Calculate
    // Video Quality" because at full source resolution it spent 5-30 ms on
    // every file/frame switch and made browsing large SERs feel laggy.
    private let qualityScanner = SerQualityScanner()

    /// LRU + 4-frame look-ahead cache for SER playback. Hits the cache
    /// instead of disk on the timer's hot tick path; the prefetch
    /// keeps the next 4 upcoming frames warm so NAS-based SERs don't
    /// freeze on per-frame I/O.
    private let serPrefetcher = SerFramePrefetcher(device: MetalDevice.shared.device)
    /// CPU-side low-res scrub cache — no Metal-kernel contention with
    /// the full-res prefetcher / main load. Drives drag-preview on
    /// 4 GB+ SERs where full-res decodes are too slow per scrub step.
    private let serScrubCache = SerScrubLowResCache(device: MetalDevice.shared.device)
    /// Persistent low-res proxy atlas (opt-in, cached on disk). Owned by
    /// AppModel so the opt-in BUILD (AppModel.buildScrubProxy) and this
    /// read path share one instance — after a build, AppModel re-opens it
    /// and scrubbing immediately hits decode-free thumbnails. READ-ONLY
    /// preview accelerator: never touches markers / export.
    private var serProxyAtlas: ScrubProxyAtlas { app.scrubProxyAtlas }

    /// Texture pixel dimensions of the currently-shown preview, exposed so
    /// the ZoomableMTKView can compute fit-scale for anchored zooming.
    var texturePixelSize: CGSize? {
        guard let tex = beforeTex else { return nil }
        return CGSize(width: tex.width, height: tex.height)
    }

    /// Compute the visible-image sub-region in normalised image coordinates
    /// (0…1, top-left origin) and publish it to AppModel for the mini-map
    /// overlay. nil when the whole image fits in the view at the current
    /// zoom (mini-map is hidden in that case).
    func publishViewport() {
        guard let tex = beforeTex, let view = view else {
            app.previewViewport = nil
            return
        }
        let texW = CGFloat(tex.width), texH = CGFloat(tex.height)
        let viewW = view.drawableSize.width, viewH = view.drawableSize.height
        guard texW > 0, texH > 0, viewW > 0, viewH > 0 else {
            app.previewViewport = nil; return
        }
        let fit = min(viewW / texW, viewH / texH)
        let effScale = fit * CGFloat(zoomScale)
        guard effScale > 0 else { app.previewViewport = nil; return }
        let fracW = min(1.0, viewW / (texW * effScale))
        let fracH = min(1.0, viewH / (texH * effScale))
        // Hide the mini-map when nothing is cropped — full image visible.
        if fracW >= 0.999 && fracH >= 0.999 {
            app.previewViewport = nil
            return
        }
        // Centre of viewport in normalised image coords. Sign matches the
        // display shader's panPx convention (positive panPx.x shifts image
        // RIGHT on screen, so the viewport sees content LEFT of centre).
        var cx = 0.5 - CGFloat(panPx.x) / (texW * effScale)
        var cy = 0.5 - CGFloat(panPx.y) / (texH * effScale)
        let halfW = fracW / 2, halfH = fracH / 2
        cx = min(1 - halfW, max(halfW, cx))
        cy = min(1 - halfH, max(halfH, cy))
        app.previewViewport = CGRect(x: cx - halfW, y: cy - halfH, width: fracW, height: fracH)
    }

    // Re-process trigger (throttled for "instant" slider feedback).
    // Two derived streams from this subject:
    //   - throttle 33 ms (latest wins) → live preview path with `preview: true`
    //     so Wiener uses the 50%-downsampled FFT and stays under the 30 Hz
    //     budget during continuous drag.
    //   - debounce 200 ms → drag-end path with `preview: false`, so the
    //     final image is full-res Wiener once the user lets go.
    private let reprocessSubject = PassthroughSubject<Void, Never>()

    /// Fires after the user STOPS scrubbing a SER (debounced). During a
    /// fast-forward the per-frame path only paints the raw decoded frame
    /// (instant); the expensive auto-range percentile recompute + full
    /// sharpen / tone pipeline run ONCE here when the scrub settles. This
    /// is what keeps manual fast-forward usable as a quick visual scan on
    /// large SERs — running both per frame at 30 fps was the lag.
    private let serScrubSettleSubject = PassthroughSubject<Void, Never>()

    /// Monotonic dispatch counter for SER frame loads. Each scrub /
    /// playback frame request bumps it; `applyLoadedSerFrame` only paints
    /// when the arriving frame's sequence is the newest seen, so an
    /// earlier-dispatched frame that finishes LATE (out of order) is
    /// dropped — preventing the preview from flicking backwards — while
    /// every in-flight frame that IS the latest still paints. Replaces
    /// the old strict `index == dispatchedIndex` guard, which dropped
    /// every intermediate frame during a fast scrub (so nothing moved on
    /// screen until the user stopped).
    private var serDispatchSeq: Int = 0
    private var lastPaintedScrubSeq: Int = 0
    /// Wall-clock of the last scrub-driven frame load. Used to rate-limit
    /// the synchronous scrub sink to ~30 decodes/s without a scheduler
    /// timer (which would stall inside the slider's modal tracking loop).
    private var lastScrubLoadTime: CFTimeInterval = 0

    // Zoom / pan state — UI lives here, MTKView queries via draw().
    var zoomScale: Float = 1.0
    var panPx: SIMD2<Float> = .zero

    // Tone curve LUT cache
    private var lutTex: MTLTexture?
    private var lastLUTPoints: [CGPoint] = []
    /// Tracks whether the cached `lutTex` was built via Solar Dual-Zone
    /// (fixed asinh + linear curve) vs the standard control-points
    /// Catmull-Rom path. Used to invalidate the cache when the user
    /// toggles between the two.
    private var lastLUTSolarDualZone: Bool = false

    init(app: AppModel) {
        self.app = app
        self.pipeline = Pipeline()
        super.init()
        buildDisplayPSO()
        subscribe()
    }

    private func buildDisplayPSO() {
        guard let lib = MetalDevice.shared.library else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "display_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "display_fragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        displayPSO = try? MetalDevice.shared.device.makeRenderPipelineState(descriptor: desc)
    }

    func attach(view: ZoomableMTKView) {
        self.view = view
    }

    private func subscribe() {
        // Use throttle(latest: true) to feed one update every ~33ms with the
        // latest parameters — smoother than debounce for continuous slider use.
        let trigger = reprocessSubject
            .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)

        app.$sharpen.removeDuplicates()
            .sink { [weak self] _ in self?.reprocessSubject.send(()) }
            .store(in: &cancellables)
        app.$toneCurve.removeDuplicates()
            .sink { [weak self] _ in self?.reprocessSubject.send(()) }
            .store(in: &cancellables)
        app.$coloring.removeDuplicates()
            .sink { [weak self] _ in self?.reprocessSubject.send(()) }
            .store(in: &cancellables)
        app.$previewFileID.removeDuplicates()
            .sink { [weak self] _ in self?.loadCurrentFile() }
            .store(in: &cancellables)
        // Section switch: force a preview refresh so leaving the Memory tab
        // immediately shows the file-list-selected file from Inputs/Outputs
        // (otherwise the last in-memory texture lingers).
        app.$displayedSection.removeDuplicates()
            .sink { [weak self] _ in
                self?.currentFileID = nil   // bypass the cache check
                self?.loadCurrentFile()
            }
            .store(in: &cancellables)
        // Compare side panel toggle was previously wired to a Before/After
        // main-view flip via `app.$showAfter`. The flip was retired
        // 2026-05-03 — main view always shows the manipulated result;
        // comparison happens via the dedicated side panel instead.
        // displayAutoRange toggle: just trigger a redraw — the cached
        // percentiles are reused, no recompute needed.
        app.$displayAutoRange
            .removeDuplicates()
            .sink { [weak self] _ in self?.view?.needsDisplay = true }
            .store(in: &cancellables)
        // Highlight-clipped overlay toggle (LSW 8.8) — purely visual,
        // just nudges the MTKView to redraw with the new uniform.
        app.$highlightClipped
            .removeDuplicates()
            .sink { [weak self] _ in self?.view?.needsDisplay = true }
            .store(in: &cancellables)
        // displayGain slider: redraw on every change. Throttle so a
        // continuous drag doesn't thrash the GPU (display path is cheap
        // but the shader recompiles uniform buffers per frame anyway).
        app.$displayGain
            .removeDuplicates()
            .throttle(for: .milliseconds(16), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.view?.needsDisplay = true }
            .store(in: &cancellables)
        // SER frame scrub. Deliberately a SYNCHRONOUS sink with a manual
        // time-gate rather than a Combine `.throttle(scheduler:)`. A
        // SwiftUI Slider drag runs a modal NSEventTrackingRunLoopMode
        // loop; the throttle's scheduler-timer doesn't fire in that mode,
        // so it held every intermediate value and only emitted on
        // release — the preview looked frozen until you let go. A plain
        // @Published sink fires inline on the set (during tracking too);
        // we rate-limit by wall-clock so a 5000-frame drag still only
        // decodes ~30×/s. The settle subject lands the exact final frame
        // + the full pipeline once the drag stops.
        app.$previewSerFrameIndex
            .removeDuplicates()
            .sink { [weak self] _ in self?.serScrubIndexChanged() }
            .store(in: &cancellables)

        // Drag release: when isSerScrubbing flips true → false, the
        // settle subject fires a full-res decode of the LANDED frame
        // (no longer the nearest-cached neighbour the drag showed).
        app.$isSerScrubbing
            .removeDuplicates()
            .sink { [weak self] dragging in
                if !dragging { self?.serScrubSettleSubject.send(()) }
            }
            .store(in: &cancellables)
        // SER playback stopped → run the percentile recompute + pipeline
        // on whichever frame the user landed on. During playback both are
        // skipped (NAS reads cap at much lower fps than the timer wants),
        // so the current beforeTex is unprocessed when the user pauses.
        app.$serPlaybackActive
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                // Tune the prefetcher's look-ahead — playback needs a
                // deeper buffer than scrubbing so the (now bounded-
                // parallel) decode queue can stay ahead of the timer.
                self.serPrefetcher.setPlaybackMode(active)
                if active {
                    let idx = self.app.previewSerFrameIndex
                    let total = self.app.previewSerFrameCount
                    // Fire prefetch on BOTH caches. The full-res
                    // prefetcher has 12-deep lookahead; the low-res
                    // cache materialises thumbs around the playhead
                    // so playbackPaintCachedFrame's tier-2 fallback
                    // has something to show on cache misses (avoids
                    // the "Standbild for the first 3 runs" symptom).
                    self.serPrefetcher.prefetch(after: idx, totalFrames: total)
                    // Request low-res thumbs around the playhead so
                    // tier-2 has neighbours to fall back on.
                    let lowResBudget = 8
                    for off in 0..<lowResBudget {
                        let i = (idx + off) % max(1, total)
                        self.serScrubCache.requestThumb(at: i)
                    }
                    return
                }
                // Playback STOP — settle the landed frame with the
                // full pipeline.
                guard self.beforeTex != nil else { return }
                self.refreshDisplayAutoRange()
                self.view?.needsDisplay = true
                self.reprocess()
            }
            .store(in: &cancellables)
        // Playback: when the current playback frame index changes, swap the
        // source texture and re-run the pipeline.
        app.$playback
            .map { ($0.currentIndex, $0.frames.count) }
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] _ in self?.onPlaybackFrameChanged() }
            .store(in: &cancellables)

        trigger
            .sink { [weak self] in self?.reprocess(preview: true) }
            .store(in: &cancellables)

        // Drag-end debounce: 200 ms after the user stops touching sliders,
        // re-run with `preview: false` so the final image lands as full-res
        // Wiener. The throttle path keeps the live preview cheap; this
        // debounce path "polishes" the result once the drag ends. If the
        // pipeline doesn't actually use Wiener, this is a redundant pass —
        // negligible cost for non-Wiener pipelines, but it keeps the
        // wiring uniform.
        reprocessSubject
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reprocess(preview: false) }
            .store(in: &cancellables)

        // SER scrub-settle: 160 ms after the user stops fast-forwarding,
        // run the auto-range recompute + full pipeline once on the landed
        // frame. During the scrub itself `applyLoadedSerFrame` only paints
        // the raw frame, so flipping through thousands of large frames
        // stays instant for visual scanning.
        serScrubSettleSubject
            .debounce(for: .milliseconds(160), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, !self.app.serPlaybackActive else { return }
                // Land the EXACT final frame first (the last scrub index
                // change may have been rate-limited out), then run the
                // auto-range recompute + full sharpen / tone pipeline once.
                self.loadCurrentSerFrame()
                guard self.beforeTex != nil else { return }
                self.refreshDisplayAutoRange()
                self.view?.needsDisplay = true
                self.reprocess()
            }
            .store(in: &cancellables)

        // Zoom shortcuts (⌘+ ⌘- ⌘0 ⌘1 ⌘2). The View menu posts a
        // PreviewZoomCommand value; we apply it here so the menu code
        // never has to know about the MTKView at all.
        NotificationCenter.default.publisher(for: .previewZoomCommand)
            .compactMap { $0.object as? PreviewZoomCommand }
            .sink { [weak self] cmd in self?.applyZoomCommand(cmd) }
            .store(in: &cancellables)

        // ROI-capture handler. The Stabilize section's "Lock current view
        // as ROI" button posts this; we snapshot the current viewport
        // (zoom + pan) into normalised reference-frame coordinates and
        // write it back into AppModel.stabilize.roi.
        NotificationCenter.default.publisher(for: .stabilizeCaptureROI)
            .sink { [weak self] _ in self?.captureCurrentViewportAsROI() }
            .store(in: &cancellables)
    }

    /// Convert the current zoom + pan state into a normalised rect on the
    /// reference image. The display shader fits the texture to the view
    /// at `zoomScale = 1`; visible texture rect = full image / zoom,
    /// shifted by panPx (in drawable pixels). We invert that to get the
    /// portion of the source actually shown, then divide by tex size for
    /// normalised coords.
    private func captureCurrentViewportAsROI() {
        guard let beforeTex else { return }
        let texW = Float(beforeTex.width), texH = Float(beforeTex.height)
        let z = max(zoomScale, 0.0001)
        // Visible texture span (in tex pixels) = tex / zoom. Centred unless panPx != 0.
        let visW = texW / z
        let visH = texH / z
        // panPx is expressed in drawable pixels; convert to texture pixels
        // using the fit ratio. At z=1 the texture covers the full view, so
        // 1 drawable px = (texW / viewW) tex px (axis-wise). Approximated
        // with the smaller side fit ratio for symmetry.
        let view = self.view
        let viewW = Float(view?.drawableSize.width ?? 1)
        let viewH = Float(view?.drawableSize.height ?? 1)
        let fit = min(viewW / texW, viewH / texH)
        let panTexX = panPx.x / max(fit, 1e-6) / z
        let panTexY = panPx.y / max(fit, 1e-6) / z
        let cx = texW * 0.5 - panTexX
        let cy = texH * 0.5 - panTexY
        let originX = max(0, cx - visW * 0.5)
        let originY = max(0, cy - visH * 0.5)
        let nx = Double(originX / texW)
        let ny = Double(originY / texH)
        let nw = Double(min(visW, texW) / texW)
        let nh = Double(min(visH, texH) / texH)
        DispatchQueue.main.async {
            self.app.stabilize.roi = NormalisedRect(x: nx, y: ny, w: nw, h: nh)
        }
    }

    private func applyZoomCommand(_ cmd: PreviewZoomCommand) {
        guard let view = self.view else { return }
        let texW = Float(beforeTex?.width ?? 0)
        let texH = Float(beforeTex?.height ?? 0)
        let viewW = Float(view.drawableSize.width)
        let viewH = Float(view.drawableSize.height)

        // The display shader treats `zoomScale = 1` as "fit-to-view" already
        // (vertex stage scales texSize → viewSize). So 1:1 means we have to
        // ask "how much do we need to multiply the fit so one tex pixel maps
        // to one drawable pixel?" — that's `min(texW/viewW, texH/viewH)`'s
        // inverse, which is `max(viewW/texW, viewH/texH)`.
        func oneToOneScale() -> Float {
            guard texW > 0, texH > 0, viewW > 0, viewH > 0 else { return 1 }
            return max(viewW / texW, viewH / texH)
        }

        switch cmd {
        case .zoomIn:
            zoomScale = min(zoomScale * 1.25, 64)
        case .zoomOut:
            zoomScale = max(zoomScale / 1.25, 0.1)
        case .fit:
            zoomScale = 1
            panPx = .zero
        case .oneToOne:
            zoomScale = oneToOneScale()
            panPx = .zero
        case .oneToTwo:
            // 1:2 — image at 50% (1 image px → 0.5 view px). Half of
            // oneToOne's effective scale.
            zoomScale = 0.5 * oneToOneScale()
            panPx = .zero
        case .oneToFour:
            zoomScale = 0.25 * oneToOneScale()
            panPx = .zero
        case .oneToEight:
            zoomScale = 0.125 * oneToOneScale()
            panPx = .zero
        }
        view.needsDisplay = true
    }

    private func onPlaybackFrameChanged() {
        guard let frame = app.playback.currentFrame else { return }
        beforeTex = frame.texture
        afterTex = nil
        reprocess()
    }

    func syncFromModel() {
        if currentFileID != app.previewFileID {
            loadCurrentFile()
        }
    }

    // MARK: - Loading

    private func loadCurrentFile() {
        // Memory tab owns the preview via the playback transport; let it
        // drive there. In Inputs/Outputs we always reload from the
        // file-system entry the user clicked — even if memory still holds
        // aligned frames, the current section's preview must update.
        if app.displayedSection == .memory && app.playback.hasFrames { return }

        currentFileID = app.previewFileID
        // Clear any previous-file error banner up front. The completion
        // path will (re-)set it if the new load fails. Without this, the
        // user briefly sees the previous error while navigating to a
        // healthy file.
        app.previewError = nil
        // A different file invalidates the SER quality scan from the previous
        // file — cancel before kicking new work or stale results land.
        qualityScanner.cancel()

        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }) else {
            beforeTex = nil
            afterTex = nil
            app.previewStats = PreviewStats()
            view?.needsDisplay = true
            return
        }
        let url = entry.url
        let isSER = entry.isSER
        let isAVI = entry.isAVI

        // Auto-stretch is fully user-controlled (2026-05-03 user
        // request). The previous "auto-on for SER/AVI, off for stills"
        // override surprised users who explicitly wanted to see
        // everything unmodified by default — including dim raw
        // captures. The user toggles "Auto" themselves when they
        // want display-time stretching.

        // Seed the HUD with header-derived info immediately. Bytes / dates
        // come from the FileEntry and the (optional) SER / AVI header.
        var stats = PreviewStats()
        stats.fileName = entry.name
        stats.fileSizeBytes = entry.sizeBytes
        stats.captureDate = entry.creationDate
        stats.totalFrames = 1
        stats.currentFrame = 1

        // For frame-sequence files, read the header up front so we know the
        // frame count and can show the scrub slider. Reset scrub for stills.
        var serHeader: SerHeader?
        var aviReader: AviReader?
        if isSER {
            let serReader = try? SerReader(url: url)
            serHeader = serReader?.header
            if let h = serHeader {
                // Use the ACTUALLY-readable frame count, not the header's
                // declared one — an aborted / truncated capture can claim
                // more frames than the file contains, and scrubbing into
                // those phantom frames froze the preview (canReadFrame
                // correctly refuses to read past the mapped data).
                let realCount = serReader?.readableFrameCount ?? h.frameCount
                app.previewSerFrameCount = realCount
                // Derive the actual capture FPS from the SER's optional
                // per-frame timestamp trailer (FireCapture / SharpCap /
                // ASIStudio populate it; some older tools don't). nil →
                // scrub bar falls back to a 30 fps display estimate.
                app.previewSerCapturedFPS = serReader?.capturedFPS
                // Trim range + crop region are per-file. Restore from
                // the per-URL memory if the user previously set marks
                // on this SER — keeps the IN/OUT positions across
                // re-export rounds with different settings. Clamp to
                // the readable range in case the file was truncated.
                if let pair = app.rememberedSerTrimRanges[url] {
                    let last = max(0, realCount - 1)
                    app.serTrimStart = pair.0.map { max(0, min(last, $0)) }
                    app.serTrimEnd = pair.1.map { max(0, min(last, $0)) }
                } else {
                    app.serTrimStart = nil
                    app.serTrimEnd = nil
                }
                app.serCropRect = nil
                app.serCropAspect = .free
                // Restore the last-viewed frame for this SER when the
                // user round-trips between sections. Clamp to the
                // actual readable range in case the file was truncated.
                let remembered = app.rememberedSerFrameIndices[url] ?? 0
                app.previewSerFrameIndex = max(0, min(realCount - 1, remembered))
                // Bind both caches to this SER. Full-res prefetcher
                // handles release / play-time decodes; low-res scrub
                // cache handles drag previews. Low-res prefill runs
                // CPU-side (no Metal contention) so even on 4 GB+
                // SERs the main frame-0 load isn't starved.
                serPrefetcher.setURL(url)
                serScrubCache.setURL(url)
                serScrubCache.prefillSparse(totalFrames: realCount)
                // Refresh proxy availability + bind a cached proxy for
                // this SER (opens it off-main). Scrub then hits decode-free
                // thumbnails. Building itself is opt-in (buildScrubProxy).
                app.refreshScrubProxyState()
                stats.totalFrames = realCount
                stats.dimensions = (h.imageWidth, h.imageHeight)
                stats.bitDepth = h.pixelDepthPerPlane
                stats.bayerLabel = Self.bayerLabel(for: h.colorID)
                if let d = h.dateUTC { stats.captureDate = d }

                // E.4 capture validator. Detect target from filename +
                // folder name (same heuristic as the auto-preset path),
                // then parse SharpCap / FireCapture's metadata pairs out
                // of the header strings to feed the validator. Warnings
                // appear in the HUD's yellow chip section.
                let targetCandidates = [
                    url.lastPathComponent,
                    url.deletingLastPathComponent().lastPathComponent,
                ]
                let target = PresetAutoDetect.detect(in: targetCandidates)
                let meta = CaptureValidator.parseMetadata(
                    observer: h.observer,
                    instrument: h.instrument,
                    telescope: h.telescope
                )
                stats.captureWarnings = CaptureValidator.validate(
                    header: h,
                    target: target,
                    exposureMs: meta["exp"] ?? meta["exposure"],
                    frameRateFPS: meta["fps"]
                )
            }
        } else if isAVI {
            aviReader = try? AviReader(url: url)
            if let a = aviReader {
                app.previewSerFrameCount = a.frameCount
                app.previewSerFrameIndex = 0
                stats.totalFrames = a.frameCount
                stats.dimensions = (a.imageWidth, a.imageHeight)
                stats.bayerLabel = "AVI"
            }
        } else {
            app.previewSerFrameCount = 0
            app.previewSerFrameIndex = 0
            app.previewSerCapturedFPS = nil
        }
        app.previewStats = stats

        let flipped = entry.meridianFlipped
        let aviForBackground = aviReader
        // Stale-load guard: capture the file ID at dispatch time, then drop
        // the result on completion if the user has already moved on. Without
        // this, fast arrow-key blinking across the list dispatches multiple
        // background loads in flight at once; whichever finishes LAST wins
        // the beforeTex slot regardless of which row the user is now sitting
        // on, so the visible image desyncs from the highlighted filename and
        // can flip back and forth as old loads complete out-of-order.
        let dispatchedID = id
        // Loading-overlay signal. Multi-GB SERs from a NAS share take a
        // visible 1-3 s for the first-frame page-fault read; without a
        // loading indicator the user sees a black canvas and can't tell
        // if anything is happening. Show only for frame-sequence files
        // since static images load in <50 ms and the indicator would
        // flash distractingly.
        let showLoading = isSER || isAVI
        if showLoading {
            let sizeLabel = ByteCountFormatter.string(
                fromByteCount: entry.sizeBytes,
                countStyle: .file
            )
            app.isLoadingPreview = true
            app.loadingPreviewLabel = "\(entry.name)  ·  \(sizeLabel)"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tex: MTLTexture?
            var loadError: String?   // surfaced to PreviewView overlay
            let loadStart = Date()
            if isSER {
                do {
                    tex = try SerFrameLoader.loadFrame(url: url, frameIndex: 0, device: MetalDevice.shared.device)
                } catch {
                    NSLog("PreviewView: SerFrameLoader.loadFrame failed for %@ — %@",
                          url.lastPathComponent, String(describing: error))
                    loadError = Self.userFacingSerError(error: error, fileName: url.lastPathComponent)
                }
            } else if let avi = aviForBackground {
                tex = try? avi.loadFrame(at: 0, device: MetalDevice.shared.device)
                if tex == nil {
                    loadError = "Couldn't decode AVI frame from \(url.lastPathComponent)"
                }
            } else {
                tex = try? ImageTexture.load(url: url, device: MetalDevice.shared.device)
                if tex == nil {
                    loadError = "Couldn't read image from \(url.lastPathComponent)"
                }
            }
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            // Diagnostic: log file load + first-frame brightness so the
            // user can tell from Console.app whether a "black preview"
            // is real (data is genuinely dim → tone curve fix) vs a
            // load failure (tex is nil → app bug). Only fires for
            // frame-sequence files since static images already show
            // sane brightness via ImageTexture.load.
            if showLoading, let t = tex {
                let stats = Self.sampleBrightness(texture: t)
                NSLog("PreviewView: loaded %@ in %d ms — %dx%d %@, sample mean=%.4f min=%.4f max=%.4f",
                      url.lastPathComponent, loadMs,
                      t.width, t.height,
                      String(describing: t.pixelFormat),
                      stats.mean, stats.min, stats.max)
            } else if showLoading {
                NSLog("PreviewView: %@ load returned nil (after %d ms)",
                      url.lastPathComponent, loadMs)
            }
            // Apply the meridian-flip flag once, here. Everything downstream
            // sees the rotated frame.
            if flipped, let t = tex {
                tex = RotateTexture.rotate180(t, device: MetalDevice.shared.device)
            }
            // Skip the on-disk histogram path for any frame-sequence file —
            // Histogram.compute reads via ImageIO which doesn't grok SER/AVI.
            let hist = (isSER || isAVI) ? [] : Histogram.compute(url: url)
            // Per-channel histogram for the Tone Curve editor's RGB
            // overlay — cheap single-pass companion read.
            let histRGB: ChannelHistogram = (isSER || isAVI)
                ? ChannelHistogram(r: [], g: [], b: [])
                : Histogram.computeRGB(url: url)
            // Sharpness probe deliberately NOT auto-run on file open — at full
            // source resolution it adds 5-30 ms per click, which becomes
            // unbearable when the user is fanning through a folder of large
            // SERs. The "Calculate Video Quality" button below the HUD is the
            // explicit opt-in that runs the per-frame probe + distribution.
            DispatchQueue.main.async {
                guard self.app.previewFileID == dispatchedID else {
                    // Stale: we lost the race. Only clear loading state if
                    // no other load has overwritten it (which would be the
                    // current-file load — leave that alone).
                    if showLoading, self.app.loadingPreviewLabel?.contains(url.lastPathComponent) == true {
                        self.app.isLoadingPreview = false
                        self.app.loadingPreviewLabel = nil
                    }
                    return
                }
                self.app.previewError = loadError
                self.beforeTex = tex
                self.afterTex = nil
                // Zoom + pan deliberately PRESERVED across file switches — this
                // matches AstroTriage so blink-compare workflows (clicking
                // through neighbours in the list while staying zoomed-in on
                // the same region) work without re-zooming after every click.
                // Double-click on the preview / ⌘0 still reset to fit.
                self.app.previewHistogram = hist
                // For SER / AVI the ImageIO-based RGB pass returns empty
                // (formats it can't open). Compute from the just-decoded
                // preview texture instead so OSC Bayer SERs also get a
                // per-channel histogram in the Tone Curve editor.
                if histRGB.r.isEmpty, let t = tex {
                    let device = MetalDevice.shared.device
                    let queue = MetalDevice.shared.commandQueue
                    self.app.previewHistogramRGB = Histogram.computeRGB(
                        texture: t, device: device, queue: queue
                    )
                } else {
                    self.app.previewHistogramRGB = histRGB
                }
                if let dim = tex.map({ ($0.width, $0.height) }) {
                    self.app.previewStats.dimensions = dim
                }
                self.app.previewStats.currentSharpness = nil
                self.refreshDisplayAutoRange()
                self.view?.needsDisplay = true
                if showLoading {
                    self.app.isLoadingPreview = false
                    self.app.loadingPreviewLabel = nil
                }
                self.reprocess()
            }
        }

        // Look the SER distribution up in the on-disk cache. Hit → use it
        // immediately; miss → leave `distribution` nil so the HUD shows the
        // "Calculate Video Quality" button and the user opts in. We
        // deliberately don't auto-scan anymore — browsing many SERs in a
        // capture session was too slow when each one kicked a fresh scan.
        if isSER, serHeader != nil {
            if let cached = QualityCache.shared.lookup(url: url),
               let dist = cached.distribution {
                app.previewStats.distribution = dist
            }
        }
        // For static images, populate sharpness from the catalog if it has
        // already been computed by the thumbnail loader.
        if !isSER, let s = entry.sharpness {
            app.previewStats.currentSharpness = s
        }
    }

    /// Translate a low-level SerFrameLoader / SerReader error into a
    /// short user-friendly message for the preview error overlay. Keeps
    /// the developer-facing context in NSLog while showing something
    /// actionable on screen (e.g. "Unsupported SER ColorID 101 — …").
    /// `nonisolated` so the background-queue load path can call it
    /// without the @MainActor coordinator's actor hop.
    nonisolated private static func userFacingSerError(error: Error, fileName: String) -> String {
        let descr = String(describing: error)
        if descr.contains("unsupportedFormat") {
            // Pull the colorID out of the embedded message if present.
            if let range = descr.range(of: #"ColorID (\d+)"#, options: .regularExpression) {
                let cid = String(descr[range])
                return "\(fileName) — \(cid) is not a standard SER ColorID. Re-export from your capture tool as mono / Bayer / RGB."
            }
            if descr.contains("pixelDepth") {
                return "\(fileName) — pixel depth not supported (SER must be 8 or 16 bit)."
            }
            return "\(fileName) — unsupported SER format. Re-export from your capture tool."
        }
        if descr.contains("unsupportedColor") {
            return "\(fileName) — RGB SER files aren't yet supported in preview/stack. Capture as mono or Bayer."
        }
        if descr.contains("cannotOpen") || descr.contains("readerOpenFailed") {
            return "\(fileName) — couldn't open. Check the network volume / file isn't truncated."
        }
        if descr.contains("invalidHeader") || descr.contains("tooSmall") {
            return "\(fileName) — header looks corrupt or truncated."
        }
        return "\(fileName) — failed to decode (\(descr))"
    }

    /// Read back a 64×64 centre region of an rgba16Float / rgba32Float
    /// texture and compute mean/min/max luminance for diagnostic logging.
    /// Used to distinguish "load failed → texture is nil" from "load
    /// succeeded but data is dim → user thinks it's broken". Cost is
    /// a 16 KB blit + CPU iterate, negligible vs the file read itself.
    private static func sampleBrightness(texture: MTLTexture) -> (mean: Float, min: Float, max: Float) {
        let size = 64
        let cx = max(0, texture.width / 2 - size / 2)
        let cy = max(0, texture.height / 2 - size / 2)
        let w = min(size, texture.width - cx)
        let h = min(size, texture.height - cy)
        guard w > 0, h > 0 else { return (0, 0, 0) }
        // Two supported preview pixel formats land here: rgba16Float (typical
        // first-frame upload) and rgba32Float (post-pipeline). Both decode
        // RGB into [0, 1+] floats; just read R as a proxy for luminance on
        // the diagnostic path.
        let bpp: Int
        let isFloat32: Bool
        switch texture.pixelFormat {
        case .rgba32Float: bpp = 16; isFloat32 = true
        case .rgba16Float: bpp = 8;  isFloat32 = false
        default:           return (0, 0, 0)
        }
        // Source texture is .private storage so getBytes won't work
        // directly — blit the centre region into a .shared staging
        // texture first, then read.
        let device = MetalDevice.shared.device
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: w, height: h,
            mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stageDesc),
              let cmd = MetalDevice.shared.commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            return (0, 0, 0)
        }
        blit.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: cx, y: cy, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: staging,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let bytesPerRow = w * bpp
        var raw = [UInt8](repeating: 0, count: bytesPerRow * h)
        raw.withUnsafeMutableBufferPointer { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: w, height: h, depth: 1)
                ),
                mipmapLevel: 0
            )
        }
        var sum: Double = 0
        var minV: Float = .greatestFiniteMagnitude
        var maxV: Float = -.greatestFiniteMagnitude
        let pixels = w * h
        raw.withUnsafeBytes { rawBuf in
            if isFloat32 {
                let f = rawBuf.bindMemory(to: Float.self)
                for i in 0..<pixels {
                    let v = f[i * 4]
                    sum += Double(v)
                    if v < minV { minV = v }
                    if v > maxV { maxV = v }
                }
            } else {
                let h16 = rawBuf.bindMemory(to: UInt16.self)
                for i in 0..<pixels {
                    let v = Float(Float16(bitPattern: h16[i * 4]))
                    sum += Double(v)
                    if v < minV { minV = v }
                    if v > maxV { maxV = v }
                }
            }
        }
        return (Float(sum / Double(pixels)), minV, maxV)
    }

    /// Friendly Bayer-pattern label for the HUD. Mirrors `SerColorID` but
    /// kept here so the engine type doesn't bleed into UI strings.
    private static func bayerLabel(for id: SerColorID) -> String {
        switch id {
        case .mono:      return "Mono"
        case .rgb, .bgr: return "RGB"
        case .bayerRGGB: return "RGGB"
        case .bayerGRBG: return "GRBG"
        case .bayerGBRG: return "GBRG"
        case .bayerBGGR: return "BGGR"
        }
    }

    /// Called when the user scrubs the frame-sequence slider. Loads the
    /// requested frame and re-runs the processing pipeline. Throttled in
    /// the subscription so rapid scrubs don't queue up. Despite the
    /// historical name this also handles AVI frame access.
    /// Synchronous handler for a scrub index change. Fires inline on the
    /// `@Published` set — so it runs even inside the slider's modal
    /// tracking loop, unlike a scheduler-based throttle. Rate-limited by
    /// wall-clock to ~30 decodes/s. During playback it always loads (the
    /// timer drives the cadence). The settle subject (debounced) lands
    /// the exact final frame + full pipeline once the drag stops.
    /// Playback paint path — three-tier fallback like a real video
    /// player so motion stays visible even when the full-res decoder
    /// is still loading the requested frame:
    ///
    ///   1. Full-res cache hit → paint instantly (best case).
    ///   2. Full-res miss → paint the low-res thumb at this index
    ///      (or the nearest cached thumb). User sees motion
    ///      immediately, slightly soft, rather than a frozen frame
    ///      waiting for disk + Metal.
    ///   3. Both miss → keep the previously painted frame on screen.
    ///
    /// On every tick we ALSO re-arm both caches so the upcoming
    /// frames stay warm. The bounded-parallel prefetcher (max 2
    /// decode workers) replaced the old serial queue, so the full-
    /// res buffer fills ~2× faster.
    private func playbackPaintCachedFrame() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }),
              entry.isSER else { return }
        let idx = app.previewSerFrameIndex
        let total = app.previewSerFrameCount
        serPrefetcher.setURL(entry.url)
        serScrubCache.setURL(entry.url)
        serPrefetcher.prefetch(after: idx, totalFrames: total)
        // Ask the low-res cache to materialise this exact index too —
        // cheap, and the next tick can hit it while the full-res
        // decode is still in flight.
        serScrubCache.requestThumb(at: idx)

        // Tier 1: full-res cache hit.
        if let cached = serPrefetcher.cachedFrame(at: idx) {
            serDispatchSeq += 1
            let tex = entry.meridianFlipped
                ? RotateTexture.rotate180(cached, device: MetalDevice.shared.device)
                : cached
            applyLoadedSerFrame(
                tex: tex,
                dispatchedID: id,
                dispatchedSeq: serDispatchSeq,
                frameIndex: idx
            )
            return
        }

        // Tier 2: low-res fallback. Paint the thumb at idx if cached,
        // else the nearest cached thumb. This keeps motion visible
        // while the full-res decoder catches up.
        let lowRes = serScrubCache.cachedThumb(at: idx)
            ?? serScrubCache.nearestCachedThumb(to: idx)?.texture
        if let lowRes {
            paintScrubLowRes(lowRes, flipped: entry.meridianFlipped, frameIndex: idx)
            return
        }
        // Tier 3: nothing usable — leave the last painted frame on
        // screen. Frame counter still advances; the next tick has a
        // higher chance of hitting cache.
    }

    private func serScrubIndexChanged() {
        if app.serPlaybackActive {
            // Playback path — CACHE ONLY, no fresh async load.
            //
            // The old per-tick `loadCurrentSerFrame()` fanned out
            // async dispatches onto a global queue; each one called
            // `SerFrameLoader.loadFrame` which serialises on
            // `MetalDevice.shared.commandQueue.waitUntilCompleted`.
            // The prefetcher's serial queue queues buffers there too.
            // Result: every tick stacks more Metal command buffers
            // behind the prefetch, so for the first 200-500 ms after
            // Play we got a "Standbild" (nothing paints) followed by
            // a burst (everything completes at once).
            //
            // Now: we ONLY paint cached frames + keep the prefetcher
            // refilling. Cache misses just skip the tick — the screen
            // keeps the last painted frame, the prefetcher catches up
            // on the next tick. Smooth (slower) > stuttery (bursty).
            playbackPaintCachedFrame()
            return
        }
        let now = CACurrentMediaTime()
        if now - lastScrubLoadTime >= 0.03 {
            lastScrubLoadTime = now
            loadScrubFrameSync()
        }
        // Always arm the settle pass — its debounce fires on release and
        // loads the EXACT landed frame (in case the last index change was
        // rate-limited out) before running auto-range + the pipeline.
        serScrubSettleSubject.send(())
    }

    /// Synchronous scrub-frame load: decode + paint INLINE on the main
    /// thread (no background-queue → `main.async` hop). Cache hits are
    /// instant; a miss decodes here directly (tens of ms for a large
    /// frame — acceptable for a visual scan, and it's gated to ~30/s).
    /// Falls back to the async `loadCurrentSerFrame` for AVI.
    ///
    /// Speed-up: SER-load primes the cache with 16 sparse frames
    /// (prefillSparse), so scrubbing near a prefilled position hits
    /// cache and returns instantly. Hot lookahead (prefetch(after:))
    /// warms the next 4 frames around the current position.
    private func loadScrubFrameSync() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id })
        else { return }
        guard entry.isSER else { loadCurrentSerFrame(); return }
        let frameIndex = app.previewSerFrameIndex
        serPrefetcher.setURL(entry.url)
        serScrubCache.setURL(entry.url)

        // Drag-active path: low-res scrub cache only. Decoupled from
        // the Metal-kernel-bound full-res prefetcher, so it stays
        // responsive on 4 GB+ SERs where each full-res decode is
        // 300-500 ms. Request the EXACT frame's thumb in the background
        // (lands on the next drag pulse) and show nearest-cached now.
        if app.isSerScrubbing {
            // Instant path: a pre-built proxy atlas covers the whole SER
            // with decode-free thumbnails (no cold reads into the 8-20 GB
            // file). Nearest covered frame is at most stride/2 away.
            if let proxyTex = serProxyAtlas.nearestTexture(toFrame: frameIndex) {
                paintScrubLowRes(proxyTex, flipped: entry.meridianFlipped, frameIndex: frameIndex)
                return
            }
            // Fallback (no proxy built for this SER): on-demand low-res cache.
            serScrubCache.requestThumb(at: frameIndex)
            let lowRes = serScrubCache.cachedThumb(at: frameIndex)
                ?? serScrubCache.nearestCachedThumb(to: frameIndex)?.texture
            if let lowRes {
                paintScrubLowRes(lowRes, flipped: entry.meridianFlipped, frameIndex: frameIndex)
                return
            }
            // Low-res cache also missed (e.g. first drag right after
            // load, before any thumb has decoded). Skip the full-res
            // sync decode here — it would block the main thread for
            // hundreds of milliseconds on a 4 GB SER. The next pulse
            // will likely have a thumb ready. If we have any prior
            // texture in `beforeTex`, just leave it visible.
            return
        }

        // Idle / release: full-res decode of the exact frame.
        serPrefetcher.prefetch(after: frameIndex, totalFrames: app.previewSerFrameCount)
        guard let raw = serPrefetcher.loadFrameSync(at: frameIndex) else { return }
        let tex: MTLTexture = entry.meridianFlipped
            ? RotateTexture.rotate180(raw, device: MetalDevice.shared.device)
            : raw
        afterTex = nil
        beforeTex = tex
        app.previewStats.currentFrame = frameIndex + 1
        app.previewStats.currentSharpness = nil
        view?.draw()
    }

    private func paintScrubLowRes(_ raw: MTLTexture, flipped: Bool, frameIndex: Int) {
        let tex: MTLTexture = flipped
            ? RotateTexture.rotate180(raw, device: MetalDevice.shared.device)
            : raw
        afterTex = nil
        beforeTex = tex
        app.previewStats.currentFrame = frameIndex + 1
        app.previewStats.currentSharpness = nil
        view?.draw()
    }

    func loadCurrentSerFrame() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }),
              entry.isFrameSequence else { return }
        let url = entry.url
        let isSER = entry.isSER
        let frameIndex = app.previewSerFrameIndex
        let flipped = entry.meridianFlipped
        // Stale-load guard tokens — both the file and the frame index must
        // still match when this load completes. Fast scrubbing dispatches
        // many concurrent loads; without this, frame N+5 finishing AFTER
        // frame N+10 would draw N+5 over N+10 and flip the visible frame
        // backwards relative to the slider.
        let dispatchedID = id
        serDispatchSeq += 1
        let dispatchedSeq = serDispatchSeq
        // SER hot path: synchronous cache hit returns inline (no
        // background dispatch needed) so the timer-driven playback
        // doesn't pay the GCD round-trip on a cache hit. Miss falls
        // through to the background load below. Prefetch is fired
        // immediately so the next 4 frames warm up regardless of
        // whether the current frame was a hit or miss.
        if isSER {
            serPrefetcher.setURL(url)
            serPrefetcher.prefetch(after: frameIndex, totalFrames: app.previewSerFrameCount)
            if let cached = serPrefetcher.cachedFrame(at: frameIndex) {
                let flippedHit: MTLTexture? = flipped
                    ? RotateTexture.rotate180(cached, device: MetalDevice.shared.device)
                    : cached
                self.applyLoadedSerFrame(
                    tex: flippedHit, dispatchedID: dispatchedID,
                    dispatchedSeq: dispatchedSeq,
                    frameIndex: frameIndex
                )
                return
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tex: MTLTexture?
            if isSER {
                tex = self.serPrefetcher.loadFrameSync(at: frameIndex)
            } else {
                // AVI — instantiate a lightweight reader per scrub. The
                // generator caches under the hood so consecutive frame-N
                // requests stay fast even without persistent state.
                tex = try? AviReader(url: url).loadFrame(at: frameIndex, device: MetalDevice.shared.device)
            }
            if flipped, let t = tex {
                tex = RotateTexture.rotate180(t, device: MetalDevice.shared.device)
            }
            // Same rationale as `loadCurrentFile`: no auto-probe on scrub.
            // Holding next/prev or dragging the scrubber across thousands of
            // frames must stay snappy. The HUD's currentSharpness goes blank
            // during scrub; the "Calculate Video Quality" button populates
            // the sampled distribution when the user opts in.
            let texFinal = tex
            DispatchQueue.main.async {
                self.applyLoadedSerFrame(
                    tex: texFinal,
                    dispatchedID: dispatchedID,
                    dispatchedSeq: dispatchedSeq,
                    frameIndex: frameIndex
                )
            }
        }
    }

    /// Commit a freshly-loaded SER / AVI frame to the preview state.
    /// Shared by:
    ///   - the cache-hit fast path in `loadCurrentSerFrame` (no GCD
    ///     hop, no disk read)
    ///   - the disk-load slow path (background queue → main hop)
    /// Stale-load guard: dispatchedID must still match `previewFileID`.
    /// During active SER playback the index-match guard is relaxed so
    /// the timer keeps painting frames even when disk I/O lags behind
    /// the cadence.
    private func applyLoadedSerFrame(
        tex: MTLTexture?,
        dispatchedID: UUID,
        dispatchedSeq: Int,
        frameIndex: Int
    ) {
        guard app.previewFileID == dispatchedID else { return }
        // Drop only frames that arrive OUT OF ORDER (an earlier dispatch
        // finishing after a later one) — this keeps the preview from
        // flicking backwards during a fast scrub while still painting
        // every intermediate frame that is the newest seen. The old
        // `index == dispatchedFrameIndex` guard dropped ALL in-flight
        // frames mid-scrub, so nothing moved until the user stopped.
        guard dispatchedSeq >= lastPaintedScrubSeq else { return }
        lastPaintedScrubSeq = dispatchedSeq
        guard let tex else { return }
        // Drop the stale sharpened texture so the raw frame paints
        // immediately. Without this the user stares at the previous
        // frame's "after" texture until the sharpen / tone-curve
        // pipeline finishes for the new frame — which is what made
        // scrubbing feel laggy. The pipeline still runs and replaces
        // afterTex when it lands.
        afterTex = nil
        beforeTex = tex
        app.previewStats.currentFrame = frameIndex + 1
        app.previewStats.currentSharpness = nil
        // Force an IMMEDIATE synchronous render rather than the deferred
        // `needsDisplay` path. While the user drags the SER scrub slider
        // (or any control), the main run loop is in
        // NSEventTrackingRunLoopMode and the on-demand MTKView redraw
        // that `needsDisplay = true` schedules does NOT fire until the
        // drag ends — so frames appeared frozen mid-scrub and only
        // updated on release. `draw()` renders the new beforeTex on the
        // spot regardless of run-loop mode.
        view?.draw()
        // The expensive auto-range recompute + full pipeline are armed by
        // `serScrubIndexChanged` (settle debounce), NOT here — so the
        // per-frame scrub path only pays the decode + draw. Playback skips
        // the heavy pass entirely (the timer drives the cadence; running
        // the pipeline per frame would block it).
    }

    // MARK: - Processing

    private var processingQueue = DispatchQueue(label: "astrosharper.preview.process", qos: .userInitiated)
    private var inFlight = false
    /// Coalesced pending pass. Replaces the old "send back into
    /// reprocessSubject" retry which fed both the throttle (33 ms) and
    /// debounce (200 ms) subscribers — the debounce timer kept resetting
    /// on every retry-send, and the throttle kept re-firing while
    /// `inFlight` was true, so each pipeline run kicked off another
    /// one. With a single queued bool, when the current run ends we just
    /// drain at most one queued pass directly, no Combine round-trip.
    /// preview:false (drag-end full-res) takes precedence over
    /// preview:true (drag-tick) so a late throttle emit can't downgrade
    /// the queued pass back to fast mode.
    private var pendingPreview: Bool?

    private func reprocess(preview: Bool = true) {
        guard let src = beforeTex else {
            pendingPreview = nil
            return
        }

        // Already running? Queue at most one pass and bail; the in-flight
        // pipeline drains it on completion.
        if inFlight {
            if !(pendingPreview == false && preview == true) {
                pendingPreview = preview
            }
            return
        }

        let sharpen = app.sharpen
        let tone = app.toneCurve
        let coloring = app.coloring

        // Identity short-circuit at the call site too — when the user has
        // nothing turned on, don't kick a background pipeline pass at all.
        // The display falls back to `beforeTex` when `afterTex` is nil,
        // which is exactly the unmodified raw frame the user wants to see
        // when no panel is active. Match the engine-side guard in
        // Pipeline.process so adding new pipeline steps stays in sync.
        let bcIsIdentity = abs(tone.brightness) < 1e-4 && abs(tone.contrast - 1.0) < 1e-4
        let satIsIdentity = abs(tone.saturation - 1.0) < 1e-4
        let toneCurveActive = tone.enabled && !tone.controlPoints.isEmpty
            && (tone.controlPoints.count > 2
                || tone.controlPoints.first != .zero
                || tone.controlPoints.last != CGPoint(x: 1, y: 1))
        // Coloring is its own gate — enabled section with at least one
        // non-identity curve. Without this guard the call-site short-
        // circuit below skips pipeline.process entirely when ONLY the
        // Coloring section is dialled in, and the user's curve edits
        // never reach the GPU (the bug the user just reported).
        let coloringActive = coloring.enabled && !coloring.isIdentity
        let nothingActive = !tone.autoWB
            && !tone.chromaticAlignment
            && !sharpen.enabled
            && !coloringActive
            && (!tone.enabled || (!toneCurveActive && !tone.solarDualZone && bcIsIdentity && satIsIdentity))
        if nothingActive {
            afterTex = nil
            view?.needsDisplay = true
            // Make sure the spinner/highlight aren't stuck-on if a previous
            // pass left them set and the user just toggled everything off.
            if app.processingInFlight { app.processingInFlight = false }
            if app.activePreviewStage != nil { app.activePreviewStage = nil }
            pendingPreview = nil
            return
        }

        let lut = ensureLUT(for: tone)
        inFlight = true
        pendingPreview = nil
        if !app.processingInFlight { app.processingInFlight = true }

        processingQueue.async { [weak self] in
            guard let self else { return }
            let result = self.pipeline.process(
                input: src,
                sharpen: sharpen,
                toneCurve: tone,
                toneCurveLUT: lut,
                coloring: coloring,
                preview: preview,
                onStageChange: { [weak self] stage in
                    // Pipeline runs on background queue; UI state must be
                    // mutated on main. Coalescing identical writes is fine
                    // here — SwiftUI ignores set-equal-value on @Published.
                    DispatchQueue.main.async {
                        self?.app.activePreviewStage = stage
                    }
                }
            )
            DispatchQueue.main.async {
                self.afterTex = result
                // Recompute display auto-range against the JUST-PRODUCED
                // afterTex so the stretch+gamma parameters reflect what
                // the shader will actually display. Without this, the
                // shader uses parameters tuned to beforeTex (raw frame)
                // while drawing the sharpened/toned afterTex, which can
                // clip highlights to white and produce the "flat" look
                // user reported on their solar Ha SER.
                self.refreshDisplayAutoRange()
                self.inFlight = false
                self.app.processingInFlight = false
                self.app.activePreviewStage = nil
                self.view?.needsDisplay = true
                // Drain a queued pass, if any. Direct re-call (no Combine
                // round-trip) so we don't poke either of the subject
                // subscribers back to life.
                if let pending = self.pendingPreview {
                    self.pendingPreview = nil
                    self.reprocess(preview: pending)
                }
            }
        }
    }

    private func ensureLUT(for tone: ToneCurveSettings) -> MTLTexture? {
        // Tone subsystem is gated on `tone.enabled` — if the user
        // disabled the Tone Curve section, NOTHING tone-side fires
        // (including solarDualZone). Dual-zone is just a different
        // LUT shape selected when the section is enabled.
        guard tone.enabled else { return nil }
        if tone.solarDualZone {
            if lutTex != nil, lastLUTSolarDualZone { return lutTex }
            let newLUT = ToneCurveLUT.buildSolarDualZone(device: MetalDevice.shared.device)
            lutTex = newLUT
            lastLUTSolarDualZone = true
            lastLUTPoints = []
            return newLUT
        }
        if lutTex != nil, !lastLUTSolarDualZone, lastLUTPoints == tone.controlPoints { return lutTex }
        let newLUT = ToneCurveLUT.build(points: tone.controlPoints, device: MetalDevice.shared.device)
        lutTex = newLUT
        lastLUTPoints = tone.controlPoints
        lastLUTSolarDualZone = false
        return newLUT
    }

    // MARK: - Draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private struct DisplayUniforms {
        var texSize: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var zoom: Float
        var panPx: SIMD2<Float>
        var splitX: Float
        var hasAfter: UInt32
        var autoBlack: Float
        var autoScale: Float
        var autoGamma: Float
        var displayGain: Float
        var autoRangeOn: UInt32
        // Highlight-clipped overlay (LSW 8.8). Mirrors the same-named
        // fields on the Metal-side struct in Shaders.metal — must stay
        // in sync field-for-field, or `setFragmentBytes` will pack the
        // values into the wrong shader slots.
        var clipOverlayOn: UInt32
        var clipThreshold: Float
    }

    // Cached auto-range params. Recomputed only when beforeTex changes
    // (NOT every draw call). Match AS!4's "Auto Range + Brightness pow"
    // formula picked by the user bracket (file 26_stretch_g25):
    //   stretched = clamp((col − autoBlack) · autoScale, 0, 1)
    //   displayed = pow(stretched, autoGamma)
    private var displayBlack: Float = 0.0    // = p1 of the luma histogram
    private var displayScale: Float = 1.0    // = 1 / max(0.005, p99 − p1)
    private var displayGamma: Float = 2.5    // user-bracket pick — fixed for now
    private var lastUniformLogToken: String = ""    // for de-duped log spam

    /// Recompute auto-range params for the current `beforeTex`. Cheap
    /// (~5 ms via the existing 256² downsample + sort). Same formula
    /// as the user's picked file `26_stretch_g25.png` from the
    /// /tmp/display-bracket/ comparison: stretch [p1, p99] → [0, 1]
    /// then `pow(., 2.5)` to darken midtones into AS!4-style contrast.
    ///
    /// Examples:
    ///   solar Ha (p1=0.008, p99=0.89): autoScale = 1.13, gamma = 2.5
    ///     → 0.67 raw: (0.67−0.008)·1.13 = 0.748 → pow(0.748, 2.5) = 0.484
    ///       (mid-grey disc face — matches AS!4 reference)
    ///   Jupiter (p1=0, p99=0.6): autoScale = 1.67, gamma = 2.5
    ///     → 0.5 raw: 0.83 stretched → pow(0.83, 2.5) = 0.625 (visible disc)
    ///   Lunar (p1=0.05, p99=0.5): autoScale = 2.22, gamma = 2.5
    ///     → 0.3 raw: 0.555 stretched → pow(0.555, 2.5) = 0.229 (dim mid)
    ///       (lunar gets darker than user wants if Auto is on by default
    ///       on lunar — they can dial Brightness up or toggle Auto off)
    func refreshDisplayAutoRange() {
        // Sample the texture the SHADER will actually display, not the
        // raw frame: when the pipeline runs sharpen / tone curve it
        // writes into `afterTex`, which can hold values quite different
        // from `beforeTex` (sharpening lifts highlights, tone curve
        // remaps midtones). Computing percentiles on `beforeTex` while
        // the shader reads `afterTex` produces the "flat / clipped"
        // failure mode the user saw — the stretch parameters were
        // tuned for the wrong texture.
        guard let tex = afterTex ?? beforeTex else {
            displayBlack = 0; displayScale = 1; return
        }
        if let pts = pipeline.computeLumaPercentiles(
            input: tex, lowPercentile: 0.01, highPercentile: 0.99
        ) {
            displayBlack = max(0, pts.black)
            let range = max(Float(0.005), pts.white - pts.black)
            displayScale = 1.0 / range
            NSLog("Display auto-range: p1=%.4f median=%.4f p99=%.4f → black=%.4f scale=%.3f gamma=%.2f (source=%@)",
                  pts.black, pts.median, pts.white, displayBlack, displayScale, displayGamma,
                  afterTex != nil ? "afterTex" : "beforeTex")
        } else {
            NSLog("Display auto-range: percentile compute returned nil — using identity")
            displayBlack = 0
            displayScale = 1.0
        }
    }

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let pso = displayPSO,
            let cmdBuf = MetalDevice.shared.commandQueue.makeCommandBuffer()
        else { return }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = view.clearColor

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pso)

        let vw = Float(view.drawableSize.width)
        let vh = Float(view.drawableSize.height)
        let tw = Float(beforeTex?.width ?? 1)
        let th = Float(beforeTex?.height ?? 1)

        // Compare side panel replaced the old Before/After main-view flip
        // (2026-05-03). Always render fully "after" (post-pipeline);
        // direct comparison now happens via the side-panel thumbnails.
        let split: Float = 1.0
        let autoOn = app.displayAutoRange
        let user: Float = Float(max(0.1, app.displayGain))
        let bk: Float = autoOn ? displayBlack : 0
        let sc: Float = autoOn ? displayScale : 1
        let gm: Float = autoOn ? displayGamma : 1
        var uniforms = DisplayUniforms(
            texSize: SIMD2(tw, th),
            viewSize: SIMD2(vw, vh),
            zoom: zoomScale,
            panPx: panPx,
            splitX: split,
            hasAfter: afterTex == nil ? 0 : 1,
            autoBlack: bk,
            autoScale: sc,
            autoGamma: gm,
            displayGain: user,
            autoRangeOn: autoOn ? 1 : 0,
            clipOverlayOn: app.highlightClipped ? 1 : 0,
            clipThreshold: 0.995
        )
        // One-shot diagnostic: log the exact uniforms whenever they
        // CHANGE. Frequent draws don't spam the log because the values
        // are stable between texture loads + slider drags.
        let token = "\(autoOn ? 1 : 0)|\(bk)|\(sc)|\(gm)|\(user)"
        if token != lastUniformLogToken {
            lastUniformLogToken = token
            NSLog("Display uniforms: autoOn=%d black=%.4f scale=%.3f gamma=%.2f userGain=%.2f",
                  autoOn ? 1 : 0, bk, sc, gm, user)
        }

        if let before = beforeTex {
            enc.setFragmentTexture(before, index: 0)
            enc.setFragmentTexture(afterTex ?? before, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - ZoomableMTKView

final class ZoomableMTKView: MTKView {
    weak var coordinator: PreviewCoordinator?

    private var isPanDragging = false
    private var panDragStart: NSPoint = .zero         // drawable pixels — panPx is stored in drawable pixels too
    private var panStartOffset: SIMD2<Float> = .zero

    override var acceptsFirstResponder: Bool { true }

    // Mouse model — standard macOS Preview-style interactions
    // (rebuilt 2026-05-02 — replaces the AstroTriage Photoshop-anchored
    // click-drag-zoom which the user found surprising):
    //   • Plain left-drag         = pan (hand tool, closed-hand cursor).
    //   • ⌥ + drag                = pan (legacy modifier kept for
    //                               muscle-memory).
    //   • Double-click            = reset to fit-to-view + center.
    //   • Pinch (magnify)         = zoom anchored to cursor.
    //   • ⌥ + scroll wheel        = zoom anchored to cursor.
    //   • Scroll wheel (no mods)  = pan when zoomed in; passes through
    //                               to enclosing scroll view otherwise.

    /// `panPx` in the coordinator is in drawable pixels (same units the
    /// display shader sees). Mouse events come in points, so we convert.
    private func toDrawable(_ p: NSPoint) -> CGPoint {
        let s = window?.backingScaleFactor ?? 1
        return CGPoint(x: p.x * s, y: p.y * s)
    }

    /// Fit-scale = how much the texture is scaled up/down to fit the view
    /// at zoomScale = 1. Matches the display shader's implicit fit.
    private func fitScale() -> CGFloat {
        guard let c = coordinator,
              let texSize = c.texturePixelSize else { return 0 }
        let view = drawableSize
        guard view.width > 0, view.height > 0,
              texSize.width > 0, texSize.height > 0 else { return 0 }
        return min(view.width / texSize.width, view.height / texSize.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = coordinator else { return }

        if event.clickCount == 2 {
            // Double-click resets to fit + center. Standard macOS
            // Preview behaviour.
            c.zoomScale = 1
            c.panPx = .zero
            needsDisplay = true
            return
        }

        // Plain drag (or ⌥-drag for muscle-memory) = pan. The
        // Photoshop anchored-zoom-drag was removed 2026-05-02 per
        // user feedback that it felt non-standard.
        isPanDragging = true
        panDragStart = toDrawable(convert(event.locationInWindow, from: nil))
        panStartOffset = c.panPx
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = coordinator else { return }
        guard isPanDragging else { return }

        let current = toDrawable(convert(event.locationInWindow, from: nil))
        // Hand-tool pan — image follows the cursor on both axes.
        // X: AppKit and shader agree on direction (right is +). Drag
        //    right → see more of left side → cx decreases → panPx.x
        //    must go negative → subtract the positive delta.
        // Y: AppKit Y is bottom-up (+ = mouse moved up), but the shader's
        //    `cy = 0.5 - panPx.y / …` interprets a NEGATIVE panPx.y as
        //    "shift content up". Earlier subtract-on-both-axes was the
        //    bug: dragging up made the image drift down (user-reported
        //    2026-05-21). Subtract on X, ADD on Y → hand-tool follow on
        //    both axes.
        c.panPx.x = panStartOffset.x - Float(current.x - panDragStart.x)
        c.panPx.y = panStartOffset.y + Float(current.y - panDragStart.y)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isPanDragging { NSCursor.arrow.set() }
        isPanDragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = coordinator else {
            super.scrollWheel(with: event)
            return
        }
        // ⌥ + scroll = zoom anchored to cursor (standard Mac
        // viewer convention, matches Preview / Photos).
        if event.modifierFlags.contains(.option) {
            let mouseInView = toDrawable(convert(event.locationInWindow, from: nil))
            // scrollingDeltaY is positive when scrolling up. Map to
            // a 1.05× / 0.95× zoom step per scroll tick.
            let step: CGFloat = event.scrollingDeltaY > 0 ? 1.05 : (1.0 / 1.05)
            let oldScale = c.zoomScale
            let newScale = Float(max(0.1, min(50.0, CGFloat(oldScale) * step)))
            anchoredZoom(toScale: newScale,
                         anchor: mouseInView,
                         fromScale: oldScale,
                         fromPan: c.panPx)
            return
        }
        // Plain scroll = pan when zoomed in. Otherwise pass through
        // to whatever's behind us (typically a no-op).
        guard c.zoomScale > 1.01 else {
            super.scrollWheel(with: event)
            return
        }
        let s = Float(window?.backingScaleFactor ?? 1)
        c.panPx.x -= Float(event.scrollingDeltaX) * s
        c.panPx.y -= Float(event.scrollingDeltaY) * s
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let c = coordinator else { return }
        let mouseInView = toDrawable(convert(event.locationInWindow, from: nil))
        let factor = CGFloat(1.0 + event.magnification)
        let oldScale = c.zoomScale
        let newScale = Float(max(0.1, min(50.0, CGFloat(oldScale) * factor)))
        anchoredZoom(toScale: newScale,
                     anchor: mouseInView,
                     fromScale: oldScale,
                     fromPan: c.panPx)
    }

    /// Update `zoomScale` and `panPx` so the image pixel that was under
    /// `anchor` (in drawable-pixel view coords) stays under the anchor
    /// after the zoom change.
    ///
    /// Sign convention: the display shader uses `uv += panPx / texSize`, so
    /// positive `panPx.x` shifts image content to the LEFT on screen
    /// (samples further to the right in the source). That's *opposite* to
    /// AstroTriage's pan-offset convention, so the math here is the
    /// negated form of the AstroTriage formula derived for our shader:
    ///   sampled image-x = relX_view * (texW / (viewW * zoom * fitX)) + ½texW + panPx.x
    /// Solving for the panPx.x that keeps the same image-x under the anchor
    /// yields:
    ///   imgX_at_anchor = (relX + oldPan.x) / oldEffective
    ///   panPx.x_new    = imgX_at_anchor * newEffective − relX
    /// (same shape for Y).
    private func anchoredZoom(toScale newScale: Float,
                              anchor: CGPoint,
                              fromScale oldScale: Float,
                              fromPan oldPan: SIMD2<Float>) {
        guard let c = coordinator else { return }
        let baseFit = fitScale()
        guard baseFit > 0 else {
            c.zoomScale = newScale
            needsDisplay = true
            return
        }
        let oldEffective = baseFit * CGFloat(oldScale)
        let newEffective = baseFit * CGFloat(newScale)

        let viewW = drawableSize.width
        let viewH = drawableSize.height
        let relX = anchor.x - viewW / 2.0
        let relY = anchor.y - viewH / 2.0

        let imgX = (relX + CGFloat(oldPan.x)) / oldEffective
        let imgY = (relY + CGFloat(oldPan.y)) / oldEffective

        c.panPx.x = Float(imgX * newEffective - relX)
        c.panPx.y = Float(imgY * newEffective - relY)
        c.zoomScale = newScale
        needsDisplay = true
    }
}
