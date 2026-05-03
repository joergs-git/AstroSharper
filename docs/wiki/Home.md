# AstroSharper Wiki

Welcome. This wiki mirrors the in-app **How AstroSharper works** window plus deeper reference for every section.

## Pages

- [Getting Started](Getting-Started.md) — first folder, first stack
- [**AutoAP and AutoNuke**](AutoAP-and-AutoNuke.md) — *new (2026-05)*: the engine-decides path, master toggle, regression results
- [Preview HUD & Quality](Preview-HUD-and-Quality.md) — sharpness probe, distribution scan, lucky-% recommendation
- [Lucky Stack](Lucky-Stack.md) — quality grading, multi-AP, variants
- [Stabilization](Stabilization.md) — reference modes, alignment modes, ROI, memory path
- [Sharpening](Sharpening.md) — STEP 1 / 2 / 3 pipeline, wavelet, unsharp, Wiener, Lucy-Richardson
- [Tone Curve](Tone-Curve.md) — Catmull-Rom spline editor and 1D LUT
- [Presets](Presets.md) — built-ins, user presets, iCloud sync, smart auto-detection
- [Keyboard Shortcuts](Keyboard-Shortcuts.md)
- [File Formats](File-Formats.md) — what you can read and write
- [Output Folders](Output-Folders.md) — sandbox, NAS, fallback rules
- [Troubleshooting](Troubleshooting.md)
- [FAQ](FAQ.md)

## At a glance

AstroSharper is a one-window, three-section app:

```
   Inputs          Memory             Outputs
   ──────          ──────             ───────
   files on disk → align/stack/sharp → saved files
                  in RAM, scrub before
                  committing
```

The headline-bar **target picker chips** show which target was auto-detected for the previewed file (Sun / Moon / Jupiter / Saturn / Mars / Other). The chip lights up in colour when a keyword matches; clicking any chip applies that target's first built-in preset. Scrolling between SER files updates the highlight live.

## The four entry points (since 2026-05)

| Entry | Where | What |
|---|---|---|
| **AutoNuke toggle** | Lucky Stack panel | Engine picks every auto-feature, manual sliders grey out |
| **Run Lucky Stack** | Lucky Stack panel | Runs the stack with whatever's currently configured |
| **Apply to Selection** (⌘R) | Process menu | Per-file batch (sharpen / tone) on already-stacked files |
| **Target picker chip click** | Header bar | Force-apply a different target's built-in preset |

The old **Apply ALL Stuff** super-button was removed in 2026-05 because the AutoNuke + per-section "Run" buttons make the intent more visible.

## Where to find help inside the app

- **Help → How AstroSharper works** — opens a movable, non-blocking window with the same step-by-step intro
- **Help → Show Welcome Screen…** — re-open the splash
- **Help → AstroSharper on GitHub** — opens this repo
- **Help → Example images on AstroBin** — joergsflow's gallery of real captures processed with AstroSharper
- **Help → Buy me a coffee ☕️** — opens the coffee dialog directly
- **About AstroSharper** (app menu) — version, links

## Privacy + community

Two opt-OUT (default ON) toggles in the bottom status bar:

- **Anonymous telemetry** — random per-machine UUID + AutoAP / AutoPSF stats per stack. Lets the engine's defaults converge on what works empirically across the user fleet. No filenames, no hostnames, no personal data.
- **Community share** — after each successful stack, asks once whether to upload a small JPEG thumbnail + minimal metadata. Per-stack opt-in stays granular; bottom-bar icon disables globally.

Both icons turn **green** when active and dim grey when off. iCloud sync icon is informational only (presets sync via NSUbiquitousKeyValueStore when an iCloud account is signed in).

## Community Stacks viewer

Violet **Community** button in the headline bar (right side) — or **Help → Show other peoples' stacks…** (⇧⌘C) — opens a floating non-modal window with a 3-column grid of the latest uploads from all users.

- Server caps each contributor at 6 entries + 50 total → diverse feed without one prolific user dominating.
- Each card shows the JPEG (loaded via 1-h-TTL signed URL, no auth needed client-side), target chip, UTC date + time + Z suffix, stack duration, frame count, machine UUID short-form, and a YOU badge on your own contributions.
- **Double-click any thumbnail** → opens in a Mac-native pinch-to-zoom viewer at 1.5× initial size, centered. Pinch / smart-magnify (two-finger double-tap) / scroll-bar pan all native via `NSScrollView` with magnification + a custom centering clip view. Range 0.25× → 8×.

## Support

If AstroSharper is useful to your imaging workflow, the kindest things you can do:

1. ⭐️ Star [the GitHub repo](https://github.com/joergsflow/astrosharper)
2. ☕️ [Buy me a coffee](https://buymeacoffee.com/joergsflow)
3. 📝 Leave an App Store review once it lands
4. 🐛 File issues with reproducible bugs and a sample SER

Clear skies.
