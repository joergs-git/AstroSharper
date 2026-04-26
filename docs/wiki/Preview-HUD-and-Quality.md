# Preview HUD & Video Quality

The translucent overlay in the bottom-left corner of the preview shows everything AstroSharper knows about the file you're looking at, plus a sharpness number for the current frame and — for SER captures — a recommendation for the lucky-stack keep-percentage.

## The HUD at a glance

```
🎞 Sun_2026-04-26_h-alpha.ser
   3008×3008 · 16-bit · Mono · 2.4 GB · 2026-04-26 09:14
   Frame 482/2000
   🎯 Sharpness: 0.0214  ⓘ
   ───────────────────────────
   Sampled 64 frames
   p10: 0.0091  med: 0.0173  p90: 0.0246
   Recommend: keep top 25%
   wide spread (seeing variable) — keep top 25%.
```

### Static image (TIFF / PNG / JPEG)
- Filename, dimensions, file size, capture date (filesystem mtime).
- Sharpness score for the image (variance of Laplacian — see below).

### Video (SER)
- All of the above plus:
- Bayer pattern (`Mono`, `RGGB`, `GRBG`, `GBRG`, `BGGR`, `RGB`).
- Bit depth from the SER header.
- `Frame N/M` updates live as you scrub or play.
- "Calculate Video Quality" button until the distribution scan has been run.

## What "Sharpness" means

The number is the **variance of the Laplacian** computed on the displayed frame via Metal Performance Shaders. It's a standard focus / blur metric:

- **Higher = sharper** (more high-frequency detail).
- **Compare values within the same target.** Absolute numbers depend on contrast, exposure, and dynamic range — a Sun H-alpha frame will sit in a different range than a Mars RGB frame.
- Typical range on normalised float textures: `1e-4 … 5e-2`.

## "Calculate Video Quality"

The first time you click a SER, the distribution panel says *"Video quality not yet calculated."* with a yellow **Calculate Video Quality** button.

When you click it:

1. AstroSharper samples up to **64 evenly-spaced frames** across the file.
2. For each frame it loads the texture, runs the sharpness probe, and records the score.
3. The 64 scores are sorted; AstroSharper extracts `p10 / median / p90` and the spread `p90 / p10`.
4. A recommendation is derived from the spread:

| Spread (`p90/p10`) | Verdict | Recommended keep % |
|--------------------|---------|--------------------|
| `< 1.4`            | tight quality distribution | **75 %** (keep most for SNR) |
| `1.4 – 2.0`        | moderate variance | **50 %** |
| `2.0 – 4.0`        | wide spread (seeing variable) | **25 %** |
| `> 4.0`            | very wide (turbulent seeing) | **10 %** |

The result is **persisted to disk** at:

```
~/Library/Containers/com.joergsflow.AstroSharper/Data/
   Library/Application Support/AstroSharper/quality-cache.json
```

Re-opening a previously-scanned SER is instant.

## Cache invalidation

Cache entries are fingerprinted by **file size + modification time**. If the file is overwritten with a fresh capture, the fingerprint changes and the next visit triggers a re-scan automatically.

## Sortable Sharpness column

Static images (TIFF / PNG / JPEG) are scored automatically in the background right after thumbnails. The result lands in the file list's **Sharpness** column, which is sortable — click the header to find the sharpest frame in a folder of intermediates. SER / AVI rows show "video" instead since they have a distribution rather than a single number.

## Non-obvious tips

- **Compare files of the same target/exposure**. The score isn't a global "this image is good" rating — it's relative.
- **Scrubbing is fast** even on multi-thousand-frame SERs: the raw decoded frame paints first, the sharpened version replaces it as soon as the GPU pipeline catches up.
- **The HUD is always-on.** Toggle visibility via `app.hudVisible` (no shortcut wired yet).
