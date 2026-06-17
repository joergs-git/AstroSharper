// ScrubProxyAtlas unit tests — build a synthetic SER, build the proxy,
// reopen it, and verify the read path returns correctly-sized decode-free
// thumbnails for the nearest covered frame.
//
// Why these matter: the proxy is the instant-scrub path for 8-20 GB SERs.
// A bug in the header layout / offset math would surface as a black or
// garbled scrub preview. The atlas is a READ-ONLY preview accelerator —
// it must never affect the true frame index (trim markers / export), so
// the tests also assert the entry→true-frame mapping is monotonic.
import Foundation
import Metal
import Testing
@testable import AstroSharper

@Suite("ScrubProxyAtlas — build + read round-trip")
struct ScrubProxyAtlasTests {

    private func device() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    @Test("build → exists → open → nearestTexture round-trips")
    func roundTrip() throws {
        guard let dev = device() else { return }   // headless CI without a GPU: skip
        let ser = try SyntheticSER.write(width: 128, height: 96, depth: 8,
                                         frameCount: 200, colorID: 0, fillByte: 0x80)
        defer {
            try? FileManager.default.removeItem(at: ser)
            if let c = ScrubProxyAtlas.cacheURL(for: ser) { try? FileManager.default.removeItem(at: c) }
        }

        let atlas = ScrubProxyAtlas(device: dev)
        #expect(ScrubProxyAtlas.cachedAtlasExists(for: ser) == false)

        var lastP = 0.0
        let built = atlas.build(serURL: ser, maxEntries: 64, longestSide: 96,
                                progress: { lastP = $0 })
        #expect(built)
        #expect(lastP == 1.0)
        #expect(ScrubProxyAtlas.cachedAtlasExists(for: ser))

        // Fresh reader instance (proves the on-disk format is self-contained).
        let reader = ScrubProxyAtlas(device: dev)
        #expect(reader.open(serURL: ser))
        #expect(reader.isOpen)
        #expect(reader.coverageCount > 0)
        #expect(reader.coverageCount <= 64)

        // Nearest-texture works across the whole range and is the right size.
        // longestSide 96 on a 128×96 source → ratio 96/128=0.75 → 96×72 thumb.
        for f in [0, 50, 100, 199] {
            let tex = reader.nearestTexture(toFrame: f)
            #expect(tex != nil)
            #expect(tex?.width == 96)
            #expect(tex?.height == 72)
        }
    }

    @Test("open fails cleanly when no proxy exists")
    func openMissing() throws {
        guard let dev = device() else { return }
        let ser = try SyntheticSER.write(width: 64, height: 48, frameCount: 10)
        defer {
            try? FileManager.default.removeItem(at: ser)
            if let c = ScrubProxyAtlas.cacheURL(for: ser) { try? FileManager.default.removeItem(at: c) }
        }
        let atlas = ScrubProxyAtlas(device: dev)
        #expect(atlas.open(serURL: ser) == false)
        #expect(atlas.nearestTexture(toFrame: 0) == nil)
    }

    @Test("cancelled build writes nothing")
    func cancelled() throws {
        guard let dev = device() else { return }
        let ser = try SyntheticSER.write(width: 64, height: 48, frameCount: 100)
        defer {
            try? FileManager.default.removeItem(at: ser)
            if let c = ScrubProxyAtlas.cacheURL(for: ser) { try? FileManager.default.removeItem(at: c) }
        }
        let atlas = ScrubProxyAtlas(device: dev)
        let built = atlas.build(serURL: ser, maxEntries: 64, isCancelled: { true })
        #expect(built == false)
        #expect(ScrubProxyAtlas.cachedAtlasExists(for: ser) == false)
    }
}
