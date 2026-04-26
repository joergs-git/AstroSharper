# Presets

Bundles of settings (sharpening / stabilize / tone-curve / multi-AP grid) tagged with a target.

## Built-in presets

| Preset | Target | Designed for |
| --- | --- | --- |
| Sun · Granulation | sun | White-light high-resolution surface detail |
| Sun · Prominences | sun | Hα limb features, soft disc contrast |
| Sun · Sunspots | sun | Pinned-feature alignment, strong sharpening |
| Moon · Detail | moon | Crater fields, terminator texture |
| Moon · Full Disc | moon | Whole-Moon shots, gentler sharpening |
| Jupiter · Belts | jupiter | Belt detail, GRS, multi-AP 8×8 |
| Saturn · Rings | saturn | Cassini division, ring shadow |
| Mars · Surface | mars | Polar caps, Syrtis Major, multi-AP 12×12 |
| Generic · Punch | other | Default settings for unknown targets |
| Generic · Soft | other | Conservative starting point |

Built-ins are read-only. Apply one, tweak the sliders, then **Save as New Preset…** to keep your own version.

## Smart auto-detection

When you open a folder, AstroSharper scans filenames and folder names for keywords:

| Match | Auto-applied preset |
| --- | --- |
| `sun`, `sol`, `solar`, `granulation`, `proms` | Sun preset (best fit) |
| `moon`, `lunar`, `mond` | Moon · Detail |
| `jup`, `jupiter` | Jupiter · Belts |
| `sat`, `saturn` | Saturn · Rings |
| `mars` | Mars · Surface |

Detection is case-insensitive. If multiple matches: longest match wins.

You can disable auto-detection in the Preset dropdown (toggle "Auto-pick by filename").

## User presets

**Save as New Preset…** captures all current settings into a Codable `Preset` and stores it in `UserDefaults`. Each preset gets:

- A name (your choice)
- A target tag (sun / moon / jupiter / saturn / mars / other) — drives auto-detection
- Optional notes (free-form)

**Update Current** snapshots the currently-active user preset (built-ins can't be updated).

## iCloud sync

User presets live in `NSUbiquitousKeyValueStore` so they roam across your Macs automatically. Open AstroSharper on a second Mac signed into the same Apple ID and your Sun preset is already there.

(Local UserDefaults stays as a fallback if iCloud is off.)

## Per-preset Multi-AP

The Lucky Stack multi-AP grid + patch size is preset-specific. Saturn's narrow ring system needs a different grid than Jupiter's belts; the preset captures that. When you switch presets, the multi-AP popup reflects the new tuning.

## Implementation

- `Engine/Presets/Preset.swift` — Codable struct, target enum, auto-detect keyword arrays.
- `Engine/Presets/PresetManager.swift` — `ObservableObject` singleton, list of built-ins + user presets, iCloud sync.
- `App/Views/PresetMenu.swift` — toolbar dropdown UI.

## See also

- [Lucky Stack](Lucky-Stack.md)
- [Workflow](../WORKFLOW.md)
