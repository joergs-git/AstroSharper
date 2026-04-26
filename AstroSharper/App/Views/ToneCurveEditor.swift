// Direct-manipulation tone curve editor, modeled on ImPPG's tone curve panel.
//
//   - Left-click near a point: drag it (SwiftUI gesture; with minimumDistance 0
//     the tap also fires a drag, so we hit-test on start).
//   - Left-click on empty area: adds a new control point at that location.
//   - Right-click or double-click on a point: deletes it (endpoints excluded).
//   - Histogram overlay with a linear / log toggle in the button row.
//   - Reset, Invert (negate), Stretch (auto-endpoints from histogram).
//
// Implementation note on hit testing:
//   A single `DragGesture(minimumDistance: 0)` on the whole area decides on
//   .onChanged's first fire whether the press started on an existing point
//   (→ move that point) or on empty area (→ placeholder; commit an insert in
//   .onEnded if the user didn't drag meaningfully). This is more reliable than
//   layering multiple `.onTapGesture` calls, which SwiftUI routes unpredictably.
import AppKit
import SwiftUI

struct ToneCurveEditor: View {
    @Binding var points: [CGPoint]
    let histogram: [UInt32]
    @Binding var logHistogram: Bool

    @State private var dragTarget: DragTarget = .none
    /// Generic hit radius for interior nodes.
    private let hitRadius: CGFloat = 16
    /// Endpoints sit at x=0 / x=1, right against the editor edge, so half
    /// their grab area is normally outside the frame. Use a bigger radius
    /// for them so the mouse can reach them comfortably.
    private let endpointHitRadius: CGFloat = 26

    private enum DragTarget { case none, movePoint(Int), pendingInsert(CGPoint) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.28))

                    // Histogram underneath curve.
                    if !histogram.isEmpty {
                        HistogramBars(histogram: histogram, log: logHistogram)
                            .frame(width: size.width, height: size.height)
                            .allowsHitTesting(false)
                    }

                    // Grid
                    Path { p in
                        for f: CGFloat in [0.25, 0.5, 0.75] {
                            p.move(to: CGPoint(x: f * size.width, y: 0))
                            p.addLine(to: CGPoint(x: f * size.width, y: size.height))
                            p.move(to: CGPoint(x: 0, y: f * size.height))
                            p.addLine(to: CGPoint(x: size.width, y: f * size.height))
                        }
                    }
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)

                    // Identity diagonal
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height))
                        p.addLine(to: CGPoint(x: size.width, y: 0))
                    }
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // The curve itself
                    Path { p in
                        let sorted = points.sorted { $0.x < $1.x }
                        let samples = 128
                        for i in 0...samples {
                            let t = CGFloat(i) / CGFloat(samples)
                            let y = CGFloat(sampleCurve(t: Double(t), points: sorted))
                            let pt = CGPoint(x: t * size.width, y: (1 - y) * size.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 1.5)

                    // Control point dots (cosmetic — gesture handling lives on the overlay).
                    ForEach(Array(points.enumerated()), id: \.offset) { idx, pt in
                        let isDragging = { if case .movePoint(let i) = dragTarget, i == idx { return true } else { return false } }()
                        let isEndpoint = pt.x <= 0.001 || pt.x >= 0.999
                        let dotSize: CGFloat = isEndpoint ? 14 : 12
                        ZStack {
                            // Halo to make endpoints visually larger and clearly grabable.
                            if isEndpoint {
                                Circle()
                                    .stroke(Color.accentColor.opacity(0.30), lineWidth: 2)
                                    .frame(width: dotSize + 8, height: dotSize + 8)
                            }
                            Circle()
                                .fill(isDragging ? Color.white : Color.accentColor)
                                .frame(width: dotSize, height: dotSize)
                        }
                        .position(x: pt.x * size.width, y: (1 - pt.y) * size.height)
                        .allowsHitTesting(false)
                    }

                    // Transparent gesture catcher — receives ALL input. Right-click
                    // is routed via a local NSEvent monitor below.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    handleDragChanged(location: g.location, start: g.startLocation, in: size)
                                }
                                .onEnded { g in
                                    handleDragEnded(end: g.location, translation: g.translation, in: size)
                                }
                        )

                    RightClickOverlay { loc in
                        removePoint(nearest: loc, in: size)
                    }
                    .allowsHitTesting(true)
                }
            }
            .frame(height: 180)

            HStack(spacing: 6) {
                Button("Reset") { resetIdentity() }
                    .controlSize(.small)
                Button("Invert") { invert() }
                    .controlSize(.small)
                Button("Stretch") { stretchToHistogram() }
                    .controlSize(.small)
                    .disabled(histogram.isEmpty)
                Toggle(isOn: $logHistogram) { Text("Log Hist") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                Spacer()
            }

            Text("click = add · drag = move · right-click / ⇧click on point = remove")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Gesture handling

    private func handleDragChanged(location: CGPoint, start: CGPoint, in size: CGSize) {
        switch dragTarget {
        case .none:
            if let hit = hitTest(point: start, in: size) {
                dragTarget = .movePoint(hit)
                moveControlPoint(index: hit, to: location, in: size)
            } else {
                dragTarget = .pendingInsert(start)
            }
        case .movePoint(let idx):
            moveControlPoint(index: idx, to: location, in: size)
        case .pendingInsert:
            // Still no point was targeted; ignore until we know it's a tap.
            break
        }
    }

    private func handleDragEnded(end: CGPoint, translation: CGSize, in size: CGSize) {
        defer { dragTarget = .none }
        let dragDist = hypot(translation.width, translation.height)
        switch dragTarget {
        case .pendingInsert(let start) where dragDist < 3:
            // Shift+click on a point removes it (alternative to right-click).
            if NSEvent.modifierFlags.contains(.shift),
               let hit = hitTest(point: start, in: size) {
                removePoint(at: hit)
            } else {
                insertPoint(at: start, in: size)
            }
        default:
            break
        }
    }

    // MARK: - Model ops

    private func hitTest(point: CGPoint, in size: CGSize) -> Int? {
        var best: (idx: Int, dist: CGFloat)?
        for (i, pt) in points.enumerated() {
            let px = pt.x * size.width
            let py = (1 - pt.y) * size.height
            let d = hypot(point.x - px, point.y - py)
            // Endpoints (first / last after x-sort) get a larger reachable
            // radius. Order in `points` may not be sorted, so we check
            // pinned x-values: 0 or 1 ⇒ endpoint.
            let isEndpoint = (pt.x <= 0.001 || pt.x >= 0.999)
            let radius = isEndpoint ? endpointHitRadius : hitRadius
            if d < radius, (best == nil || d < best!.dist) {
                best = (i, d)
            }
        }
        return best?.idx
    }

    private func insertPoint(at location: CGPoint, in size: CGSize) {
        let nx = Double(max(0, min(1, location.x / size.width)))
        let ny = Double(max(0, min(1, 1 - location.y / size.height)))

        var pts = points.sorted { $0.x < $1.x }
        var insertAt = pts.count
        for i in 0..<pts.count where Double(pts[i].x) > nx { insertAt = i; break }
        if insertAt > 0, abs(Double(pts[insertAt - 1].x) - nx) < 0.01 { return }
        if insertAt < pts.count, abs(Double(pts[insertAt].x) - nx) < 0.01 { return }
        pts.insert(CGPoint(x: nx, y: ny), at: insertAt)
        points = pts
    }

    private func removePoint(at index: Int) {
        let sorted = points.sorted { $0.x < $1.x }
        guard index > 0, index < sorted.count - 1 else { return }
        var pts = sorted
        pts.remove(at: index)
        points = pts
    }

    private func removePoint(nearest location: CGPoint, in size: CGSize) {
        if let idx = hitTest(point: location, in: size) {
            removePoint(at: idx)
        }
    }

    private func moveControlPoint(index: Int, to viewLoc: CGPoint, in size: CGSize) {
        let nx = max(0, min(1, viewLoc.x / size.width))
        let ny = max(0, min(1, 1 - viewLoc.y / size.height))
        let clampedX: CGFloat
        if index == 0 { clampedX = 0 }
        else if index == points.count - 1 { clampedX = 1 }
        else {
            let left = points[index - 1].x + 0.01
            let right = points[index + 1].x - 0.01
            clampedX = max(left, min(right, nx))
        }
        points[index] = CGPoint(x: clampedX, y: ny)
    }

    // MARK: - Button actions

    private func resetIdentity() {
        points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)]
    }

    private func invert() {
        // Negate curve: map x → 1 - y(x). Same endpoints swap: (0,0)→(0,1), (1,1)→(1,0).
        var pts = points.sorted { $0.x < $1.x }
        for i in 0..<pts.count {
            pts[i].y = 1 - pts[i].y
        }
        points = pts
    }

    private func stretchToHistogram() {
        guard !histogram.isEmpty else { return }
        let (lowX, highX) = Histogram.stretchBounds(histogram: histogram, lowPercent: 0.2, highPercent: 0.2)
        // Auto-stretch: two anchor points map histogram boundaries to 0..1.
        points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: lowX, y: 0),
            CGPoint(x: highX, y: 1),
            CGPoint(x: 1, y: 1),
        ]
    }

    private func sampleCurve(t: Double, points raw: [CGPoint]) -> Double {
        var pts = raw.sorted { $0.x < $1.x }
        if pts.first?.x != 0 { pts.insert(CGPoint(x: 0, y: pts.first?.y ?? 0), at: 0) }
        if pts.last?.x != 1  { pts.append(CGPoint(x: 1, y: pts.last?.y ?? 1)) }
        guard pts.count >= 2 else { return t }
        var i = 0
        for k in 0..<(pts.count - 1) where t >= Double(pts[k].x) && t <= Double(pts[k + 1].x) {
            i = k; break
        }
        let p0 = pts[max(i - 1, 0)]
        let p1 = pts[i]
        let p2 = pts[min(i + 1, pts.count - 1)]
        let p3 = pts[min(i + 2, pts.count - 1)]
        let segLen = max(Double(p2.x - p1.x), 1e-6)
        let u = (t - Double(p1.x)) / segLen
        let y = 0.5 * (
            (2.0 * Double(p1.y)) +
            (-Double(p0.y) + Double(p2.y)) * u +
            (2.0 * Double(p0.y) - 5.0 * Double(p1.y) + 4.0 * Double(p2.y) - Double(p3.y)) * u * u +
            (-Double(p0.y) + 3.0 * Double(p1.y) - 3.0 * Double(p2.y) + Double(p3.y)) * u * u * u
        )
        return max(0.0, min(1.0, y))
    }
}

// MARK: - Histogram bars

private struct HistogramBars: View {
    let histogram: [UInt32]
    let log: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Path { p in
                guard !histogram.isEmpty else { return }
                let normed: [Double] = histogram.map { raw in
                    log ? Foundation.log(1.0 + Double(raw)) : Double(raw)
                }
                let maxV = max(normed.max() ?? 1.0, 1.0)
                let barW = size.width / CGFloat(histogram.count)
                for (i, v) in normed.enumerated() {
                    let h = CGFloat(v / maxV) * size.height
                    let x = CGFloat(i) * barW
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x, y: size.height - h))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
    }
}

// MARK: - Right-click overlay
//
// Receives right-clicks only — hit-tests as transparent to anything else so
// the DragGesture below keeps working for left-click add/move.

struct RightClickOverlay: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickOnlyView {
        let v = RightClickOnlyView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: RightClickOnlyView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

final class RightClickOnlyView: NSView {
    var onRightClick: ((CGPoint) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // AppKit's origin is bottom-left, SwiftUI's is top-left.
        let flipped = CGPoint(x: loc.x, y: bounds.height - loc.y)
        onRightClick?(flipped)
    }

    // Transparent to every event except right-click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let eventType = NSApp.currentEvent?.type
        switch eventType {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point)
        default:
            return nil
        }
    }
}
