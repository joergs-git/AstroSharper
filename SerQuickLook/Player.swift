// On-demand SER frame decoder for the QuickLook preview extension.
//
// The thumbnail pipeline (Core.swift's `renderRepresentativeFrame`)
// opens + closes a FileHandle per call — fine for one-shot use. For
// frame-by-frame playback we want a single open handle for the whole
// preview-panel session, so we don't pay the open()/close() syscall
// overhead 25 times per second.
//
// Design notes:
//   • SerPlayer is NOT thread-safe. The owning PreviewProvider serialises
//     all `image(at:)` calls onto a single private background queue.
//   • Frames are decoded fresh each call (no internal cache). Planetary
//     SERs can be multi-GB; caching would blow the QL XPC's memory cap
//     (~50–100 MB). Re-decoding ~10–30 MB of raw bytes per frame fits
//     comfortably.
//   • `maxDimension` is intentionally lower than thumbnail/single-frame
//     preview (default 768 px) — playback prioritises smoothness over
//     resolution; spacebar QL panels rarely exceed ~900 px wide anyway.

import Foundation
import CoreGraphics

final class SerPlayer {

    let header: SerQL.Header
    /// Total number of frames recorded in the SER container.
    var frameCount: Int { header.frameCount }
    /// Long-edge cap (pixels) applied during downsample. Lower = faster
    /// playback at the cost of preview sharpness.
    let maxDimension: Int

    private let handle: FileHandle
    private let frameBytes: Int

    init?(url: URL, maxDimension: Int = 768) {
        guard let header = SerQL.readHeader(url: url),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        self.header = header
        self.handle = handle
        self.maxDimension = maxDimension
        self.frameBytes = header.bytesPerFrame
    }

    deinit { try? handle.close() }

    /// Decode the frame at `index`. Out-of-range values wrap into
    /// `[0, frameCount)` so the timer-driven playback loop can just
    /// monotonically increment its counter forever without bounds
    /// checks of its own.
    func image(at index: Int) -> CGImage? {
        guard frameCount > 0 else { return nil }
        let i = ((index % frameCount) + frameCount) % frameCount
        let offset = UInt64(178 + i * frameBytes)

        do { try handle.seek(toOffset: offset) } catch { return nil }
        guard let raw = try? handle.read(upToCount: frameBytes),
              raw.count == frameBytes else { return nil }

        let rgb8 = SerQL.convertToRGB8(raw: raw, header: header)
        guard !rgb8.isEmpty else { return nil }
        let rgba = SerQL.autoStretchRGB8ToRGBA(rgb8: rgb8,
                                               width: header.width,
                                               height: header.height)
        let (pixels, w, h) = SerQL.downsampleRGBA(rgba,
                                                  width: header.width,
                                                  height: header.height,
                                                  maxDim: maxDimension)
        return SerQL.makeCGImage(rgba8: pixels, width: w, height: h)
    }
}
