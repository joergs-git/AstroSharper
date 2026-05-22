# Lucky Stack

The SER → final-image pipeline. Two modes balance speed against quality.

## Modes

| Mode | What it does | When to use |
| --- | --- | --- |
| **Lightspeed** | Top-N% best frames, single-AP global align, weighted mean. AutoStakkert-equivalent. Fast. | Whole-disc subjects with little local distortion (full-disc Sun / Moon); quick "is this SER worth keeping?" passes. |
| **Scientific** | Builds a reference from the top frames, re-aligns all kept frames to it, multi-AP local refinement, LoG quality grading, optional post-stack Wiener deconvolution. Slower, higher fidelity. | High-resolution surface / planetary work where local seeing matters. |

(There is no "Balanced" mode — earlier docs listed one that was never in the code. The enum is exactly `lightspeed` + `scientific`.)

## Quality grading

Each frame is scored by a **Laplacian / LoG sharpness metric** on a downsampled luminance — high response = high-frequency content = sharp frame. The score is computed once, cached, and reused across stack passes.

The **Keep %** slider picks the top fraction. Sensible defaults are target-dependent (see [Presets](Presets.md)): planetary 20–25 %, lunar 25–50 %, solar 30–50 %. `--auto-keep` resolves it from the frame-quality distribution, clamped to a [20 %, 75 %] band with a frame-count floor so very short captures don't over-reject.

## Multi-AP (alignment-point) refinement

After global alignment, AstroSharper splits the frame into a grid (e.g. 8×8 for Jupiter belts) and computes a local SAD-search shift per cell. Each cell's content is warped independently, then bilinear-blended at boundaries. This catches local seeing distortions that global alignment can't.

Per-preset tuning (matches `BuiltInPresets`):

| Preset | Grid | Patch half-size |
| --- | --- | --- |
| Sun — Granulation | **off** | — |
| Sun — Full Disk | off | — |
| Sun — Hα Prominence | **off** | — |
| Moon — High Detail | 10×10 | 24 px |
| Moon — Wide Field | off | — |
| Jupiter — Standard | 10×10 | 24 px |
| Jupiter — Belt Detail | 10×10 | 16 px |
| Saturn — Standard | 10×10 | 24 px |
| Saturn — Ring Emphasis | 12×12 | 24 px |
| Mars — Standard | 6×6 | 16 px |

The **Sun presets run multi-AP OFF** (retuned 2026-05-22): a benchmark showed per-cell SAD smears low-contrast solar surface and warps the limb. You can override in the Multi-AP popup. **AutoAP** (default on) picks grid + patch from the reference frame automatically; touching the sliders or running with `--multi-ap-grid N` switches to manual. See [Presets](Presets.md) for *why* the grids differ per target.

### Aperture-problem rejection (2026-05-22)

When multi-AP IS engaged, each cell only earns a local shift if its SAD minimum is well-defined in BOTH axes — a genuine 2D feature. A cell sitting on a smooth, locally-straight edge (the curved solar limb, a planetary terminator) has a SAD *valley* along the edge tangent, so the along-edge shift is arbitrary; left unchecked, neighbouring cells warp the edge into a blocky zig-zag. Such cells (and flat low-contrast cells) now fall back to the global alignment. The F3 regression set confirms Jupiter multi-AP is unaffected — only genuinely ambiguous cells are dropped.

## Variants

Run multiple stacks from one SER in one click. Each non-zero entry in the Variants section adds a labelled run that lands in its own subdirectory:

```
   _luckystack/
   ├── jupiter_lucky.tif        (default slider-based run)
   ├── f200/
   │   └── jupiter_lucky.tif    (top-200 absolute count)
   ├── f500/
   │   └── jupiter_lucky.tif    (top-500 absolute count)
   ├── p15/
   │   └── jupiter_lucky.tif    (top-15 % run)
   └── p35/
       └── jupiter_lucky.tif    (top-35 % run)
```

Compare them in OUTPUTS, keep the best.

## Bake-in

Default **ON**. The stacked texture is run through the standard Sharpen + Tone-Curve pipeline before writing — so the saved file looks like the live preview. Turn off to keep raw stacks for separate downstream processing in Photoshop / PixInsight / etc.

## Filename modes

- **SharpCap** style (default): `<basename>_stack.tif`
- **WinJUPOS** style: `YYYY-MM-DD-HHmm_s-<target>.tif` — built from the SER's UTC timestamp and the preset's target. Falls back to SharpCap style if the SER has no embedded timestamp.

## Why this is fast

Every step except quality grading runs on the GPU. Bayer demosaic is a Metal kernel; AP shifts are dispatched in threadgroup-sized parallel; weighted accumulation runs in **32-bit float** so it never banks visible quantisation banding through the later sharpen pass. A 1500-frame Jupiter SER stacks in well under a minute on an M2 in Scientific mode.

## See also

- [Stabilization](Stabilization.md) — the "before lucky-stack" sequence aligner
- [Sharpening](Sharpening.md) — the bake-in pass
- [Presets](Presets.md) — preset target tuning
