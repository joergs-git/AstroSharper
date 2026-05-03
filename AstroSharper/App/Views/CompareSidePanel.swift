// Compare side panel — vertical column of two thumbnails for
// at-a-glance A/B/C comparison alongside the main preview.
//
//   Top    : "Stacked"     — the currently displayed file thumbnail.
//                            For Outputs / Memory captures this is the
//                            stacked image *without* the live tone-curve
//                            / sharpen manipulations the main preview
//                            applies. For Inputs SER captures it's the
//                            same as the source (degenerate, but
//                            visually correct — no stack happened yet).
//   Bottom : "Source"      — frame 0 of the SER that produced the most
//                            recent lucky-stack run (`lastStackedSource*`
//                            on `AppModel`). Empty placeholder when no
//                            stack has run yet in this session.
//
// Toggle visibility from the toolbar's Compare button (keyboard shortcut B).
//
// Zoom + pan: both thumbnails share a single `zoom` + `pan` state so
// pinching one immediately reflects on the other — the whole point of
// the panel is region-locked comparison. Default zoom = 2.0× so users
// land directly on detail without having to pinch in. Range 0.5 …
// 8.0×; double-click resets to defaults.
import AppKit
import SwiftUI

struct CompareSidePanel: View {
    @EnvironmentObject private var app: AppModel

    /// Linked zoom across both thumbnails. 1.0 = fit-to-frame; default
    /// 2.0 lands on detail without forcing the user to pinch in.
    @State private var zoom: CGFloat = 2.0
    /// In-progress pinch delta — added to `zoom` on gesture end.
    @GestureState private var pinchDelta: CGFloat = 1.0
    /// Linked pan offset across both thumbnails (in points, in the
    /// thumbnail-frame coordinate space).
    @State private var pan: CGSize = .zero
    /// In-progress drag delta — added to `pan` on gesture end.
    @GestureState private var dragDelta: CGSize = .zero

    private static let defaultZoom: CGFloat = 2.0
    private static let minZoom: CGFloat = 0.5
    private static let maxZoom: CGFloat = 8.0

    private var currentFileThumbnail: NSImage? {
        guard let id = app.previewFileID else { return nil }
        return app.catalog.files.first(where: { $0.id == id })?.thumbnail
    }

    private var currentFileLabel: String {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id })
        else { return "—" }
        return entry.url.lastPathComponent
    }

    /// On Inputs the displayed file IS the source SER (no stacking
    /// has happened yet), so fall back to its thumbnail. Otherwise
    /// require a tracked `lastStackedSourceURL` — showing an
    /// unrelated file as the "source" would be misleading.
    private var sourceImage: NSImage? {
        if let img = app.lastStackedSourceThumbnail { return img }
        if app.displayedSection == .inputs { return currentFileThumbnail }
        return nil
    }

    private var sourceLabel: String {
        if let url = app.lastStackedSourceURL { return url.lastPathComponent }
        if app.displayedSection == .inputs { return currentFileLabel }
        return "Run Lucky Stack to populate"
    }

    /// Effective live zoom (committed × in-flight pinch). Clamped so
    /// pathological pinches can't flip the image inside-out or push it
    /// past usability.
    private var liveZoom: CGFloat {
        max(Self.minZoom, min(Self.maxZoom, zoom * pinchDelta))
    }

    /// Effective live pan (committed + in-flight drag).
    private var livePan: CGSize {
        CGSize(width: pan.width + dragDelta.width,
               height: pan.height + dragDelta.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                Text("\(Int(liveZoom * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    zoom = Self.defaultZoom
                    pan = .zero
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Reset zoom + pan to default (200%, centred). Double-click any thumbnail does the same.")
                .disabled(abs(zoom - Self.defaultZoom) < 0.01 && pan == .zero)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            sectionLabel("Stacked / Current File", systemImage: "photo")
            thumbnailFrame(image: currentFileThumbnail, caption: currentFileLabel)

            Divider()

            sectionLabel("Source SER · Frame 0", systemImage: "film")
            thumbnailFrame(image: sourceImage, caption: sourceLabel)
        }
        .frame(width: 200)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    @ViewBuilder
    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnailFrame(image: NSImage?, caption: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.4))
                if let img = image {
                    // Inner clip container: zoomed image is rendered at
                    // `liveZoom` × natural-fit and panned by `livePan`,
                    // then clipped to the thumbnail frame so overflow
                    // doesn't bleed onto neighbouring chrome.
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(liveZoom)
                        .offset(livePan)
                        .animation(nil, value: liveZoom)
                        .animation(nil, value: livePan)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No thumbnail")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .gesture(zoomGesture)
            .simultaneousGesture(panGesture)
            .onTapGesture(count: 2) {
                zoom = Self.defaultZoom
                pan = .zero
            }

            Text(caption)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 6)
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchDelta) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoom = max(Self.minZoom, min(Self.maxZoom, zoom * value))
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan = CGSize(width: pan.width + value.translation.width,
                             height: pan.height + value.translation.height)
            }
    }
}
