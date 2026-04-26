# Troubleshooting

## "Can't write to the default output location"

The picked output folder is unwritable. AstroSharper auto-falls back to the sandbox container — check the status bar for the actual output path. To pick a working folder, use Settings → Output Folder → Choose…

## Stabilization is jumpy on the Sun

Three independent fixes; try in this order:

1. Switch **Alignment** to **Disc Centroid**. Locks onto the limb — the strongest signal.
2. Press `R` on a sharp frame to pin it as Reference. Default-first frames are often poor seeing moments.
3. If the Sun has a clear sunspot or prominence: switch to **Reference ROI**, zoom in on it, and click **Lock current view as ROI**.

The DC-removal fix (mean subtraction before Hann window) is on by default and helps too — but choose a real anchor first.

## Memory tab "lost" my sharpening after Stabilize

Pre-2026-04-26 versions reloaded source files from disk on Stabilize, wiping any in-memory edits. The current version uses memory textures directly — your sharpening / tone-curve survives a re-stabilize, with a confirm prompt before the operation.

If you're on the older behaviour, update to the latest commit.

## Lucky Stack output is soft

Bake-in is OFF. Open the Lucky Stack section and turn on **Bake-in (Sharpen + Tone)**. The stacked texture will then run through the sharpening / tone pipeline before saving — what you see in the preview is what you get on disk.

## App crashes on Lucky Stack

If the crash is `SIGABRT` deep in `lucky_accumulate_with_shifts`: the multi-AP grid is too large for the available threadgroup memory. Try reducing the grid in the preset (8×8 instead of 12×12) or disable Multi-AP.

The accumulator was previously vulnerable to a threadgroup-memory race on large grids. Recent versions zero-init all 1024 slots regardless of dispatched threadgroup size.

## Thumbnails are white / blown-out

Float TIFFs (which AstroSharper itself writes) used to come back saturated through ImageIO's default thumbnail path. Current versions render thumbnails through a normalising 8-bit RGB context. Update if you're seeing this.

## "Stabilize needs ≥ 2 files"

Mark or select at least two files in the file list. Use Space to mark, ⌘-click to multi-select.

## "AVI lucky-stack support is coming"

AVI files are recognised in the catalog but the Lucky Stack engine still only supports SER. For now, convert AVIs to SER (or per-frame TIFFs which the file-batch can process).

## Preview shows the wrong frame after switching sections

Older versions cached the last-displayed file ID and skipped re-load when the section changed but the preview file ID hadn't. Current versions force-clear the cache on section switch.

## Cmd-zoom shortcuts don't fire

Make sure the main window is focused (click anywhere in the preview / list). The shortcuts come through the application's View menu.

## R key doesn't pin the reference frame

The R-key handler is bound on the `KeyEventView` sitting under the file list — it only fires when:

1. The main window is the key window
2. The user isn't typing in a text field
3. No modifier keys (no `⌘R`, no `⌥R`)

If R does nothing, click into the file list area first to ensure focus.

## Apply ALL Stuff is greyed out

`canApply` requires:
- At least one row marked or selected
- `jobStatus` is idle (no running job)

Mark or select files; if a job is "stuck" in error state, click Dismiss in the status bar to clear it.

## Where are my saved files?

Look at the status bar — the active output path is always visible there. If it's the sandbox container fallback, you'll see `~/Library/Containers/.../AstroSharper Outputs`.

## Reporting a bug

[Open an issue on GitHub](https://github.com/joergsflow/astrosharper/issues) with:

- macOS version
- Mac model (Intel / Apple Silicon)
- AstroSharper version (Help → About)
- A sample SER or TIFF that reproduces the issue (small ones — under 100 MB if possible)
- Console log if the app crashed (Console.app → search "AstroSharper")
