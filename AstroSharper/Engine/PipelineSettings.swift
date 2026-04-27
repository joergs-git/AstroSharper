// Settings structs for the per-frame pipeline operations.
//
// Moved out of AppModel.swift in v1.0 foundation work so both the GUI
// app and the headless CLI / test targets can reference them without
// pulling in SwiftUI / @MainActor / app state. The values are still
// presented through @Published wrappers in AppModel for the UI; the
// Engine just consumes plain Codable structs.
//
// Defaults match the previous AppModel definitions exactly so existing
// presets, preset JSON, and user state on disk keep loading.
import CoreGraphics
import Foundation

struct SharpenSettings: Equatable, Codable {
    var enabled: Bool = true

    // Classical Unsharp Mask.
    var unsharpEnabled: Bool = true
    var radius: Double = 1.5         // Gaussian sigma in pixels
    var amount: Double = 1.0         // Unsharp amount
    var adaptive: Bool = false

    // Lucy-Richardson deconvolution.
    var lrEnabled: Bool = false
    var lrIterations: Int = 30
    var lrSigma: Double = 1.3

    // Wiener deconvolution (synthetic Gaussian PSF).
    // Linear MSE-optimal inverse — sharper edges than L-R for known PSFs,
    // but ringing risk if SNR is mis-set. Best for crisp planetary frames
    // where the optical PSF is well-modelled by a Gaussian.
    var wienerEnabled: Bool = false
    var wienerSigma: Double = 1.4
    var wienerSNR: Double = 50

    // Wavelet sharpening (à-trous / starlet) — 4 dyadic scales, independently
    // boosted. Standard tool for solar/planetary sharpening (Registax-style).
    var waveletEnabled: Bool = false
    var waveletScales: [Double] = [1.8, 1.4, 1.0, 0.6]  // amounts for scales 1..4

    // -------------------------------------------------------------------
    // Block C — blind / tiled deconvolution plumbing
    // -------------------------------------------------------------------
    // Inert in v0.3.x — the field set is read by the upcoming
    // BlindDeconvolve module (C.1) and by Process Luminance Only (C.7).
    // Adding the fields now lets the UI surface them earlier and keeps
    // preset JSON forward-compatible. Defaults are BiggSky-aligned.

    /// Denoise applied DURING the PSF estimation step of blind
    /// deconvolution. Range 0–100; the higher the value the more
    /// smoothing on the ROI before fitting the kernel. BiggSky's
    /// recommended starting point is 75 for typical captures, 0 for
    /// already-clean stacked input.
    var denoiseBeforePercent: Double = 75

    /// Denoise applied AFTER the deconvolution restoration step. Same
    /// scale as `denoiseBeforePercent`. Minimum 1 is the BiggSky-
    /// recommended floor — pure 0/0 can amplify residual noise. The
    /// dual-stage design lets the user weaken the PSF estimate's
    /// smoothing while still gating noise on the output, or vice
    /// versa.
    var denoiseAfterPercent: Double = 75

    /// For OSC (one-shot color) captures: estimate the PSF on the
    /// luminance channel (weighted Y) only and apply the resulting
    /// kernel to all three RGB channels. ~3× faster than per-channel
    /// PSF estimation and BiggSky reports it produces sharper colour
    /// results because the L channel has higher SNR than the per-bayer
    /// R/G/B rasters. Default ON because the failure mode (R/G/B
    /// drifting independently in the deconv estimate) is more
    /// objectionable than the loss of per-channel adaptivity.
    var processLuminanceOnly: Bool = true

    /// Capture gamma correction applied BEFORE deconvolution.
    /// Linearises a non-linear camera output so the deconv algorithm's
    /// linear forward-model assumption holds, killing planetary edge-
    /// ringing artifacts. 1.0 means "data is already linear, no
    /// correction"; 2.0 squares the values; the camera-slider UI value
    /// (50, 100, …) is converted via `CaptureGamma.gamma(fromCameraSliderValue:)`.
    var captureGamma: Double = 1.0

    // MARK: - Codable

    /// Custom decoder so preset JSON written by older app versions
    /// (where the C.* fields didn't exist yet) keeps loading. Each
    /// field uses `decodeIfPresent` and falls back to the property's
    /// designated default. The synthesized encoder is left in place —
    /// new files always carry every field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Existing fields.
        self.enabled         = try c.decodeIfPresent(Bool.self,    forKey: .enabled)         ?? true
        self.unsharpEnabled  = try c.decodeIfPresent(Bool.self,    forKey: .unsharpEnabled)  ?? true
        self.radius          = try c.decodeIfPresent(Double.self,  forKey: .radius)          ?? 1.5
        self.amount          = try c.decodeIfPresent(Double.self,  forKey: .amount)          ?? 1.0
        self.adaptive        = try c.decodeIfPresent(Bool.self,    forKey: .adaptive)        ?? false
        self.lrEnabled       = try c.decodeIfPresent(Bool.self,    forKey: .lrEnabled)       ?? false
        self.lrIterations    = try c.decodeIfPresent(Int.self,     forKey: .lrIterations)    ?? 30
        self.lrSigma         = try c.decodeIfPresent(Double.self,  forKey: .lrSigma)         ?? 1.3
        self.wienerEnabled   = try c.decodeIfPresent(Bool.self,    forKey: .wienerEnabled)   ?? false
        self.wienerSigma     = try c.decodeIfPresent(Double.self,  forKey: .wienerSigma)     ?? 1.4
        self.wienerSNR       = try c.decodeIfPresent(Double.self,  forKey: .wienerSNR)       ?? 50
        self.waveletEnabled  = try c.decodeIfPresent(Bool.self,    forKey: .waveletEnabled)  ?? false
        self.waveletScales   = try c.decodeIfPresent([Double].self, forKey: .waveletScales)  ?? [1.8, 1.4, 1.0, 0.6]
        // New Block C fields.
        self.denoiseBeforePercent = try c.decodeIfPresent(Double.self, forKey: .denoiseBeforePercent) ?? 75
        self.denoiseAfterPercent  = try c.decodeIfPresent(Double.self, forKey: .denoiseAfterPercent)  ?? 75
        self.processLuminanceOnly = try c.decodeIfPresent(Bool.self,   forKey: .processLuminanceOnly) ?? true
        self.captureGamma         = try c.decodeIfPresent(Double.self, forKey: .captureGamma)         ?? 1.0
    }

    /// Designated memberwise init — Swift can't synthesise this
    /// alongside a custom `init(from:)` in some compiler versions, so
    /// we provide it explicitly with all defaults preserved.
    init(
        enabled: Bool = true,
        unsharpEnabled: Bool = true,
        radius: Double = 1.5,
        amount: Double = 1.0,
        adaptive: Bool = false,
        lrEnabled: Bool = false,
        lrIterations: Int = 30,
        lrSigma: Double = 1.3,
        wienerEnabled: Bool = false,
        wienerSigma: Double = 1.4,
        wienerSNR: Double = 50,
        waveletEnabled: Bool = false,
        waveletScales: [Double] = [1.8, 1.4, 1.0, 0.6],
        denoiseBeforePercent: Double = 75,
        denoiseAfterPercent: Double = 75,
        processLuminanceOnly: Bool = true,
        captureGamma: Double = 1.0
    ) {
        self.enabled = enabled
        self.unsharpEnabled = unsharpEnabled
        self.radius = radius
        self.amount = amount
        self.adaptive = adaptive
        self.lrEnabled = lrEnabled
        self.lrIterations = lrIterations
        self.lrSigma = lrSigma
        self.wienerEnabled = wienerEnabled
        self.wienerSigma = wienerSigma
        self.wienerSNR = wienerSNR
        self.waveletEnabled = waveletEnabled
        self.waveletScales = waveletScales
        self.denoiseBeforePercent = denoiseBeforePercent
        self.denoiseAfterPercent = denoiseAfterPercent
        self.processLuminanceOnly = processLuminanceOnly
        self.captureGamma = captureGamma
    }
}

struct StabilizeSettings: Equatable, Codable {
    var enabled: Bool = false
    var referenceMode: ReferenceMode = .marked
    var cropMode: CropMode = .crop
    var stackAverage: Bool = false
    var alignmentMode: AlignmentMode = .fullFrame
    /// User-defined region of interest in *normalised* reference-frame
    /// coordinates (0…1, top-left origin). Only consulted when
    /// `alignmentMode == .referenceROI`.
    var roi: NormalisedRect? = nil

    enum ReferenceMode: String, CaseIterable, Identifiable, Codable {
        /// Use the frame the user explicitly tagged with the gold-star
        /// "Reference" marker. Default — clearest user intent.
        case marked = "Marked Reference"
        case firstSelected = "First Selected"
        case brightestQuality = "Best-Quality Frame"
        var id: String { rawValue }
    }

    enum CropMode: String, CaseIterable, Identifiable, Codable {
        case pad = "Pad to Bounding Box"       // output stays at input size, black borders
        case crop = "Crop to Intersection"     // output = overlap region of all frames
        var id: String { rawValue }
    }

    /// Picks how the per-frame shift is computed. Each mode shines on a
    /// different subject:
    ///   - `.fullFrame`: phase-correlation on the whole image — robust for
    ///     general scenes with widely-distributed detail.
    ///   - `.discCentroid`: locks onto the bright disc's centre of mass
    ///     against a dark background. Designed for full-disc Sun / Moon
    ///     where surface detail is faint relative to the disc edge — the
    ///     limb itself becomes the anchor and works even on featureless
    ///     surfaces or thin clouds.
    ///   - `.referenceROI`: phase-correlate only inside a user-drawn rect
    ///     on the reference frame. Pin alignment to a specific feature —
    ///     a sunspot group, prominence, lunar crater, planetary moon
    ///     transit. Other parts of the frame are ignored entirely.
    enum AlignmentMode: String, CaseIterable, Identifiable, Codable {
        case fullFrame      = "Full Frame"
        case discCentroid   = "Disc Centroid (Sun / Moon)"
        case referenceROI   = "Reference ROI (feature lock)"
        var id: String { rawValue }
    }
}

/// Plain-Codable rect used for normalised ROI storage. CGRect isn't
/// Codable directly, so we keep our own minimal type.
struct NormalisedRect: Equatable, Codable {
    var x: Double      // 0…1, left
    var y: Double      // 0…1, top
    var w: Double      // 0…1
    var h: Double      // 0…1
    var asCGRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct ToneCurveSettings: Equatable, Codable {
    var enabled: Bool = false
    var controlPoints: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 1.0, y: 1.0),
    ]
}
