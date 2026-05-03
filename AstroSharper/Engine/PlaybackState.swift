// In-memory frame sequence shared by the GUI Memory tab and (later) the
// CLI's stack subcommand. Carries the current MTLTexture per frame plus
// a trail of operations that have been applied to it — both Engine
// concerns; SwiftUI bindings stay in AppModel.
//
// Moved out of AppModel.swift in v1.0 foundation work so the headless
// CLI / test targets can reference these types without pulling in
// SwiftUI. Definitions and defaults are unchanged so any in-memory or
// on-disk consumer keeps working.
import Foundation
import Metal

struct PlaybackFrame: Identifiable {
    let id: UUID         // matches FileEntry.id of the source file
    let sourceURL: URL
    var texture: MTLTexture
    /// Trail of operations that have been applied to this in-memory frame.
    /// Drives the smart filename suffixes when the user saves to disk —
    /// e.g. ["aligned", "sharp", "tone"] → `<source>_aligned_sharp_tone.tif`.
    var appliedOps: [String] = []
}

struct PlaybackState {
    var frames: [PlaybackFrame] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var fps: Double = 18
    var loop: Bool = true

    var hasFrames: Bool { !frames.isEmpty }
    var currentFrame: PlaybackFrame? {
        guard frames.indices.contains(currentIndex) else { return nil }
        return frames[currentIndex]
    }
}
