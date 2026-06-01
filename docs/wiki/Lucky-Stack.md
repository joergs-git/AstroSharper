# Lucky Stack

The SER → final-image pipeline. Two modes balance speed against quality.

## Modes

| Mode | What it does | When to use |
| --- | --- | --- |
| **Lightspeed** | Top-N% best frames, multi-AP local refinement (via AutoAP), weighted mean. The right default for clean captures. | Most real-world data — good seeing, well-tracked, decent SNR. |
| **Scientific** | Adds an explicit top-25% **reference build** + a **re-alignment pass** before stacking. Same multi-AP refinement otherwise. | Hard data: varying seeing, drift, low SNR — where the reference choice matters. |
| **Lucky Region** | AS!4-style per-tile frame selection. The image is divided into 32×32 tiles; for EACH tile, the engine picks adaptively 1-10 of the kept frames where local quality at that tile was sharpest, then averages only those (bilinear-blended at tile boundaries). | Solar full-disc / surface where global stacking loses 40-60% detail vs Frame 0 (a moment of good seeing near a sunspot can contribute to that region even when the same frame's limb was bad). |

**Reality check (2026-05-23 headless on BiggSky moon):** on clean data Lightspeed and Scientific are indistinguishable — RMS diff 0.065%, zero pixels differ by >0.5%. Both engaged identical AutoAP refinement. Scientific's extra reference-build step matters only when the data is *hard enough* that the reference choice actually changes the alignment outcome. **Start with Lightspeed; switch to Scientific only if you can see ghosting / softness; switch to Lucky Region for solar where averaging-induced smearing is the limit.**

### Lucky Region (added 2026-05-24)

The conventional accumulator AVERAGES kept frames. On data where each frame's local sharpness varies — atmospheric seeing affects different regions differently per frame — averaging smears every feature by the sub-pixel jitter that survived global alignment. The classic AS!4 / RegiStax answer: build the output **per region**, not per frame.

**How it works:** the engine divides the output into 32×32 tiles. The existing GPU quality-grader already produces per-16×16-threadgroup partial scores; these are re-aggregated to per-tile quality scores per frame at zero extra GPU cost. For each tile, the K=1-10 sharpest frames at THAT tile are selected (adaptive — default K=1, "pure lucky region"). A custom Metal shader (`lucky_accumulate_region`) accumulates per-output-pixel using bilinear weights across the 4 adjacent tiles, so there are no hard seams.

**Empirical results (2026-05-24 bracket on LUNT Hα solar captures):**
- Frame 0 baseline edge energy = 2124 (reference)
- Bare stack (top 10% of 3000 frames): edges 1092 (**-49%** — the original "stack worse than Frame 0" problem)
- Lucky Region tile=32 pure lucky: edges 1788 (**-16%** — closes 2/3 of the gap)

Visually the Lucky Region output preserves all Frame 0 features (sunspots, secondary dots) AND has noticeably cleaner granulation with more filamentary structure visible — looks like a post-processed astrophoto, not a noisy raw frame.

**When NOT to use Lucky Region:** verified on solar surface + sunspot captures, where it wins clearly. Planetary (Jupiter, Saturn) hasn't been bracketed against Frame 0 yet — Lightspeed / Scientific are still recommended there. Sun-Granulation and Sun-Full-Disk presets now ship with `.region` as default (validated 2026-05-24).

**Hα Prominence captures: stack ≠ better than Frame 0.** A 48-variant bracket on `TESTIMAGES/sun/14_03_21_prominence.ser` (Lightspeed/Scientific/Region × keep% × multi-AP × sigma-clip × disc-mask × off-limb-alignment) showed: **every** stack variant softens the prominence wisp vs raw Frame 0. The cause is physical — the wisps deform per-frame from atmospheric seeing, so averaging integrates over the deformation. No alignment fix can recover what's morphologically different per frame. Sun-Hα-Prominence preset stays `.scientific` for backward compatibility (clean background, prominence visible but soft); for max wisp detail, export a single best frame instead.

### Disc-mask + off-limb alignment (CLI `--disc-mask`)

Opt-in for Hα prominence captures where the bright saturated disc dominates the global quality + alignment signals.

- **Quality side**: Region's per-tile selection normally picks "frames where this tile was sharpest by Laplacian variance". On prominence captures the saturated disc dominates the Laplacian → off-limb tiles inadvertently pick "frames where the DISC was sharpest", not where the prominence was clearest. Disc-mask short-circuits disc tiles to the first eligible frame (saturated → any frame is equivalent there) so off-limb tiles drive the honest selection.
- **Alignment side**: phase correlation runs on full-frame luma; the disc edge dominates the cross-power spectrum, so the off-limb prominence gets aligned via disc-anchor sub-pixel jitter. With disc-mask on, bright pixels in luma are replaced with the off-limb median BEFORE phase correlation — alignment honestly tracks off-limb features.

Helps the prominence stack incrementally (cleaner background, slightly better wisp definition vs no-mask Region) but does NOT beat raw Frame 0 for wisp detail (see prominence note above). Not enabled in any preset; use `--mode region --disc-mask` via CLI for power-user experiments.

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

## Drift correction (opt-in)

Long planetary captures sometimes drift — mount tracking error or field rotation slowly walks the planet across the frame over 20–60 s. Full-frame phase correlation can fail on the odd frame (a small bright disc on a large dark sky is noise-dominated; a frame locks on the (0,0) DC peak instead of tracking the drift), and those frames accumulate at the wrong position → a **ghost / double contour**.

Enable **Drift correction (planet wandered)** in the Lucky Stack section (CLI `--drift-correct`) for such a capture. It aligns by the **background-subtracted disc centroid** instead of phase correlation — the centroid of the brightest blob tracks the planet directly, immune to the phase-correlation scatter. It drives both the reference build and the final per-frame alignment, so the reference can't ghost either.

**Default OFF** on purpose: well-tracked captures have real shift variation, so always-on perturbed the F3 reference set. Turn it on only for a capture you can see ghosting.

**Caveat — it's data-limited.** Centroid alignment needs the disc to actually stand out. On a very low-contrast capture (planet only ~1.5–2× brighter than a bright sky — twilight, haze, or too much gain), the centroid is as noisy as phase correlation and drift correction won't rescue it. The real fix there is capture-side: more exposure on the planet, a darker sky, or shorter sub-captures (e.g. 3×10 s instead of 1×30 s) to limit how far the planet drifts within one stack.

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
