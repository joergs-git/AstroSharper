# AstroSharper

### Lucky imaging helper for macOS

A native, GPU-accelerated lucky-imaging companion for solar, lunar and planetary astrophotographers — built from the ground up in **Swift + Metal** for Apple Silicon (no Python wrappers, no Wine, no Boot Camp).

> You used AutoStakkert and ImPPG and Windows stuff? — and you've always had this secret wish: if there were a native macOS version with much more speed, comfort and quality output…
> So, here it comes finally and you are welcome to give it a try.
> Feedback welcome too.

**📥 Now available — free — on the [Mac App Store](https://apps.apple.com/de/app/astrosharper/id6778564449?mt=12).**

[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-Download-0D96F6?logo=apple&logoColor=white)](https://apps.apple.com/de/app/astrosharper/id6778564449?mt=12)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![Metal](https://img.shields.io/badge/Metal-3-black)](https://developer.apple.com/metal/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

![AstroSharper Stacking, Sharpening, Aligning](AstroSharper1.png)

---

## What it does

**AstroSharper** turns long SER capture sessions into crisp final images with as little manual tuning as possible. Drop a folder of SER captures, flip the **AutoNuke** master toggle on, hit **Run Lucky Stack**, and walk away with a stacked, aligned, deconvolved master file. The engine picks AP geometry, PSF σ, keep-percentage and multi-AP yes/no — all per-data, no settings to guess at.

Already have stacked images (TIFF / PNG / JPEG)? Skip Lucky Stack entirely and use the post-stack sharpening + tone pipeline on its own. Either way it's the same UI, same pipeline, same Apple-Silicon-native speed — every step runs on the GPU via Metal compute kernels and `MPSGraph`. A 4K Sun frame goes through unsharp mask in **under 10 ms on an Apple M2**.

## Highlights

- **AutoNuke + AutoAP** — one master toggle hands every "auto" decision to the engine: PSF σ from the limb, AP grid + patch size per data, multi-AP gate, auto keep-%. Beats hand-tuned presets on every fixture in the regression set. → [Lucky Stack](https://github.com/joergs-git/AstroSharper/wiki/Lucky-Stack)
- **Smart Auto-PSF + Radial Fade Filter** — one-click, parameter-free deconvolution that measures the PSF from the planetary limb and suppresses the dark Gibbs ring on discs over dark sky. → [Sharpening](https://github.com/joergs-git/AstroSharper/wiki/Sharpening)
- **Folder watch + auto-stack** — point it at your SharpCap / FireCapture capture folder and walk away; each new SER is stacked the moment its capture finishes writing. NAS-safe (polling re-scan, size-stability gating).
- **Stacking & alignment** — Lightspeed / Scientific modes, disc-centroid & ROI stabilization, per-channel stacking for OSC cameras, drizzle 1.5×/2×/3×, opt-in drift correction. → [Stabilization](https://github.com/joergs-git/AstroSharper/wiki/Stabilization)
- **Quality intelligence** — per-frame sharpness HUD, one-click video-quality scan with a keep-% recommendation, on-disk quality cache. → [Preview HUD & Quality](https://github.com/joergs-git/AstroSharper/wiki/Preview-HUD-and-Quality)

## Quick workflow

1. **Open** a folder of SER files (`⌘O` or drag-and-drop on the window).
2. **Watch the target picker** at the top light up for the detected target. Click a different chip to override.
3. *(Optional)* **Press R** on the sharpest-looking row to pin it as the reference — AutoNuke picks a sensible one if you don't.
4. Open the **Lucky Stack** section, flip **AutoNuke** ON.
5. Hit **Run Lucky Stack**. The saved TIFF lands in `OUTPUTS/` automatically.

The in-app **How AstroSharper works** window (Help menu) has the same content.

## Documentation

📖 **[The Wiki](https://github.com/joergs-git/AstroSharper/wiki)** is the full reference — a page per feature (Lucky Stack, Sharpening, Stabilization, Tone Curve, Presets, File Formats, Output Folders, Keyboard Shortcuts, Troubleshooting, FAQ).

Also in this repo: [Workflow guide](docs/WORKFLOW.md) · [Architecture](docs/ARCHITECTURE.md) · [Changelog](CHANGELOG.md).

## More from joergsflow

Part of a small native astro toolkit — each app handles one stage well:

- **[AstroBlink](https://apps.apple.com/app/id6760241266)** *(macOS)* — blink, cull & stack your capture frames
- **[AstroFileViewer](https://apps.apple.com/app/id6760240080)** *(iPhone & iPad)* — view FITS / SER / TIFF captures on iOS

## Support the project

If AstroSharper helped you turn a long capture night into a printable image:

- ⭐️ Star the repo
- 📝 [Leave a review on the Mac App Store](https://apps.apple.com/de/app/astrosharper/id6778564449?mt=12)
- ☕️ [Buy me a coffee](https://buymeacoffee.com/joergsflow)
- 🐛 Open issues with reproducible bugs and sample SERs

## License

MIT — see [LICENSE](LICENSE).

---

Made with care by [joergsflow](https://app.astrobin.com/u/joergsflow) — clear skies.
