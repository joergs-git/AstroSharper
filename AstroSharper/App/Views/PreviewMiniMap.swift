// Mini-map / viewport indicator overlay for the preview. When the user
// has zoomed in past fit-to-view, this shows a tiny thumbnail of the full
// frame with a dashed rectangle marking the visible sub-region — same
// idiom as Photoshop's Navigator panel and AstroBlinkV2's mini-map.
//
// Hidden when the whole image fits in the view (AppModel.previewViewport
// is nil) — no point showing a 100% rect over a thumbnail.
import SwiftUI

struct PreviewMiniMap: View {
    /// Thumbnail of the source image. 48–256 px is plenty since the map
    /// itself only renders 110 px wide. nil → solid grey placeholder.
    let thumbnail: NSImage?
    /// Visible viewport in normalised image coords (0…1, top-left origin).
    let viewport: CGRect

    private let mapWidth: CGFloat = 110

    var body: some View {
        let imgSize = thumbnail?.size ?? CGSize(width: 4, height: 3)
        let aspect = imgSize.width > 0 ? imgSize.height / imgSize.width : 0.75
        let mapHeight = mapWidth * aspect
        ZStack(alignment: .topLeading) {
            // Background — the thumbnail itself, or a placeholder swatch.
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: mapWidth, height: mapHeight)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: mapWidth, height: mapHeight)
            }

            // Dashed viewport rectangle. Convert from normalised image
            // coords into the mini-map's coordinate space.
            Rectangle()
                .strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
                .frame(width: max(2, viewport.width * mapWidth),
                       height: max(2, viewport.height * mapHeight))
                .offset(x: viewport.minX * mapWidth,
                        y: viewport.minY * mapHeight)
        }
        .overlay(
            // Outer border so the whole map reads as a discrete chip on
            // both bright and dark previews.
            Rectangle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .background(Color.black.opacity(0.45))
        .padding(12)
        .help("Mini-map — yellow rectangle marks the visible viewport. Hidden when the full image fits in the view.")
    }
}
