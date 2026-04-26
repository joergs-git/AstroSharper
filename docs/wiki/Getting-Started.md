# Getting Started

Five minutes from install to first stacked image.

## Install

```bash
git clone https://github.com/joergsflow/astrosharper.git
cd astrosharper
xcodegen generate
open AstroSharper.xcodeproj
```

Press ⌘R in Xcode to build & run. (Mac App Store release coming soon — this is the source path for now.)

## First run

1. **Open a folder** — `⌘O` or drag a folder onto the window. AstroSharper recognises:
   - SER (mono + Bayer, 8/16-bit)
   - TIFF (8/16-bit, Float16)
   - PNG, JPEG
   - AVI (catalog only — full lucky-stack support shipping next)

2. **Select files** — multi-select with ⌘-click or Shift-click; ⌘A selects all. The first selected drives the preview.

3. **Mark for batch** — checkbox column or `Space`. Marks override selection for batch jobs (use marks when you want to lock a working set without losing the selection).

4. **Pick a preset** — toolbar dropdown. Built-in presets exist for Sun · Granulation, Sun · Prominences, Moon · Detail, Jupiter · Belts, Saturn · Rings, Mars · Surface, and a generic "Other". AstroSharper auto-detects the target from the filename when possible.

5. **Apply ALL Stuff** — `⇧⌘A`. The button picks the right pipeline:
   - SER selected → Lucky Stack
   - Memory tab → in-place sharpen / tone on the playback frames
   - Otherwise → file-batch (stabilize → sharpen → tone-curve, written to OUTPUTS)

6. **Save** — for memory ops, "Save All" persists everything in OUTPUTS. For lucky-stack and file-batch, files are written automatically.

## The three sections

The toggle bar above the file list switches between Inputs · Memory · Outputs. Each section has its own catalog and selection state — switching is instant because the inactive section is parked in RAM.

- **Inputs** — your source files on disk
- **Memory** — aligned / sharpened textures held in RAM. Scrub them with the inline player; nothing is written to disk until you say so.
- **Outputs** — files AstroSharper has saved this session

## Mark the reference

Press `R` on whichever frame looks sharpest in the preview. A gold star appears in its row. The Stabilize section's Reference picker defaults to "Marked", so this single keystroke pins your anchor for the whole session.

If you don't pick one, AstroSharper falls back to the first selected and warns you in the status bar.

## Where outputs land

- **Picked output folder** — set via Settings panel "Output Folder" section (creates a security-scoped bookmark; persists across launches).
- **Auto fallback** — if no folder picked: `<input-folder>/_AstroSharper/`.
- **Last resort** — sandbox `Documents/AstroSharper Outputs/`.

The status bar always shows the active output path.

## Next steps

- [Lucky Stack](Lucky-Stack.md) for the SER → final-image flow
- [Stabilization](Stabilization.md) for the alignment modes
- [Sharpening](Sharpening.md) for the deconvolution + wavelet sliders
