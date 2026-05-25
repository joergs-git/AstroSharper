// A preset bundles all processing settings under a single name + target.
// Built-in presets are tuned for typical solar/lunar/planetary lucky-imaging
// targets; user presets are written by the user and synced via the
// PresetManager.
import Foundation

/// Full lucky-stack tuning block stored alongside the live-preview
/// Sharpen / Tone settings on a preset. Optional in `Preset` so old
/// presets (saved before 2026-05-02) decode cleanly with this absent;
/// new saves always populate it. Captures every toggle / slider in
/// the Lucky Stack section that materially affects output:
///   - autoNuke + auto* flags (the engine-decides bundle)
///   - manual sharpening / deconv path (auto-PSF, denoise, tiled)
///   - accumulator path (drizzle, sigma-clip, per-channel)
///   - radial fade filter (RFF)
///   - output-style choices (bake-in, auto-tone)
struct LuckyPresetDetails: Codable, Equatable {
    /// Default true to match the master `LuckyStackUIState.autoNuke`
    /// default (since 2026-05-24 commit 0dae988). Previously false here
    /// meant picking a preset with luckyDetails silently flipped the
    /// user's AutoNuke off — surprise bug the user flagged on
    /// 2026-05-25. AutoAP v1 beats hand-tuned presets on the regression
    /// suite (6/6 fixtures), so a preset-picked-then-Nuke'd state is
    /// the empirically correct default.
    var autoNuke: Bool = true
    /// Default FALSE (reverted 2026-05-24 after the day-of regression):
    /// AutoPSF Wiener post-deconv produces unnatural-looking output
    /// (white halo rings around sunspots, over-sharpened granulation)
    /// that the user explicitly rejected even though a naive metric
    /// (dark-core / bright-bg "dot contrast") rated it 0.679 = "+14%
    /// over Frame 0". The metric was capturing the ringing artifact as
    /// "more contrast", not naturalness. User-validated finding: the
    /// path to a natural-looking solar stack that beats Frame 0 is
    /// FINE multi-AP (grid 16, patch ~8), not post-stack deconv. See
    /// [[project-autopsf-solar-2026-05-24]] for the full empirical
    /// trail of this dead end.
    var autoPSF: Bool = false
    var autoPSFSNR: Double = 50
    var autoKeepPercent: Bool = false
    var perChannelStacking: Bool = false
    var denoisePrePercent: Int = 0
    var denoisePostPercent: Int = 0
    var tiledDeconv: Bool = false
    var tiledDeconvAPGrid: Int = 8
    var sigmaClipEnabled: Bool = false
    var sigmaClipThreshold: Double = 2.5
    var drizzleScale: Int = 1
    var drizzlePixfrac: Double = 0.7
    var drizzleAASigma: Double = 0.7
    var bakeInProcessing: Bool = false
    var autoRecoverDynamicRange: Bool = false
    var rffMode: RFFMode = .auto
    var rffInnerFraction: Double = 0.85
    var rffOuterFraction: Double = 1.05
}

/// Keywords used by the auto-detector. We match on lowercased substrings of
/// each file's path so e.g. "/Sun/2026-04/cap.ser" or "Jupiter_001.ser" both
/// route to the right target without the user picking anything.
enum PresetAutoDetect {
    static let keywords: [(target: PresetTarget, words: [String])] = [
        (.sun,     ["sun", "solar", "sonne", "halpha", "h-alpha", "ha_", "lunt"]),
        (.moon,    ["moon", "mond", "lunar", "luna"]),
        (.jupiter, ["jup", "jupiter"]),
        (.saturn,  ["sat", "saturn"]),
        (.mars,    ["mars"]),
    ]

    /// Returns a guessed target based on the first match against any of the
    /// candidate strings (typically the file name and the parent folder name).
    /// Returns nil if nothing matches; caller should leave the active preset
    /// untouched in that case.
    static func detect(in candidates: [String]) -> PresetTarget? {
        let lowered = candidates.map { $0.lowercased() }
        for (target, words) in keywords {
            for word in words {
                for s in lowered where s.contains(word) {
                    return target
                }
            }
        }
        return nil
    }
}

enum PresetTarget: String, CaseIterable, Codable, Identifiable {
    case sun       = "Sun"
    case moon      = "Moon"
    case jupiter   = "Jupiter"
    case saturn    = "Saturn"
    case mars      = "Mars"
    case other     = "Other"

    var id: String { rawValue }

    /// SF Symbol icon name.
    var icon: String {
        switch self {
        case .sun:     return "sun.max.fill"
        case .moon:    return "moon.fill"
        // Jupiter + Saturn also have custom shape renderings in
        // `TargetIconView` (belted disc / ringed disc) used by the
        // big chips in the toolbar. The SF Symbol strings here are
        // the fallback for plain Image / Label call sites.
        case .jupiter: return "circle.hexagongrid.fill"
        case .saturn:  return "circle.dashed.inset.filled"
        case .mars:    return "circle.fill"  // small filled disc — Mars is a tiny red dot in real captures
        case .other:   return "scope"
        }
    }

    /// Hint text shown next to the picker.
    var hint: String {
        switch self {
        case .sun:     return "Solar disk / granulation / proms"
        case .moon:    return "Lunar surface, terminator detail"
        case .jupiter: return "Jupiter — fast rotation, 90s windows"
        case .saturn:  return "Saturn — rings, low contrast"
        case .mars:    return "Mars — small disk, often noisy"
        case .other:   return "Custom target"
        }
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var target: PresetTarget
    var notes: String
    var isBuiltIn: Bool
    var createdAt: Date
    var modifiedAt: Date

    var sharpen: SharpenSettings
    var stabilize: StabilizeSettings
    var toneCurve: ToneCurveSettings
    var luckyMode: LuckyStackMode
    var luckyKeepPercent: Int
    /// Multi-AP grid edge length: 0 = off, otherwise N → N×N AP grid.
    /// Hint only as of 2026-05-02: AutoAP runs on every stack and
    /// resolves the actual grid from the reference frame's content +
    /// detected disc geometry. This value is consumed by AutoAP as
    /// the prior / fallback when AutoPSF bails (lunar / textured /
    /// cropped subjects). User can still override via the GUI sliders
    /// or `--multi-ap-grid N` — both flip AutoAP into the manual
    /// path so this value is honoured unchanged.
    var luckyMultiAPGrid: Int = 0
    /// Patch radius for AP correlation (px). 8 → 16×16 patch. Same
    /// "hint only" semantics as `luckyMultiAPGrid` — AutoAP picks the
    /// effective patchHalf from AutoPSF σ when available; this
    /// preset value is consumed only as the fallback prior.
    var luckyMultiAPPatchHalf: Int = 8
    /// Optional extra-stack variants. Empty by default.
    var luckyVariants: LuckyStackVariants = LuckyStackVariants()
    /// Full lucky-stack tuning block (autoNuke, auto-PSF, denoise,
    /// tiled deconv, sigma-clip, drizzle, RFF, bake-in, auto-tone).
    /// Optional for backwards-compatible decoding of presets saved
    /// before 2026-05-02 — new saves always populate it. nil on a
    /// loaded preset → applyPreset leaves the corresponding GUI
    /// fields at their session-current values.
    var luckyDetails: LuckyPresetDetails? = nil

    init(
        id: UUID = UUID(),
        name: String,
        target: PresetTarget,
        notes: String = "",
        isBuiltIn: Bool = false,
        sharpen: SharpenSettings,
        stabilize: StabilizeSettings = StabilizeSettings(),
        toneCurve: ToneCurveSettings = ToneCurveSettings(),
        luckyMode: LuckyStackMode = .lightspeed,
        luckyKeepPercent: Int = 25,
        luckyMultiAPGrid: Int = 0,
        luckyMultiAPPatchHalf: Int = 8,
        luckyVariants: LuckyStackVariants = LuckyStackVariants(),
        luckyDetails: LuckyPresetDetails? = nil
    ) {
        let now = Date()
        self.id = id
        self.name = name
        self.target = target
        self.notes = notes
        self.isBuiltIn = isBuiltIn
        self.createdAt = now
        self.modifiedAt = now
        self.sharpen = sharpen
        self.stabilize = stabilize
        self.toneCurve = toneCurve
        self.luckyMode = luckyMode
        self.luckyKeepPercent = luckyKeepPercent
        self.luckyMultiAPGrid = luckyMultiAPGrid
        self.luckyMultiAPPatchHalf = luckyMultiAPPatchHalf
        self.luckyVariants = luckyVariants
        self.luckyDetails = luckyDetails
    }
}

// MARK: - Built-in library

enum BuiltInPresets {
    /// Returns the built-in presets — tuned defaults for the typical
    /// lucky-imaging targets. Tweaks were chosen to match common processing
    /// recipes for each object class.
    static func all() -> [Preset] {
        return [
            sunGranulation(),
            sunFullDisk(),
            sunProminence(),
            moonHighDetail(),
            moonWideField(),
            jupiterStandard(),
            jupiterBeltDetail(),
            saturnStandard(),
            saturnRings(),
            marsStandard(),
        ]
    }

    // MARK: Sun

    private static func sunGranulation() -> Preset {
        // Fine-scale granulation: aggressive small-scale wavelets, light unsharp.
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.2
        s.amount = 0.6
        s.adaptive = true
        s.lrEnabled = false
        s.waveletEnabled = true
        s.waveletScales = [2.4, 1.6, 0.8, 0.4]   // boost finest, taper coarse
        // Stacking retune (2026-05-22): multi-AP OFF + sigma-clip + lower
        // keep. A 10-run headless benchmark on a LUNT partial-disc white-
        // light SER showed dense multi-AP (12×12) was the WORST of all
        // tested combos — it smears low-contrast granulation and warps the
        // smooth limb (aperture problem). Scientific reference-build +
        // global alignment + sigma-clip + keep 20% scored within a hair of
        // the lightspeed best, with better outlier rejection. See
        // tasks/lessons.md 2026-05-22.
        var d = LuckyPresetDetails()
        d.sigmaClipEnabled = true
        d.sigmaClipThreshold = 2.5
        return Preset(
            // Switched to Lucky Region 2026-05-24 after user-validated
            // bracket on TESTIMAGES/sun/14_02_07_partial.ser and 14_09_57_
            // fulldisc.ser: bare scientific stacks lose ~50% edge energy
            // vs Frame 0, sunspots smear, granulation gets averaged. Lucky
            // Region (per-tile pure-lucky K=1, 32×32 tiles) preserves
            // sunspot definition AND has cleaner granulation than Frame 0.
            // sigma-clip stays in case there are partial cloud frames.
            name: "Sun — Granulation",
            target: .sun, notes: "Fine-scale granulation. Lucky Region (per-tile sharpest-frame selection) + sigma-clip. Beat bare stacks on the partial-disc + fulldisc bracket 2026-05-24.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .region, luckyKeepPercent: 25,
            luckyMultiAPGrid: 0, luckyMultiAPPatchHalf: 24,
            luckyDetails: d
        )
    }
    private static func sunFullDisk() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 2.0
        s.amount = 1.0
        s.adaptive = false
        s.waveletEnabled = true
        s.waveletScales = [1.4, 1.6, 1.4, 0.8]
        var t = ToneCurveSettings()
        t.enabled = true
        // Mild S-curve to lift mid-tones.
        t.controlPoints = [.init(x: 0, y: 0), .init(x: 0.35, y: 0.30), .init(x: 0.75, y: 0.85), .init(x: 1, y: 1)]
        // Solar Dual-Zone: lifts off-limb area so prominences at the
        // limb become visible in the same image as the disc surface
        // (validated 2026-05-24 on TESTIMAGES/sun/14_09_57_fulldisc.ser).
        // Overrides the S-curve above when on.
        t.solarDualZone = true
        return Preset(
            // Switched to Lucky Region 2026-05-24. Same bracket as
            // Sun-Granulation: sunspots stay crisp, granulation cleaner
            // than Frame 0. multi-AP no longer needed since Region's
            // per-tile selection IS the local refinement.
            name: "Sun — Full Disk",
            target: .sun, notes: "Full-disk lucky region. Preserves sunspot definition + cleaner granulation than Frame 0 (validated 2026-05-24).",
            isBuiltIn: true,
            sharpen: s, toneCurve: t,
            luckyMode: .region, luckyKeepPercent: 25,
            luckyMultiAPGrid: 0, luckyMultiAPPatchHalf: 32
        )
    }
    private static func sunProminence() -> Preset {
        // Hα prominences: very low contrast off-limb, need stretch + careful sharpen.
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 2.5
        s.amount = 0.8
        s.adaptive = true
        s.waveletEnabled = false
        var t = ToneCurveSettings()
        t.enabled = true
        // Strong stretch — typical Hα off-limb workflow.
        t.controlPoints = [.init(x: 0, y: 0), .init(x: 0.05, y: 0), .init(x: 0.25, y: 0.85), .init(x: 1, y: 1)]
        // Solar Dual-Zone: when the prominence capture also catches a
        // sliver of the saturated disc (typical for limb prominence
        // shots), this exposes BOTH at once instead of clipping the
        // disc to pure white. Overrides the control-points curve above
        // when on. Pure off-limb captures (no disc in frame) still
        // benefit from the asinh-stretch of the dark half.
        t.solarDualZone = true
        // Multi-AP OFF here too — off-limb Hα is even lower-contrast than
        // white-light granulation, so per-cell SAD correlation is noise-
        // dominated. Keeps the higher keep-% (40) for SNR on the faint
        // prominences (unlike Granulation, this isn't a sharpness-limited
        // surface target). Sigma-clip rejects the worst seeing frames.
        var d = LuckyPresetDetails()
        d.sigmaClipEnabled = true
        d.sigmaClipThreshold = 2.5
        return Preset(
            // Stays .scientific 2026-05-24. Empirical bracket on
            // TESTIMAGES/sun/14_03_21_prominence.ser showed: ANY stacking
            // (scientific, region, region+disc-mask, region+disc-mask+
            // off-limb-align) softens the prominence wisp vs raw Frame 0.
            // The wisp deforms physically per-frame due to seeing, so
            // averaging integrates over those variations — fundamental
            // limit. Stack here gives cleaner background; raw Frame 0
            // (or single-best-frame export) gives sharpest wisp detail.
            // Power users: try `--mode region --disc-mask` via CLI for a
            // noise-cleaned stack with usable wisp visibility.
            name: "Sun — Hα Prominence",
            target: .sun, notes: "Off-limb Hα prominences: strong stretch, soft sharpen, sigma-clip, no multi-AP. NOTE: stacking softens prominence wisps vs raw Frame 0 by ~10-20% (the wisps deform frame-to-frame due to seeing — a fundamental limit). Stack for clean background; export single-best-frame for max wisp detail.",
            isBuiltIn: true,
            sharpen: s, toneCurve: t,
            luckyMode: .scientific, luckyKeepPercent: 40,
            luckyMultiAPGrid: 0, luckyMultiAPPatchHalf: 32,
            luckyDetails: d
        )
    }

    // MARK: Moon

    private static func moonHighDetail() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.5
        s.amount = 1.4
        s.adaptive = false
        s.waveletEnabled = true
        s.waveletScales = [2.0, 1.8, 1.0, 0.5]
        return Preset(
            name: "Moon — High Detail",
            target: .moon, notes: "Lunar terminator detail. Aggressive small-scale, balanced overall.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 25,
            luckyMultiAPGrid: 10, luckyMultiAPPatchHalf: 24
        )
    }
    private static func moonWideField() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 2.5
        s.amount = 1.0
        s.waveletEnabled = true
        s.waveletScales = [1.2, 1.4, 1.2, 0.8]
        return Preset(
            name: "Moon — Wide Field",
            target: .moon, notes: "Whole-disk lunar shot. Conservative sharpen.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .lightspeed, luckyKeepPercent: 50,
            luckyMultiAPGrid: 8, luckyMultiAPPatchHalf: 32
        )
    }

    // MARK: Jupiter

    private static func jupiterStandard() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.4
        s.amount = 1.0
        s.adaptive = false
        // Wiener over L-R for Jupiter — sharper edges on the Galilean moons
        // and the GRS rim, with lower iteration cost. SNR 60 is conservative
        // for a typical 100-frame stack of decent seeing.
        s.wienerEnabled = true
        s.wienerSigma = 1.5
        s.wienerSNR = 60
        s.lrEnabled = false
        s.waveletEnabled = true
        s.waveletScales = [1.6, 1.5, 1.0, 0.6]
        return Preset(
            name: "Jupiter — Standard",
            target: .jupiter, notes: "Balanced sharpen + light L-R deconvolution.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 25,
            luckyMultiAPGrid: 10, luckyMultiAPPatchHalf: 24
        )
    }
    private static func jupiterBeltDetail() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.0
        s.amount = 0.9
        s.adaptive = true
        s.lrEnabled = true
        s.lrIterations = 35
        s.lrSigma = 1.2
        s.waveletEnabled = true
        s.waveletScales = [2.5, 1.8, 1.0, 0.4]
        return Preset(
            name: "Jupiter — Belt Detail",
            target: .jupiter, notes: "Aggressive small-scale to bring out belt structure.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 20,
            luckyMultiAPGrid: 10, luckyMultiAPPatchHalf: 16
        )
    }

    // MARK: Saturn

    private static func saturnStandard() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.6
        s.amount = 0.9
        s.adaptive = false
        // Saturn's body has lower contrast than Jupiter — slightly higher
        // SNR keeps Wiener from boosting noise in the disc.
        s.wienerEnabled = true
        s.wienerSigma = 1.6
        s.wienerSNR = 80
        s.lrEnabled = false
        s.waveletEnabled = true
        s.waveletScales = [1.4, 1.5, 1.2, 0.7]
        return Preset(
            name: "Saturn — Standard",
            target: .saturn, notes: "Balanced for the rings + planet body.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 25,
            luckyMultiAPGrid: 10, luckyMultiAPPatchHalf: 24
        )
    }
    private static func saturnRings() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.2
        s.amount = 0.9
        s.adaptive = true
        s.waveletEnabled = true
        s.waveletScales = [1.8, 1.8, 1.0, 0.4]
        return Preset(
            name: "Saturn — Ring Emphasis",
            target: .saturn, notes: "Push ring contrast without crushing the body.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 30,
            luckyMultiAPGrid: 12, luckyMultiAPPatchHalf: 24
        )
    }

    // MARK: Mars

    private static func marsStandard() -> Preset {
        var s = SharpenSettings()
        s.enabled = true
        s.unsharpEnabled = true
        s.radius = 1.0
        s.amount = 0.8
        s.adaptive = false
        s.lrEnabled = true
        s.lrIterations = 20
        s.lrSigma = 1.3
        s.waveletEnabled = true
        s.waveletScales = [1.4, 1.3, 0.8, 0.3]   // mild — Mars is small + noisy
        return Preset(
            name: "Mars — Standard",
            target: .mars, notes: "Conservative — Mars is small and noisy at typical SNR.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 35,
            luckyMultiAPGrid: 6, luckyMultiAPPatchHalf: 16
        )
    }
}
