// Finder thumbnail provider for AVI files (planetary / raw imaging
// AVIs in particular).
//
// Registers for `public.avi`. macOS picks ONE thumbnail extension per
// UTI; ours will replace the system default once the host app is
// installed. The user can disable us specifically via
//   System Settings → Privacy & Security → Extensions → Quick Look
// without affecting any other AstroSharper functionality.
//
// "Open With" defaults are NOT touched — those are governed by
// LaunchServices role mapping (CFBundleDocumentTypes / LSHandlerRank),
// which this extension does not declare for `public.avi`.

import QuickLookThumbnailing
import AppKit

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let maxSidePx = Int(max(request.maximumSize.width,
                                request.maximumSize.height) * request.scale)
        let target = max(maxSidePx, 256)

        guard let image = AviQL.renderRepresentativeFrame(url: request.fileURL,
                                                          maxDimension: target) else {
            // nil reply → Finder falls back to the next-priority thumbnail
            // provider (usually the system AVI generator).
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
