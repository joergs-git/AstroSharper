// Spacebar QuickLook preview for AstroSharper SER files — with looping
// frame playback.
//
// QuickLook gives us an NSViewController; we own its view. Strategy:
//   1. On `preparePreviewOfFile`, open a SerPlayer (persistent FileHandle).
//   2. Decode frame 0 synchronously off the main queue, paint it into
//      the NSImageView, THEN call `handler(nil)` so the QL panel never
//      flashes a black frame.
//   3. Start a DispatchSourceTimer ~25 fps on the same private decode
//      queue. Each tick: bump the index, decode the next frame, hop to
//      main to swap the NSImage. Coalesced timer events handle the case
//      where decode is slower than the 40 ms interval (large SERs at
//      4K) — playback degrades gracefully to whatever fps the I/O +
//      debayer pipeline can sustain.
//   4. Cancel the timer in `viewWillDisappear` + deinit. Closing the
//      QL panel triggers viewWillDisappear so we don't leak the
//      FileHandle once the user dismisses the preview.
//
// Auto-play loop only — no on-screen controls. The QL panel is a
// fleeting affordance ("press space, glance, press space"), so a
// minimal continuous loop matches user expectations from QL previews
// of other animated formats (GIF, system AVI, etc.).

import Cocoa
import Quartz

final class PreviewProvider: NSViewController, QLPreviewingController {

    private let imageView = NSImageView()
    private var player: SerPlayer?
    private var timer: DispatchSourceTimer?
    private var frameIndex: Int = 0

    /// Serial queue for all file I/O and decode work. Keeping this off
    /// the main queue is what makes the panel responsive while a 4K
    /// planetary frame is being debayered + stretched.
    private let decodeQueue = DispatchQueue(
        label: "com.joergsflow.AstroSharper.SerQuickLookPreview.decode",
        qos: .userInitiated)

    // MARK: - View

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        decodeQueue.async { [weak self] in
            guard let self = self else { handler(nil); return }

            guard let player = SerPlayer(url: url, maxDimension: 768) else {
                // Bad header / unreadable — let QL fall back to nothing.
                DispatchQueue.main.async { handler(nil) }
                return
            }
            self.player = player
            self.frameIndex = 0

            // Render frame 0 BEFORE signalling completion so the QL
            // panel pops up with content already drawn.
            let firstFrame = player.image(at: 0)

            DispatchQueue.main.async {
                if let cg = firstFrame {
                    self.imageView.image = NSImage(
                        cgImage: cg,
                        size: NSSize(width: cg.width, height: cg.height))
                }
                handler(nil)
                // Only kick off looping playback if there's more than one
                // frame — saves a useless timer for single-frame SERs.
                if player.frameCount > 1 {
                    self.startPlayback()
                }
            }
        }
    }

    // MARK: - Playback loop

    /// 25 fps target. Real fps will be `min(25, 1 / decode_time)`
    /// because the timer fires on the decode queue and the system
    /// coalesces overlapping events on a serial queue.
    private func startPlayback() {
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now() + .milliseconds(40),
                       repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self = self, let player = self.player else { return }
            self.frameIndex &+= 1
            let next = player.image(at: self.frameIndex)
            DispatchQueue.main.async {
                if let cg = next {
                    self.imageView.image = NSImage(
                        cgImage: cg,
                        size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Cleanup

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.cancel()
        timer = nil
        // Drop the player so its FileHandle closes promptly via deinit
        // — important when the user spacebar-scrolls through dozens of
        // SERs in a row; we don't want N FileHandles hanging around
        // waiting for ARC to get to them.
        player = nil
    }

    deinit {
        timer?.cancel()
    }
}
