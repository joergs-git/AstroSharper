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

    var body: some View {
        MetalPreviewRepresentable()
            .background(Color.black)
            .overlay(placeholderOverlay)
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
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
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
        // While in-memory playback has frames the preview is owned by the
        // transport — file-list selection no longer affects what's shown.
        if app.playback.hasFrames { return }

        currentFileID = app.previewFileID
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }) else {
            beforeTex = nil
            afterTex = nil
            return
        }
        let url = entry.url
        let isSER = entry.isSER

        // For SER files, read the header up front so we know the frame count
        // and can show the scrub slider. Reset scrub for non-SER files.
        if isSER {
            if let header = try? SerReader(url: url).header {
                app.previewSerFrameCount = header.frameCount
                app.previewSerFrameIndex = 0
            }
        } else {
            app.previewSerFrameCount = 0
            app.previewSerFrameIndex = 0
        }

        let flipped = entry.meridianFlipped
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tex: MTLTexture?
            if isSER {
                tex = try? SerFrameLoader.loadFrame(url: url, frameIndex: 0, device: MetalDevice.shared.device)
            } else {
                tex = try? ImageTexture.load(url: url, device: MetalDevice.shared.device)
            }
            // Apply the meridian-flip flag once, here. Everything downstream
            // sees the rotated frame.
            if flipped, let t = tex {
                tex = RotateTexture.rotate180(t, device: MetalDevice.shared.device)
            }
            let hist = isSER ? [] : Histogram.compute(url: url)
            DispatchQueue.main.async {
                self.beforeTex = tex
                self.afterTex = nil
                self.zoomScale = 1
                self.panPx = .zero
                self.app.previewHistogram = hist
                self.reprocess()
            }
        }
    }

    /// Called when the user scrubs the SER frame slider. Loads the requested
    /// frame and re-runs the processing pipeline. Throttled in the
    /// subscription so rapid scrubs don't queue up.
    func loadCurrentSerFrame() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }),
              entry.isSER else { return }
        let url = entry.url
        let frameIndex = app.previewSerFrameIndex
        let flipped = entry.meridianFlipped
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tex = try? SerFrameLoader.loadFrame(url: url, frameIndex: frameIndex, device: MetalDevice.shared.device)
            if flipped, let t = tex {
                tex = RotateTexture.rotate180(t, device: MetalDevice.shared.device)
            }
            DispatchQueue.main.async {
                guard let tex else { return }
                self.beforeTex = tex
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
    private var zoomAnchorView: NSPoint = .zero
    private var zoomStartScale: Float = 1
    private var zoomStartPan: SIMD2<Float> = .zero
    private var panDragStart: NSPoint = .zero
    private var panStartOffset: SIMD2<Float> = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let c = coordinator else { return }
        if event.clickCount == 2 {
            c.zoomScale = 1
            c.panPx = .zero
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains(.option) {
            isPanDragging = true
            panDragStart = convert(event.locationInWindow, from: nil)
            panStartOffset = c.panPx
            NSCursor.closedHand.set()
            return
        }
        isZoomDragging = true
        zoomAnchorView = convert(event.locationInWindow, from: nil)
        zoomStartScale = c.zoomScale
        zoomStartPan = c.panPx
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = coordinator else { return }
        if isPanDragging {
            let current = convert(event.locationInWindow, from: nil)
            // Pan in image pixels (inverse of effective scale).
            let eff = max(c.zoomScale, 0.001)
            c.panPx.x = panStartOffset.x - Float(current.x - panDragStart.x) / eff
            c.panPx.y = panStartOffset.y + Float(current.y - panDragStart.y) / eff
            needsDisplay = true
            return
        }
        guard isZoomDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = Float(current.x - zoomAnchorView.x)
        // ~200 pt of drag = 2x zoom change.
        let zoomFactor = powf(2.0, dx / 200.0)
        c.zoomScale = max(0.1, min(50.0, zoomStartScale * zoomFactor))
        needsDisplay = true
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
        let eff = max(c.zoomScale, 0.001)
        c.panPx.x -= Float(event.scrollingDeltaX) / eff
        c.panPx.y += Float(event.scrollingDeltaY) / eff
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let c = coordinator else { return }
        let factor = Float(1.0 + event.magnification)
        c.zoomScale = max(0.1, min(50.0, c.zoomScale * factor))
        needsDisplay = true
    }
}
