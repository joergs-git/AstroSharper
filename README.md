# AstroSharper

### Lucky imaging helper for macOS

A native, GPU-accelerated lucky-imaging companion for solar, lunar and planetary astrophotographers — built from the ground up in **Swift + Metal** for GPU speeded Apple Silicon (no lame python stuff).

> You used AutoStakkert and ImPPG and Windows Stuff? - and you've always had this secret wish. If there wouldnt be a native MacOS version with much more speed, comfort and quality output?
So,here it comes finally and you are welcome to give it a try.
Feedback welcome too.

[![macOS](https://img.shields.io/badge/macOS-14%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![Metal](https://img.shields.io/badge/Metal-3-black)](https://developer.apple.com/metal/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

![AstroSharper Stacking, Sharpening, Aligning ](AstroSharper1.png)
---

## What it does

**AstroSharper** turns long SER/AVI capture sessions into crisp final images in three clicks. Drop a folder of SER captures, hit **Apply ALL Stuff** (⇧⌘A), and walk away with a stacked, aligned, deconvolved, tone-curved master file.

Every step runs on the GPU. The full pipeline — quality grading, alignment, lucky stacking, à-trous wavelets, Wiener / Lucy-Richardson deconvolution, tone-curve LUTs — lives in Metal compute kernels and `MPSGraph`. A 4K Sun frame goes through unsharp mask in under 10 ms on an M2.

## Highlights

- **One-button lucky stack** with the Lightspeed / Balanced / Scientific quality modes. Multi-AP grid alignment for solar granulation and planetary detail.
- **Three reference modes** for stabilization: full-frame phase correlation, **disc centroid** (locks onto the limb of the Sun / Moon — robust against thin cloud and seeing wobble), and **reference ROI** (pin alignment to a sunspot, prominence, or crater).
- **Mark-as-Reference** with the **R** key. Gold-star the frame you want as anchor — alignment can't drift to a low-quality first frame anymore.
- **Memory workflow**: stabilize, sharpen, tone-curve all in RAM, scrub through the result with the inline player, and only commit to disk when you're happy.
- **Smart presets** that auto-detect target from the filename (`sun_*.ser`, `Jupiter_2026-04-26.ser`, etc.).
- **iCloud-synced presets** so your Sun setup follows you between Macs.
- **SER + Bayer (RGGB / GRBG / GBRG / BGGR)** native — no pre-conversion needed.
- **AVI** files now appear in the catalog (full lucky-stack support shipping next).
- **Cmd zoom shortcuts**: `⌘=` `⌘-` `⌘0` (fit) `⌘1` (1:1) `⌘2` (200 %).
- **Apply ALL Stuff** (⇧⌘A) — single hero button that picks the right pipeline for the section you're in.

## Why AstroSharper

The lucky-imaging tool landscape on Mac is a wasteland: AutoStakkert! and Registax don't run natively, ImPPG ports are clunky wxWidgets builds. AstroSharper fixes that by being **Mac-native, sandbox-safe, and Apple-Silicon-first**, with a UI built around how astrophotographers actually work — a single window, three sections (Inputs → Memory → Outputs), and an inline player so you can blink-compare before committing.

## Coming soon — Mac App Store

AstroSharper is preparing for **Mac App Store** release. While we wait for review, you can build from source or grab the latest signed/notarized release from the [Releases](https://github.com/joergsflow/astrosharper/releases) page.

If you like AstroSharper and maybe it even saves you time or you just prefer using it , [**buy me a coffee**](https://buymeacoffee.com/joergsflow) ☕️ — every cup keeps a feature shipping. Thank you.

Requires macOS 14 (Sonoma) or newer.

### From the App Store (soon)

Coming. Watch the repo for the announcement. Or open a thread on cloudynights or so and I will answer :-) 

## Quick workflow

1. **Open** a folder of SER files (`⌘O` or drag-and-drop on the window).
2. **Press R** on the row that looks sharpest — that's now your reference frame (gold star).
3. **Pick a preset** (Sun · Granulation, Jupiter · Belts, etc.) from the toolbar dropdown — auto-detected from the filename when possible.
4. **Apply ALL Stuff** (`⇧⌘A`). AstroSharper picks the right path: lucky-stack on SER, in-memory sharpen on already-stacked frames, file-batch otherwise.
5. **Scrub the result** in the Memory tab. Tweak Sharpening / Tone-Curve sliders live. Hit **Save All** when you like what you see.

A deeper walk-through lives in [`docs/WORKFLOW.md`](docs/WORKFLOW.md), and the in-app **How AstroSharper works** window (Help menu) has the same content as a movable, non-blocking guide.

## Architecture in one paragraph

SwiftUI on top, `MTKView` preview, `MPSGraph` and hand-written Metal compute kernels underneath. Every texture is `rgba16Float` end-to-end. SER frames are memory-mapped, Bayer demosaic happens on the GPU. Phase correlation uses Accelerate's vDSP 2D FFT in parallel; lucky-stack quality grading is a Laplacian-variance compute kernel; sharpening is an à-trous wavelet decomposition with Wiener / Lucy-Richardson available as alternatives. Output is 16-bit float TIFF (or 8-bit PNG / JPEG) via ImageIO. Full breakdown in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Documentation

- [**Workflow guide**](docs/WORKFLOW.md) — smart end-to-end use cases (Sun, Moon, planets)
- [**Architecture**](docs/ARCHITECTURE.md) — code structure & GPU pipeline
- [**Wiki**](docs/wiki/Home.md) — page-per-feature reference
- [**Keyboard shortcuts**](docs/wiki/Keyboard-Shortcuts.md)
- [**Troubleshooting**](docs/wiki/Troubleshooting.md)
- [**FAQ**](docs/wiki/FAQ.md)

## Roadmap

- AVI demuxing for Lucky Stack (in progress)
- Drizzle 1.5× / 2× reconstruction
- 16-bit histogram overlay on preview
- Mac App Store release with notarization pipeline
- FITS / RAW / DNG input

## Support the project

If AstroSharper helped you turn a long capture night into a printable image, the best way to say thanks is:

- ⭐️ Star the repo
- ☕️ [Buy me a coffee](https://buymeacoffee.com/joergsflow) — even one keeps the lights on
- 📝 Leave a review on the App Store once it's live
- 🐛 Open issues with reproducible bugs and sample SERs

## License

MIT — see [LICENSE](LICENSE).

---

Made with care by [joergsflow](https://app.astrobin.com/u/joergsflow) — clear skies.
