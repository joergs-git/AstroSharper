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
            .overlay(alignment: .bottomLeading) {
                if app.hudVisible && app.previewFileID != nil {
                    PreviewStatsHUD(
                        stats: app.previewStats,
                        onCalculateVideoQuality: currentEntryIsSER && app.previewStats.totalFrames > 1
                            ? { app.calculateVideoQualityForCurrentFile() }
                            : nil,
                        isScanning: app.isCalculatingVideoQuality
                    )
                    .transition(.opacity)
                }
            }
            // Mini-map overlay was disabled — pan/zoom recomputed it on
            // every drag tick, and the user found it slow without
            // commensurate value. The view + computation helpers stay in
            // the codebase (PreviewMiniMap.swift, publishViewport()) for
            // future revival.
            .environmentObject(app)
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
    private let reprocessSubject = PassthroughSubject<Void, Never>()

    // Zoom / pan state — UI lives here, MTKView queries via draw().
    var zoomScale: Float = 1.0
    var panPx: SIMD2<Float> = .zero

    // Tone curve LUT cache
    private var lutTex: MTLTexture?
    private var lastLUTPoints: [CGPoint] = []

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
        app.$showAfter
            .sink { [weak self] _ in self?.view?.needsDisplay = true }
            .store(in: &cancellables)
        // SER frame scrub — throttled to ~30 fps so dragging stays smooth
        // even on multi-thousand-frame SERs.
        app.$previewSerFrameIndex
            .removeDuplicates()
            .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.loadCurrentSerFrame() }
            .store(in: &cancellables)
        // Playback: when the current playback frame index changes, swap the
        // source texture and re-run the pipeline.
        app.$playback
            .map { ($0.currentIndex, $0.frames.count) }
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] _ in self?.onPlaybackFrameChanged() }
            .store(in: &cancellables)

        trigger
            .sink { [weak self] in self?.reprocess() }
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
        case .twoHundred:
            zoomScale = 2 * oneToOneScale()
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
            serHeader = try? SerReader(url: url).header
            if let h = serHeader {
                app.previewSerFrameCount = h.frameCount
                app.previewSerFrameIndex = 0
                stats.totalFrames = h.frameCount
                stats.dimensions = (h.imageWidth, h.imageHeight)
                stats.bitDepth = h.pixelDepthPerPlane
                stats.bayerLabel = Self.bayerLabel(for: h.colorID)
                if let d = h.dateUTC { stats.captureDate = d }
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tex: MTLTexture?
            if isSER {
                tex = try? SerFrameLoader.loadFrame(url: url, frameIndex: 0, device: MetalDevice.shared.device)
            } else if let avi = aviForBackground {
                tex = try? avi.loadFrame(at: 0, device: MetalDevice.shared.device)
            } else {
                tex = try? ImageTexture.load(url: url, device: MetalDevice.shared.device)
            }
            // Apply the meridian-flip flag once, here. Everything downstream
            // sees the rotated frame.
            if flipped, let t = tex {
                tex = RotateTexture.rotate180(t, device: MetalDevice.shared.device)
            }
            // Skip the on-disk histogram path for any frame-sequence file —
            // Histogram.compute reads via ImageIO which doesn't grok SER/AVI.
            let hist = (isSER || isAVI) ? [] : Histogram.compute(url: url)
            // Sharpness probe deliberately NOT auto-run on file open — at full
            // source resolution it adds 5-30 ms per click, which becomes
            // unbearable when the user is fanning through a folder of large
            // SERs. The "Calculate Video Quality" button below the HUD is the
            // explicit opt-in that runs the per-frame probe + distribution.
            DispatchQueue.main.async {
                guard self.app.previewFileID == dispatchedID else { return }
                self.beforeTex = tex
                self.afterTex = nil
                // Zoom + pan deliberately PRESERVED across file switches — this
                // matches AstroTriage so blink-compare workflows (clicking
                // through neighbours in the list while staying zoomed-in on
                // the same region) work without re-zooming after every click.
                // Double-click on the preview / ⌘0 still reset to fit.
                self.app.previewHistogram = hist
                if let dim = tex.map({ ($0.width, $0.height) }) {
                    self.app.previewStats.dimensions = dim
                }
                self.app.previewStats.currentSharpness = nil
                self.view?.needsDisplay = true
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
        let dispatchedFrameIndex = frameIndex
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tex: MTLTexture?
            if isSER {
                tex = try? SerFrameLoader.loadFrame(url: url, frameIndex: frameIndex, device: MetalDevice.shared.device)
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
            DispatchQueue.main.async {
                guard self.app.previewFileID == dispatchedID,
                      self.app.previewSerFrameIndex == dispatchedFrameIndex else { return }
                guard let tex else { return }
                // Drop the stale sharpened texture so the raw frame paints
                // immediately. Without this the user stares at the previous
                // frame's "after" texture until the sharpen / tone-curve
                // pipeline finishes for the new frame — which is what made
                // scrubbing feel laggy. The pipeline still runs and replaces
                // afterTex when it lands.
                self.afterTex = nil
                self.beforeTex = tex
                self.app.previewStats.currentFrame = frameIndex + 1
                self.app.previewStats.currentSharpness = nil
                self.view?.needsDisplay = true
                self.reprocess()
            }
        }
    }

    // MARK: - Processing

    private var processingQueue = DispatchQueue(label: "astrosharper.preview.process", qos: .userInitiated)
    private var inFlight = false

    private func reprocess() {
        guard let src = beforeTex, !inFlight else {
            if inFlight { reprocessSubject.send(()) }  // queue another pass
            return
        }
        let sharpen = app.sharpen
        let tone = app.toneCurve

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
        let nothingActive = !tone.autoWB
            && !tone.chromaticAlignment
            && !sharpen.enabled
            && (!tone.enabled || (!toneCurveActive && bcIsIdentity && satIsIdentity))
        if nothingActive {
            afterTex = nil
            view?.needsDisplay = true
            return
        }

        let lut = ensureLUT(for: tone)
        inFlight = true

        processingQueue.async { [weak self] in
            guard let self else { return }
            let result = self.pipeline.process(
                input: src,
                sharpen: sharpen,
                toneCurve: tone,
                toneCurveLUT: lut
            )
            DispatchQueue.main.async {
                self.afterTex = result
                self.inFlight = false
                self.view?.needsDisplay = true
            }
        }
    }

    private func ensureLUT(for tone: ToneCurveSettings) -> MTLTexture? {
        guard tone.enabled else { return nil }
        if lutTex != nil, lastLUTPoints == tone.controlPoints { return lutTex }
        let newLUT = ToneCurveLUT.build(points: tone.controlPoints, device: MetalDevice.shared.device)
        lutTex = newLUT
        lastLUTPoints = tone.controlPoints
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

        // Before/After toggle: pass splitX=1 (fully "after") when showAfter is on,
        // else 0 (fully "before"). The display shader already handles both paths.
        let split: Float = app.showAfter ? 1.0 : 0.0
        var uniforms = DisplayUniforms(
            texSize: SIMD2(tw, th),
            viewSize: SIMD2(vw, vh),
            zoom: zoomScale,
            panPx: panPx,
            splitX: split,
            hasAfter: afterTex == nil ? 0 : 1
        )

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

    private var isZoomDragging = false
    private var isPanDragging = false
    private var zoomAnchorView: NSPoint = .zero       // drawable pixels — for anchoredZoom math
    private var zoomAnchorPoints: NSPoint = .zero     // points — for the dx → speed calibration (matches AstroTriage's "200 pt = 2x")
    private var zoomStartScale: Float = 1
    private var zoomStartPan: SIMD2<Float> = .zero
    private var panDragStart: NSPoint = .zero         // drawable pixels — panPx is stored in drawable pixels too
    private var panStartOffset: SIMD2<Float> = .zero

    override var acceptsFirstResponder: Bool { true }

    // Mouse model — ported from AstroBlinkV2 / AstroTriage's ZoomableMTKView
    // so the experience is identical:
    //   • Plain left-drag  = Photoshop click-drag zoom (anchored to click;
    //     right = zoom in, left = zoom out, ~200 pt → 2×).
    //   • ⌥ + drag         = pan (hand tool, closed-hand cursor).
    //   • Double-click     = reset to fit-to-view + center.
    //   • Pinch (magnify)  = zoom anchored to cursor.
    //   • Scroll wheel     = pan when zoomed in.

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
            // Reset to fit + center.
            c.zoomScale = 1
            c.panPx = .zero
            needsDisplay = true
            return
        }

        if event.modifierFlags.contains(.option) {
            // ⌥-drag = pan (hand tool).
            isPanDragging = true
            panDragStart = toDrawable(convert(event.locationInWindow, from: nil))
            panStartOffset = c.panPx
            NSCursor.closedHand.set()
            return
        }

        // Default = anchored zoom drag. Record the click anchor and the
        // starting zoom + pan; mouseDragged will compute new pan to keep the
        // pixel under the cursor stationary as zoom changes.
        isZoomDragging = true
        let pt = convert(event.locationInWindow, from: nil)
        zoomAnchorPoints = pt
        zoomAnchorView = toDrawable(pt)
        zoomStartScale = c.zoomScale
        zoomStartPan = c.panPx
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = coordinator else { return }

        if isPanDragging {
            let current = toDrawable(convert(event.locationInWindow, from: nil))
            // Hand-tool pan — image follows the cursor on BOTH axes (matches
            // AstroTriage). The Y axis was previously inverted: dragging the
            // cursor up moved the image down. Empirically the shader's panPx.y
            // convention is opposite to what an earlier comment claimed, so
            // subtracting the Y delta makes the image follow the hand. X
            // already worked correctly (subtract → image follows hand right).
            c.panPx.x = panStartOffset.x - Float(current.x - panDragStart.x)
            c.panPx.y = panStartOffset.y - Float(current.y - panDragStart.y)
            needsDisplay = true
            return
        }

        guard isZoomDragging else { return }
        // Zoom speed in POINTS, not drawable pixels — AstroTriage's "200 pt of
        // horizontal drag = 2× zoom" calibration. Using drawable pixels here
        // made the zoom feel 2× too fast on retina because dx in drawable
        // pixels is 2× the dx in points for the same physical mouse motion.
        let currentPoints = convert(event.locationInWindow, from: nil)
        let dxPoints = currentPoints.x - zoomAnchorPoints.x
        let zoomFactor = pow(2.0, dxPoints / 200.0)
        let newScale = max(0.1, min(50.0, CGFloat(zoomStartScale) * zoomFactor))
        anchoredZoom(toScale: Float(newScale),
                     anchor: zoomAnchorView,
                     fromScale: zoomStartScale,
                     fromPan: zoomStartPan)
    }

    override func mouseUp(with event: NSEvent) {
        if isPanDragging { NSCursor.arrow.set() }
        isPanDragging = false
        isZoomDragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = coordinator, c.zoomScale > 1.01 else {
            super.scrollWheel(with: event)
            return
        }
        // Pan when zoomed in. Multiply by backing scale to keep retina
        // movement in the same drawable-pixel units the shader expects.
        // Both axes subtract the scroll delta to match the click-drag pan
        // direction (image follows the scroll).
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
