# Sharpening

Three different sharpening methods, each with different strengths. Mix and match — they compose in a fixed order.

```
   Lucy-Richardson  →  Wiener  →  À-trous Wavelet  →  Unsharp Mask
   (deconvolution)     (deconv)    (multi-scale)       (final pop)
```

## À-trous Wavelet (default ON)

Multi-scale starlet decomposition. Splits the image into N detail layers (high-frequency to low-frequency) and lets you boost each layer independently. The classical method for astrophoto sharpening — used by PixInsight, RegiStax, ImPPG.

**When it shines:** lunar craters, planetary surface texture, solar granulation. Anywhere you have detail at multiple spatial scales.

**Sliders:**
- Layers (3–6) — number of detail levels
- Strength per layer (0…3) — typically 0.5–1.5 on the finer layers

## Unsharp Mask

Classic Gaussian-difference sharpening. `out = orig + amount * (orig - blurred)`. Adaptive variant modulates `amount` per pixel by local luminance — boosts the brights, leaves the darks alone.

**When it shines:** quick "lift" passes; final polish after wavelet.

**Sliders:**
- Radius — Gaussian sigma in pixels (1.0–4.0 typical)
- Amount — multiplier on the difference (0.5–2.0 typical)
- Adaptive — reduces sharpening in low-luminance regions to keep noise down

## Wiener Deconvolution

FFT-based deconvolution against a Gaussian PSF. Effectively asks "what blurry input would produce my image?" and inverts the blur — minus a regularisation term that controls noise.

**When it shines:** when you know your seeing PSF was approximately Gaussian and want to recover detail without amplifying noise. Solar Hα, planetary work in moderate seeing.

**Sliders:**
- Sigma — assumed PSF size (px). 1.5–2.5 typical for planetary.
- SNR — signal-to-noise estimate. Lower = more conservative; higher = sharper but noisier.

## Lucy-Richardson Deconvolution

Iterative blind-ish deconvolution. Each iteration:
1. Convolve current estimate with PSF
2. Divide observed by that
3. Convolve the ratio with the flipped PSF
4. Multiply current estimate by that

Converges towards the maximum-likelihood solution.

**When it shines:** when Wiener is too aggressive and à-trous can't reach the detail you want. 30–50 iterations typical.

**Sliders:**
- Iterations (10–80)
- Sigma (Gaussian PSF size)

**Cost:** runs 2× Gaussian-blur (MPSImageGaussianBlur) + Divide + Multiply per iteration. 30 iterations on 4K ≈ 200 ms on M2.

## Live preview

Every slider triggers a throttled re-process (~33 ms cap). The preview always shows the result of the *full* pipeline applied to the active frame, so you can dial in by eye.

The **B** key toggles Before / After in the preview — handy to verify you haven't gone too far.

## Apply Sharpening hero button

In the Sharpening section. Two contexts:

- **Memory tab** — applies the current sharpen settings to every memory frame in-place. Preview frames update live, op trail appends "sharp".
- **Inputs tab** — runs the file batch with sharpening only (stabilize/tone disabled), writes `<name>_sharp.tif` to OUTPUTS.

## Implementation notes

- Wavelet decomp lives in `Engine/Pipeline/Wavelet.swift` — pure Metal compute.
- Wiener uses Accelerate's vDSP for FFT, processed per channel separately.
- Lucy-Richardson uses MPS for the Gaussian, our own Divide/Multiply kernels for the iteration step.
- All operations run in `rgba16Float` to preserve precision through iterations.

## See also

- [Tone Curve](Tone-Curve.md) — runs after sharpening
- [Lucky Stack](Lucky-Stack.md) — bake-in includes the sharpening pass
