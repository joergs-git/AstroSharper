# AutoAP and AutoNuke

The headline pair that ships in v0.4 (May 2026). **AutoAP** is the engine; **AutoNuke** is the master toggle that switches it on alongside auto-PSF + auto-keep-% + tiled-deconv geometry.

## What problem does this solve?

Lucky-imaging tools traditionally make you pick:
- **AP grid size** (8×8? 12×12? 16×16?)
- **Patch size** for SAD correlation (16 px? 24 px? 48 px?)
- **PSF σ** for deconvolution
- **Keep-percentage**
- Whether **multi-AP** is even worth doing on this capture
- Tile size for tiled deconvolution

These choices interact, depend on the data (focal length, seeing, target size in pixels, frame stability), and are tuned by hand against eye-test reference images. Every other lucky-imaging app guesses; AstroSharper measures and decides per data.

## Toggle behaviour

When **AutoNuke is ON**:

| Field | Forced to |
|---|---|
| `useAutoPSF` | `true` |
| `autoPSFSNR` | `100` (re-validated 2026-05-01 against the corrected sRGB display chain) |
| `useAutoKeepPercent` | `true` (kneedle elbow on the per-frame quality histogram) |
| `multiAPGrid` | AutoAP-resolved per data |
| `multiAPPatchHalf` | AutoAP-resolved per data |
| `multiAPSearch` | derived from patchHalf |
| `useMultiAP` | controlled by the multi-AP yes/no gate |
| `tiledDeconvAPGrid` | derived from frame size |

The manual sliders / checkboxes for these stay visible but **disabled + greyed at 45 % opacity** with a `🔒 Manual controls inactive` notice underneath. **Bake-in** and **Auto-tone** stay live regardless of AutoNuke (they're output-style choices, not stack-quality decisions).

When **AutoNuke is OFF** every toggle does exactly what its label says — no implicit auto behaviour anywhere. AutoAP still runs (geometry resolver only) when multi-AP is enabled, unless the user touched the manual sliders (`multiAP.userOverride = true`).

## AutoAP algorithm

Runs CPU-side after the runner builds the reference frame. ~50–100 ms regardless of frame count.

### Stage 1 — Preflight

1. **AutoPSF on the reference luma.** Limb-LSF estimator → Gaussian σ + disc center + radius. Auto-bails on lunar / textured / cropped subjects (inner-CV check).
2. **Target keyword detection** from filename + parent folder (Sun / Moon / Jupiter / Saturn / Mars).
3. **fps from SER metadata** (parsed via `CaptureValidator.parseMetadata`).

### Stage 2 — Geometry

```
patchHalf = clamp(round(σ × 3), 8, 32)     when AutoPSF success
          = feature-size cascade           otherwise (see below)

grid      = clamp(discDiameter / (3 × patchHalf), 6, 24)   planet-in-frame
          = clamp(minDim / (8 × patchHalf), 8, 32)         full-disc / surface

search    = clamp(patchHalf / 2 + 2, 4, 16)
```

The grid divisor of 3 (not 8) gives a comfortable 8-cells-across-disc density that matches what the historical hand-tuned presets landed on (Jupiter at r=173, patchHalf=11 → 10×10 grid).

### Stage 3 — Feature-size cascade (AutoPSF bail)

When the limb fit fails, probe the reference luma at a coarse 16×16 APPlanner grid:

| Active-cell ratio | Means | patchHalf |
|---|---|---|
| > 0.60 | Surface fills frame (lunar / solar) | `clamp(minDim/32, 12, 24)` |
| < 0.25 | Compact / clustered subject | `clamp(10, 8, 14)` |
| 0.25–0.60 | Mid density | `clamp(minDim/48, 10, 20)` |

Falls through to per-target keyword fallback if no luma is available.

### Stage 4 — AP drop-list

`APPlanner.plan` scores every cell by sum-of-|LAPD| + mean luma. Drops cells below 5 % of peak luma (empty sky) AND the bottom 20 % of the surviving cells by LAPD score. The drop-list is stored on the runner; future Metal kernel work will let the per-AP shader actually skip those cells (currently informational + counted in the diagnostic line).

### Stage 5 — Multi-AP yes/no gate

Per-frame global alignment shifts (already computed by `alignAgainstReference`) get sampled in a time-scaled pilot window:

```
pilotN = clamp(fps × 3, 100, 500)        when fps available
       = clamp(frameCount / 5, 100, 500) fallback
```

Compute std-dev of the shift magnitudes. **Suppress multi-AP when stddev > 5 px** — calibrated empirically against the BiggSky regression set:

| σ_shift | Δ vs no-multi-AP | Verdict |
|---|---|---|
| 1.03 | +2.5 % | multi-AP helps |
| 1.63 | +33.7 % | multi-AP helps |
| 1.74 | +20.1 % | multi-AP helps |
| 4.63 | +20.0 % | multi-AP helps |
| **5.36** | **−6.4 %** | multi-AP HURTS — gate fires |
| **6.20** | **−11.0 %** | multi-AP HURTS — gate fires |

High temporal motion (camera shake, tracking glitch, mount drift) makes the per-AP SAD search noisier than the global single-shift, so the gate routes those captures through the fast single-shift path instead.

### Stage 6 — Tile size for deconvolution

```
tile = round((discRadius × 8 OR minDim / 4) / 100) × 100,  clamp [200, 1024]
overlap = max(20, tile / 7)
```

15 % overlap, 100-px buckets matching BiggSky's documented tile-size choices.

## Empirical regression result

`astrosharper validate --auto-ap-sweep TESTIMAGES/biggsky/`

```
fixture                                    base LAPD   preset      auto       Δ vs base   Δ vs preset
jupiter-2022-10-25                         3.272e-05   2.812e-05   3.271e-05   −0.1%       +16.3%
jupiter-2026-03-05                         4.559e-06   4.822e-06   6.095e-06   +33.7%      +26.4%
jupiter_2022-09-10 (ZWO ASI224MC)          5.768e-06   4.366e-06   6.416e-06   +11.2%      +47.0%
mars-2022-12-10                            3.562e-05   3.602e-05   3.650e-05   +2.5%       +1.3%
mond-00_06_53                              1.045e-05   9.591e-06   1.254e-05   +20.0%      +30.8%
saturn_2023-10-10 (CK-L-Sat-pipp)          2.520e-05   2.920e-05   3.027e-05   +20.1%      +3.7%
```

**Pass criteria — all green:**
- AutoAP geometry beats the hand-tuned preset (`grid=10, patchHalf=8`) on **6/6 fixtures**.
- Multi-AP + AutoAP helps vs no-multi-AP on **5/6 fixtures** (the 6th now ties the baseline because the gate fires).
- Wall-clock ratio **1.16×** baseline.

## Files

- `Engine/Pipeline/AutoAP.swift` — pure-Swift estimator + multi-AP gate + feature-size cascade + kneedle keep-fraction
- `Engine/Pipeline/AutoPSF.swift` — limb-LSF Gaussian σ estimator (auto-bails on textured)
- `Engine/Pipeline/APPlanner.swift` — cell-LAPD + luma-cutoff scoring (also drives the drop-list)
- `Engine/Pipeline/LuckyStack.swift` — `applyAutoAP(...)` runs after the reference frame is built; mutates `options` for the downstream accumulator paths
- `App/AppModel.swift` — `LuckyStackUIState.autoNuke` + per-item options builder (forces auto-PSF / auto-keep / etc. when on)
- `App/Views/LuckyStackSection.swift` — the AutoNuke pill + greyed-out manual controls + saved-file pipeline summary
- `cli/Stack.swift` — `--auto-ap=off|fast|deep` flag
- `cli/Validate.swift` — `--auto-ap-sweep` 3-way A/B harness
- `Tests/AutoAPTests.swift` — 6 suites, 8 + tests covering closed-form ranges, AutoPSF-driven path, feature-size cascade, multi-AP gate, refinement, kneedle

## Limitations + v1+ followups

- **AP drop-list isn't honoured by the GPU shader yet.** The list is computed and logged but the per-AP SAD pass currently runs on every cell. A Metal kernel update to read a drop-mask buffer is the small next step.
- **Spatial-shear pilot.** The current gate measures temporal motion, not direct spatial shear. A small per-AP SAD pass on a few frames would give a more accurate signal — needs GPU plumbing.
- **Lunar / textured subjects.** AutoPSF still bails on these; the feature-size cascade gives a sensible fallback patchHalf but the post-pass deconvolution isn't applied. C.2 in the roadmap extends AutoPSF to find the strongest step edge anywhere in the frame.

## CLI

```bash
# Default: AutoAP runs in fast mode whenever multi-AP is on
astrosharper stack capture.ser out.tif --smart-auto --keep 25 --multi-ap

# Force AutoAP off (manual override path)
astrosharper stack capture.ser out.tif --smart-auto --keep 25 --multi-ap-grid 10 --auto-ap off

# Deep mode: additional cell-shear refinement on the reference luma
astrosharper stack capture.ser out.tif --smart-auto --keep 25 --multi-ap --auto-ap deep

# Run the 3-way regression sweep across a fixture directory
astrosharper validate TESTIMAGES/biggsky --auto-ap-sweep
```
