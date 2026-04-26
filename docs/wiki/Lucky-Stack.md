# Lucky Stack

The SER → final-image pipeline. Three modes balance speed against quality.

## Modes

| Mode | What it does | When to use |
| --- | --- | --- |
| **Lightspeed** | Top-N% best frames, single-AP global align, simple weighted mean. | Quick previews; "is this SER worth keeping?" |
| **Balanced** | Top-N% best frames, multi-AP local refinement, gamma-shaped quality weights. | Default. Fits 95 % of imaging sessions. |
| **Scientific** | Two-pass: top-5 % aligned-accumulated → use that as reference for re-aligning all kept frames. Gamma-shaped weights. | Demanding solar / lunar / planetary imaging where every grain of detail matters. |

## Quality grading

Each frame is scored by **3×3 Laplacian variance** on a downsampled luminance — high variance = high-frequency content = sharp frame. The score is computed once, cached (`lumaCache`), and reused across stack passes.

The **Keep %** slider picks the top fraction. 25 % is a good default; bump to 50 % for short captures, drop to 10 % for very long ones.

## Multi-AP (alignment-point) refinement

After global alignment, AstroSharper splits the frame into a grid (e.g. 8×8 for Jupiter belts) and computes a local SAD-search shift per cell. Each cell's content is warped independently, then bilinear-blended at boundaries. This catches local seeing distortions that global alignment can't.

Per-preset tuning:

| Preset | Grid | Patch half-size |
| --- | --- | --- |
| Sun · Granulation | 12×12 | 24 px |
| Sun · Prominences | 6×6 | 32 px |
| Moon · Detail | 10×10 | 28 px |
| Jupiter · Belts | 8×8 | 24 px |
| Saturn · Rings | 6×6 | 28 px |
| Mars · Surface | 12×12 | 20 px |

You can override these in the Multi-AP popup.

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

Every step except quality grading runs on the GPU. Bayer demosaic is a Metal kernel; AP shifts are dispatched in threadgroup-sized parallel; weighted accumulation uses 16-bit float ping-pong textures so it never quantises. A 1500-frame Jupiter SER stacks in under 30 seconds on M2 with Balanced mode.

## See also

- [Stabilization](Stabilization.md) — the "before lucky-stack" sequence aligner
- [Sharpening](Sharpening.md) — the bake-in pass
- [Presets](Presets.md) — preset target tuning
