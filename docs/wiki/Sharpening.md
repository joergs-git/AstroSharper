# Sharpening

Two distinct families of "sharpening", each with its own picker. Pro
practice is to use **one method from each family** — never two of the
same kind. The UI enforces this via a dual-picker design (since
2026-05-02).

```
   STEP 1: SHARPEN  ────────────────────────────────────────────────
   ┌─ Deconvolution ──────────┐  ┌─ Boost ────────────────────────┐
   │ Off / Wiener / LR        │  │ Off / Unsharp / Wavelet        │
   │  + Pre-gamma slider      │  │                                │
   └──────────────────────────┘  └────────────────────────────────┘
                          + Noise Reduction (orthogonal toggle)

   STEP 2: TONE CURVE & COLOUR  →  Save
   (AWB + ACDC live at the top of STEP 2; the curve editor sits below)
```

## Why two families and not one stack-everything UI

Every "sharpener" falls into one of two categories that work on
fundamentally different signal:

| Family | Methods | What it does | Why |
|---|---|---|---|
| **Deconvolution** | Wiener, Lucy-Richardson | *Inverts* the blur using a PSF model | Recovers detail actually lost to atmosphere/optics |
| **Boost** | Unsharp Mask, Wavelet (à-trous) | *Amplifies* existing high-frequency content | No PSF; just contrast at a chosen scale |

Combining one from each family is **standard pro pipeline** —
PixInsight / AS!4 / RegiStax all use deconv-then-boost. The deconv
recovers blurred-away detail; the boost amplifies what survives.

Stacking two of the *same* family is **always bad**:

| Combination | Verdict |
|---|---|
| Wiener + Wavelet | ✅ classic pro pipeline (different operations, different frequencies) |
| LR + Unsharp | ✅ less common but legitimate finishing pass |
| Off + Wavelet | ✅ typical post-stack flow when Lucky Stack `--smart-auto` already baked Wiener |
| Wiener + Lucy-Richardson | ❌ two deconvs → severe ringing, over-deconv |
| Unsharp + Wavelet | ❌ two boosts → compounded halos for the same gain you'd get tuning ONE harder |

The pickers prevent the bad combinations by construction: each
picker is `Off | Method A | Method B`, and you can independently
pick from each.

## Deconvolution

### Wiener

FFT-based linear MSE-optimal deconvolution. Inverts the assumed
Gaussian PSF in frequency space, with a regularisation term that
trades off detail recovery against noise amplification.

**When it shines:** clean planetary captures with a known seeing
PSF. Solar Hα. Anywhere the noise floor is low enough that
ringing artifacts won't dominate.

**Sliders:**
- **PSF σ** (0.3–6 px) — assumed Gaussian PSF width. Match the
  seeing FWHM you measured (or let `--smart-auto` measure it
  from the limb LSF and bake it into the stack).
- **SNR** (5–500) — lower = more regularisation, less ringing,
  softer output. The smart-auto default is 100; push higher only
  if the result looks too soft.

### Lucy-Richardson

Iterative non-negative deconvolution. Each iteration:

1. Convolve current estimate with PSF
2. Divide observed by that
3. Convolve the ratio with the flipped PSF
4. Multiply current estimate by that

Converges towards the maximum-likelihood solution.

**When it shines:** photon-noise-dominated sources where Wiener
amplifies the noise. Faint planetary moons. Saturn's outer rings.

**Sliders:**
- **Iterations** (1–200) — start at 10–25, only push higher if
  bands clearly aren't recovering. Ringing grows monotonically
  with iteration count.
- **PSF σ** (0.3–8 px) — same role as Wiener's σ.

**Cost:** ~2× Gaussian-blur (via MPSImageGaussianBlur) + divide
+ multiply per iteration. 30 iterations on a 1 K stack ≈ 200 ms
on M2.

### Pre-gamma (linearisation)

Appears under the Deconvolution picker when a method is selected.

Both deconvolutions assume a *linear* forward model: `observed =
scene * PSF + noise`. SharpCap / FireCapture saves typically apply
a display gamma (≈ 2.0) before writing the SER, breaking that
assumption — Wiener / LR on gamma-encoded data ring badly. The
Pre-gamma slider undoes that encode before the deconv runs and
re-applies it after.

**Recommended:** match the gamma your capture program applied. Set
to 1.0 for already-linear sources (raw flat-fielded TIFFs from
PixInsight). 2.0 ≈ default SharpCap / ZWO display gamma. Same role
as WaveSharp's `PreGamma` loader option.

## Boost

### Unsharp Mask

Classic Gaussian-difference sharpening. `out = orig + amount *
(orig − blur(orig, σ))`. Adaptive variant modulates `amount` per
pixel by local luminance — boosts brights, leaves dark areas
alone (so you don't amplify noise in shadows).

**When it shines:** quick lift on a single scale. Final polish
when wavelet is overkill.

**Sliders:**
- **Radius (σ)** (0.2–15 px) — Gaussian σ that defines "high
  frequency". 1–3 px is typical for planetary.
- **Amount** (0–8) — multiplier on the unsharp detail. 0.5–1.5
  typical; >2 starts ringing on edges.
- **Adaptive** (toggle) — recommended on for noisy stacks.

### Wavelet (à-trous)

Multi-scale starlet decomposition. Splits the image into N detail
bands, each band covering 2× the spatial scale of the previous
one (1, 2, 4, 8, 16, 32 px). Boost each band independently.

**When it shines:** anywhere with detail at multiple spatial
scales — lunar craters and mare boundaries, Jupiter's bands and
Great Red Spot, solar granulation and prominences. The default
Registax-style 6-band layout reproduces what RegiStax users have
been doing for years.

**Sliders:**
- **Scale 1..N** (0–20 each) — per-band amplitude. 1.0 = neutral,
  >1 boost, <1 attenuate. Default `[1.8, 1.4, 1.0, 0.6, 0.4, 0.3]`
  amplifies fine detail while leaving low-frequency structure
  alone.
- **Noise threshold** (0–0.05) — Donoho-style soft-shrinkage
  applied per band BEFORE the boost. Zeroes out small (= noise)
  coefficients, leaves edge coefficients alone — denoise without
  losing sharpness because thresholding happens inside the same
  decomposition. 0.005–0.015 is the sweet spot on planetary OSC;
  >0.02 starts visibly smoothing fine cloud detail. 0 = off.

## Noise Reduction

Independent toggle, NOT part of either picker — pairs with
whichever sharpening method (or none) you chose.

Edge-preserving bilateral filter, runs after all sharpening but
before the tone curve. Smooths the noise floor without crossing
edges.

**Sliders:**
- **Spatial σ** (0.3–4 px) — Gaussian-domain filter size.
- **Edge tolerance** (0.005–0.30) — luminance-domain σ. Keep
  low (0.02–0.08) for hard band/limb preservation.
- **Window radius** (1–6 px) — bilateral kernel half-size.

## Live preview

Every slider triggers a throttled re-process (~33 ms cap). The
preview always shows the result of the *full* pipeline applied
to the active frame, so you can dial in by eye.

The **B** key toggles Before / After in the preview — handy to
verify you haven't gone too far.

## Apply Sharpening button

In the Sharpening section. Two contexts:

- **Memory tab** — applies the current sharpen settings to every
  memory frame in-place. Preview frames update live, op trail
  appends "sharp".
- **Inputs tab** — runs the file batch with sharpening only
  (stabilize / tone disabled), writes `<name>_sharp.tif` to
  OUTPUTS.

## What about pipeline order across the STEPs?

The order matters and is enforced by the engine:

```
STEP 1: SHARPEN  →  STEP 2: TONE CURVE & COLOUR
   (deconv → boost → NR)   (auto WB + ACDC → curve + B/C / sat)
```

(Colour & Levels was a separate STEP 2 until 2026-05-03; merged into Tone Curve since it had nothing else.)

- Auto WB / ACDC must run before sharpening to avoid coloured
  halos (Bayer green is naturally amplified — the sharpener would
  push that imbalance into halos).
- Tone curve runs *last* because curves are non-linear: applying
  them earlier shifts the data that the sharpener sees in
  unpredictable ways and breaks the deconv linear-model
  assumption.
- The labels in the SettingsPanel match this order top to bottom.

## Implementation notes

- Wavelet decomp lives in `Engine/Pipeline/Wavelet.swift` — pure
  Metal compute.
- Wiener uses Accelerate's vDSP for FFT, processed per channel
  separately (or single-channel luma when `processLuminanceOnly`
  is on, default true).
- Lucy-Richardson uses MPS for the Gaussian, our own divide /
  multiply kernels for the iteration step.
- All operations run in `rgba16Float` to preserve precision
  through iterations.
- Pre-gamma (`captureGamma`) is applied just before the deconv
  forward FFT and inverted just after the inverse FFT —
  pre-stretches the input back to linear so the model holds.

## See also

- [Tone Curve](Tone-Curve.md) — runs after sharpening
- [Lucky Stack](Lucky-Stack.md) — `--smart-auto` already bakes
  in deconv (AutoPSF + Wiener + RFF), so post-stack deconv is
  often unnecessary on smart-auto outputs
