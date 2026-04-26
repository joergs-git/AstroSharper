// A preset bundles all processing settings under a single name + target.
// Built-in presets are tuned for typical solar/lunar/planetary lucky-imaging
// targets; user presets are written by the user and synced via the
// PresetManager.
import Foundation

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
        case .jupiter: return "circle.hexagongrid.fill"
        case .saturn:  return "circle.dashed.inset.filled"
        case .mars:    return "globe.europe.africa.fill"
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
    var luckyMultiAPGrid: Int = 0
    /// Patch radius for AP correlation (px). 8 → 16×16 patch.
    var luckyMultiAPPatchHalf: Int = 8
    /// Optional extra-stack variants. Empty by default.
    var luckyVariants: LuckyStackVariants = LuckyStackVariants()

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
        luckyVariants: LuckyStackVariants = LuckyStackVariants()
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
        return Preset(
            name: "Sun — Granulation",
            target: .sun, notes: "Fine-scale granulation. Sharp wavelet1, mild unsharp.",
            isBuiltIn: true,
            sharpen: s,
            luckyMode: .scientific, luckyKeepPercent: 30,
            luckyMultiAPGrid: 12, luckyMultiAPPatchHalf: 24
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
        return Preset(
            name: "Sun — Full Disk",
            target: .sun, notes: "Full-disk balanced sharpen with mild S-curve.",
            isBuiltIn: true,
            sharpen: s, toneCurve: t,
            luckyMode: .lightspeed, luckyKeepPercent: 50,
            luckyMultiAPGrid: 8, luckyMultiAPPatchHalf: 32
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
        return Preset(
            name: "Sun — Hα Prominence",
            target: .sun, notes: "Off-limb Hα prominences: strong stretch, soft sharpen.",
            isBuiltIn: true,
            sharpen: s, toneCurve: t,
            luckyMode: .scientific, luckyKeepPercent: 40,
            luckyMultiAPGrid: 8, luckyMultiAPPatchHalf: 32
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
