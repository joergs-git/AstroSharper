# Stabilization

Sequence-level frame-to-frame alignment. Use it when you have many same-target frames captured over time (mosaic tiles, time-lapse, separate sub-exposures) and you want them all referenced to one chosen frame.

Lucky Stack has its own internal alignment — Stabilization is for non-SER sequences and for the "I want the aligned frames in memory so I can edit them before saving" workflow.

## The reference frame

Stabilization aligns every frame *to* one chosen reference. Pick well:

- **Marked** (default) — uses whichever row holds the gold-star marker. Press `R` on a row to set.
- **First Selected** — uses whatever's first in the selection (catalog order).
- **Best-Quality Frame** — auto-pick the sharpest frame by Laplacian variance. Use when you don't know your captures well.

If you choose "Marked" without pinning a frame, AstroSharper falls back to first-selected and surfaces a yellow warning.

## Alignment modes

This is the big one for solar / lunar imaging.

### Full Frame
Default. Phase-correlation on the whole image. Robust for general scenes with widely-distributed detail (terrestrial mosaics, deep-sky pre-processing). Mean-subtracted and Hann-windowed before FFT to suppress DC dominance.

### Disc Centroid (Sun / Moon)
Threshold the luminance, compute the centre-of-mass of bright pixels, return the centroid difference as the shift. No FFT — fast and robust.

**Why it's the right choice for full-disc Sun and Moon:** the disc edge is by far the strongest signal, and centroid is immune to surface detail changes (sunspots rotating, granulation reorganising) and thin clouds. Phase-correlation can occasionally lock onto cloud edges instead of the limb; centroid never does.

### Reference ROI (feature lock)
Phase-correlate inside a user-defined rectangle on the reference frame. Everything outside is ignored.

**How to set the ROI:**
1. Switch alignment mode to "Reference ROI".
2. Zoom into the feature you want pinned (sunspot, prominence, crater pair, planet's polar cap).
3. Click **Lock current view as ROI** in the Stabilize section.
4. The rect is stored in normalised coordinates (0…1), so it survives zoom changes.

**When to use it:** when one specific feature must stay perfectly aligned and the rest of the frame is allowed to drift around it. Sunspot tracking, crater-pair time-lapses, planetary-moon transit alignment.

## Boundary mode

- **Crop to Intersection** (default) — output is the overlap region shared by all aligned frames. No black borders, but the output is smaller than the input.
- **Pad to Bounding Box** — output stays at source size. Frames that shifted have black borders where content moved out.

## Stack average after align

When ON, after stabilization the aligned frames are averaged into one output frame (basic stacking — for fancier weighted stacking use Lucky Stack). When OFF, each aligned frame is exported individually as `<name>_aligned.tif`.

## Memory workflow

When you stabilize from the Inputs section, the aligned frames land in **Memory**. They aren't on disk yet. From there:

- **Scrub** — inline player ◀⏯▶ steps through them
- **Blink-compare** — `B` toggles Before / After
- **Re-stabilize** — selecting memory rows and running Stabilize again uses the *current memory textures* (not re-loaded from disk), so any sharpening / tone curve applied in-memory is preserved
- **Pre-flight confirm** — if any memory frame already has applied ops (sharpen / tone), AstroSharper asks before re-aligning over them
- **Save All** — writes everything in Memory to OUTPUTS, file names reflect the accumulated op trail

## Implementation notes (for the curious)

- Working size: largest power-of-two ≤ 1024 along the smaller axis. Typical: 1024² FFT.
- Hann window applied before FFT (suppresses spectral leakage at frame edges).
- Mean is subtracted before windowing — critical for solar/lunar where DC dominates.
- Sub-pixel peak via 3-point parabolic fit on the cross-correlation surface.
- Cross-power normalised: `CP = (F · conj(G)) / |F · conj(G)|` — equal-magnitude across frequencies → peak is a sharp delta in the spatial domain.
- Centroid threshold: 25 % of max luminance, weighted by `(value - threshold)`. Computed at 256² downsample, then scaled back.
- All FFT runs on Accelerate's vDSP `vDSP_fft2d_zip` in parallel across frames.

## See also

- [Lucky Stack](Lucky-Stack.md) — for SER frames specifically
- [Workflow](../WORKFLOW.md) — solar / lunar / planetary recipes
