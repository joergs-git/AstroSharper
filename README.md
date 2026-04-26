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

**AstroSharper** turns long SER/AVI capture sessions into crisp final images in three clicks. Drop a folder of SER captures, hit **Apply ALL Stuff** (⇧⌘A), and walk away with a stacked, aligned, deconvolved, tone-curved master file. But not only that. If you have already images e.g. .TIFF Files from sun or other solar system objects you can just use it to do all the sharpening stuff and create even animated images - timelapse animations etc. All in one go. So a comparison to Autostakkert or imppg and such is not really fully possible even. However, try it out by yourself and help making it better.

Every step runs on the GPU. The full pipeline — quality grading, alignment, lucky stacking, à-trous wavelets, Wiener / Lucy-Richardson deconvolution, tone-curve LUTs — lives in Metal compute kernels and `MPSGraph`. A 4K Sun frame goes through unsharp mask in under 10 ms on an Apple M2.

## Highlights

### Stacking & alignment
- **One-button lucky stack** with the Lightspeed / Balanced / Scientific quality modes. Multi-AP grid alignment for solar granulation and planetary detail.
- **Three reference modes** for stabilization: full-frame phase correlation, **disc centroid** (locks onto the limb of the Sun / Moon — robust against thin cloud and seeing wobble), and **reference ROI** (pin alignment to a sunspot, prominence, or crater).
- **Mark-as-Reference** with the **R** key. Gold-star the frame you want as anchor — alignment can't drift to a low-quality first frame anymore.
- **Apply ALL Stuff** (`⇧⌘A`) — single hero button that picks lucky-stack, in-memory ops, or file-batch depending on the section you're in.

### Quality intelligence (new)
- **Per-frame Sharpness HUD** — translucent overlay (bottom-left of the preview) shows filename, dimensions, bit-depth, Bayer pattern, file size, capture timestamp (read straight from the SER UTC header), `Frame N/M` for videos, and a live **variance-of-Laplacian** sharpness number for whatever frame you're looking at.
- **Calculate Video Quality** — one click samples up to 64 frames across a SER, builds a sharpness distribution (`p10 / median / p90`), and **recommends a lucky-stack keep-percentage** based on the spread (tight → keep top 75 %, very turbulent → keep top 10 %).
- **On-disk quality cache** at `~/Library/Application Support/AstroSharper/quality-cache.json`, fingerprinted by file size + mtime — re-opening a SER you've already scanned is instant, and per-image sharpness is computed once at import then cached forever.
- **Sortable Sharpness column** for static images — click the header to find the sharpest TIFF / PNG in a folder of intermediates.
- **Sortable Type column** — groups SERs together vs. raster images when you opened a mixed folder.

### Preview & navigation (Photoshop-style)
- **Anchored click-drag zoom** — drag right to zoom in, left to zoom out, with the pixel under the cursor staying put as the scale changes (~200 px ≈ 2×).
- **⌥-drag pan** with hand-cursor; **double-click** to reset to fit + center; **pinch** to zoom anchored to the cursor; **scroll-wheel pan** when zoomed in.
- **Cmd zoom shortcuts**: `⌘=` `⌘-` `⌘0` (fit) `⌘1` (1:1) `⌘2` (200 %).
- **Live filename filter** with **Include / Exclude** toggle — type `conv` and click 👁/👁‍🗨 to either show only `*conv*` rows or hide them all (great for stripping intermediates from a scratch folder).
- **In-SER playback** — play / pause through the frames inside a single SER at any of 1…60 fps without leaving the file. Scrub feels instant: the raw frame paints immediately, the sharpened version replaces it as soon as the GPU pipeline catches up.
- **Memory workflow**: stabilize, sharpen, tone-curve all in RAM, scrub through the result with the inline player, and only commit to disk when you're happy.

### File handling
- **SER + Bayer (RGGB / GRBG / GBRG / BGGR)** native — no pre-conversion needed.
- **AVI** files appear in the catalog (full lucky-stack support shipping next).
- **TIFF / PNG / JPEG** input, with sharpness scored on import.
- **Smart presets** auto-detect target from filename (`sun_*.ser`, `Jupiter_2026-04-26.ser`, …).
- **iCloud-synced presets** so your Sun setup follows you between Macs.
- **Meridian-flip flag** stored per file — gets rotated 180° in memory before any processing, so post-meridian captures align with the rest of the session. Icon stays out of the way and only appears on rows that are actually flipped.

### Performance
- **End-to-end Metal** — every step (quality grading, alignment, lucky stacking, à-trous wavelets, Wiener / Lucy-Richardson deconvolution, tone-curve LUTs) lives in Metal compute kernels and `MPSGraph`. A 4K Sun frame goes through unsharp mask in **under 10 ms on an Apple M2**.
- **Memory-mapped SER** — multi-GB captures cost zero RAM beyond the frames you actually touch.
- **On-demand redraw** — preview MTKView only repaints when something changed; window-resize stays buttery even with a 4K SER loaded.
- **`rgba16Float` end-to-end** — no precision lost between stages, no banding on tone-curved Sun shots.

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

- [**Wiki on GitHub**](https://github.com/joergs-git/AstroSharper/wiki) — page-per-feature reference, including the new [Preview HUD & Quality](https://github.com/joergs-git/AstroSharper/wiki/Preview-HUD-and-Quality) page
- [**Workflow guide**](docs/WORKFLOW.md) — smart end-to-end use cases (Sun, Moon, planets)
- [**Architecture**](docs/ARCHITECTURE.md) — code structure & GPU pipeline
- [**Keyboard shortcuts**](https://github.com/joergs-git/AstroSharper/wiki/Keyboard-Shortcuts)
- [**Troubleshooting**](https://github.com/joergs-git/AstroSharper/wiki/Troubleshooting)
- [**FAQ**](https://github.com/joergs-git/AstroSharper/wiki/FAQ)

## Roadmap

- AVI demuxing for Lucky Stack (in progress)
- Drizzle 1.5× / 2× reconstruction
- Frame-to-frame jitter score in the HUD recommendation
- Per-AP sharpness map overlay
- FITS / RAW / DNG input
- Mac App Store release

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
