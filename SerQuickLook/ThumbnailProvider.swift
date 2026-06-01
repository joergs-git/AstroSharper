// Finder thumbnail provider for AstroSharper SER files.
//
// macOS calls `provideThumbnail` whenever Finder needs an icon for a
// .ser file — column view, gallery view, the title-bar icon during
// drag, the Cover Flow strip, etc. We decode a representative frame
// via SerQL, then paint it into the canvas Finder asked for, aspect-
// fitted with a transparent letterbox so the grid stays square.
//
// The QLThumbnailReply closure runs on a private rendering queue
// inside the QuickLook XPC service; nothing here touches AppKit
// state besides drawing into the supplied CGContext.

import QuickLookThumbnailing
import AppKit

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Translate the requested point-size + scale into a pixel cap.
        // Finder usually asks for 16..512 pt; the actual @2x icon is up
        // to 1024 px on the long edge. We give SerQL a safe floor of
        // 256 px so the percentile stretch has enough signal to work
        // with even when Finder requests a tiny preview.
        let maxSidePx = Int(max(request.maximumSize.width,
                                request.maximumSize.height) * request.scale)
        let target = max(maxSidePx, 256)

        guard let image = SerQL.renderRepresentativeFrame(url: request.fileURL,
                                                          maxDimension: target) else {
            // nil reply → Finder falls back to the system's generic icon.
            handler(nil, nil)
            return
        }

        let reply = QLThumbnailReply(contextSize: request.maximumSize) { context -> Bool in
            let canvas = CGRect(origin: .zero, size: request.maximumSize)
            let imgAspect = CGFloat(image.width) / CGFloat(image.height)
            let canvasAspect = request.maximumSize.width / request.maximumSize.height
            var draw = canvas
            if imgAspect > canvasAspect {
                let h = canvas.width / imgAspect
                draw = CGRect(x: 0,
                              y: (canvas.height - h) / 2,
                              width: canvas.width,
                              height: h)
            } else {
                let w = canvas.height * imgAspect
                draw = CGRect(x: (canvas.width - w) / 2,
                              y: 0,
                              width: w,
                              height: canvas.height)
            }
            context.draw(image, in: draw)
            return true
        }
        handler(reply, nil)
    }
}
