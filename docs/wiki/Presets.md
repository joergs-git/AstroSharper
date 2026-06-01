# Presets — what each one does and *why*

A preset is a bundle of settings (lucky-stack mode, keep-%, multi-AP grid, sharpening, tone) tagged with a target. The built-ins aren't arbitrary — every value is chosen from the physics of the subject and from established lucky-imaging practice. This page documents the **actual values in the code** (`Engine/Presets/Preset.swift`) and the reasoning behind them, including what *not* to do even though the app would let you.

> Values below are pulled straight from `BuiltInPresets`. If a future code change drifts from this table, the code is the source of truth — fix the doc.

---

## The two lucky-stack modes

Only two modes exist (`LuckyStackMode`):

| Mode | What it does | When |
| --- | --- | --- |
| **Lightspeed** | AutoStakkert-equivalent: Laplacian quality grading, single-AP global alignment, weighted mean. Fast. | Whole-disc subjects with little local distortion (full-disc Sun / Moon), quick "is this SER worth keeping?" passes. |
| **Scientific** | Builds a reference from the top frames, re-aligns all kept frames to it, LoG quality grading, optional post-stack Wiener deconvolution. Slower, higher fidelity. | High-resolution surface / planetary work where local seeing matters. |

There is no "Balanced" mode (older docs claimed one — that was never in the code).

---

## The 10 built-in presets (code-exact)

| Preset | Mode | Keep % | Multi-AP | Sharpen chain |
| --- | --- | --- | --- | --- |
| **Sun — Granulation** | Scientific | 20 | **off** + sigma-clip | Unsharp r1.2 a0.6 adaptive · Wavelet [2.4, 1.6, 0.8, 0.4] |
| **Sun — Full Disk** | Lightspeed | 50 | off | Unsharp r2.0 a1.0 · Wavelet [1.4, 1.6, 1.4, 0.8] · mild tone S-curve |
| **Sun — Hα Prominence** | Scientific | 40 | **off** + sigma-clip | Unsharp r2.5 a0.8 adaptive · *no wavelet* · strong tone stretch |
| **Moon — High Detail** | Scientific | 25 | 10×10, patch 24 | Unsharp r1.5 a1.4 · Wavelet [2.0, 1.8, 1.0, 0.5] |
| **Moon — Wide Field** | Lightspeed | 50 | 8×8, patch 32 | Unsharp r2.5 a1.0 · Wavelet [1.2, 1.4, 1.2, 0.8] |
| **Jupiter — Standard** | Scientific | 25 | 10×10, patch 24 | Unsharp r1.4 a1.0 · Wiener σ1.5 SNR 60 · Wavelet [1.6, 1.5, 1.0, 0.6] |
| **Jupiter — Belt Detail** | Scientific | 20 | 10×10, patch 16 | Unsharp r1.0 a0.9 adaptive · Lucy-Richardson 35 iter σ1.2 · Wavelet [2.5, 1.8, 1.0, 0.4] |
| **Saturn — Standard** | Scientific | 25 | 10×10, patch 24 | Unsharp r1.6 a0.9 · Wiener σ1.6 SNR 80 · Wavelet [1.4, 1.5, 1.2, 0.7] |
| **Saturn — Ring Emphasis** | Scientific | 30 | 12×12, patch 24 | Unsharp r1.2 a0.9 adaptive · Wavelet [1.8, 1.8, 1.0, 0.4] |
| **Mars — Standard** | Scientific | 35 | 6×6, patch 16 | Unsharp r1.0 a0.8 · Lucy-Richardson 20 iter σ1.3 · Wavelet [1.4, 1.3, 0.8, 0.3] |

(Wavelet arrays are the per-scale boost for detail bands ~1, 2, 4, 8 px. Higher first entry = more fine-detail emphasis.)

---

## Why the settings are what they are

### Keep-% — how many frames survive grading

Lucky imaging works because atmospheric turbulence occasionally freezes into a near-diffraction-limited moment; you keep those and discard the blurred majority. The probability of a "lucky" frame falls steeply as the aperture grows relative to the Fried coherence length r₀ (Fried 1978; Law, Mackay & Baldwin 2006). The keep-% trades **sharpness vs SNR**: stack fewer frames → each is sharper but noisier; stack more → smoother but softer.

- **Planetary (20–35 %)** — small, bright, high-contrast discs. The lucky-frame statistics reward an aggressive cut; Belt Detail goes lowest (20 %) because belt structure is the highest-frequency target.
- **Solar — depends on the target.** Two regimes, not one rule:
  - **Surface detail** (white-light granulation, sunspot fine structure) is a *sharpness*-limited lucky-imaging target → **low keep (10–20 %)** wins. A headless 10-stack benchmark on a partial-disc white-light SER (2026-05-22) confirmed keep-10 was sharpest; high keep softened the granulation. Sun — Granulation is therefore keep 20 %.
  - **Faint / extended features** (Hα prominences off-limb) are *SNR*-limited → **high keep (30–50 %)**; cutting hard buries the faint plasma in noise. Sun — Hα stays at keep 40 %; Full Disk at 50 %.
  This split corrects the earlier "solar wants high keep" blanket guidance.
- **Lunar (25–50 %)** — High Detail 25 % (terminator micro-contrast is high-frequency), Wide Field 50 % (whole disc, prioritise SNR + even illumination).
- **Mars (35 %)** — small *and* noisy at typical amateur SNR, so it keeps more frames than Jupiter to hold the noise floor down.

The engine's `--auto-keep` clamps automatically to a [20 %, 75 %] band — see [Lucky Stack](Lucky-Stack.md).

### Mode — Lightspeed vs Scientific

Scientific (reference-stack + multi-AP) is used wherever **local seeing distortion** varies across the frame — granulation, lunar terminator, planetary discs. Lightspeed (single global align) is used for **whole-disc, low-local-distortion** subjects (Full Disk Sun, Wide-Field Moon) where the extra passes buy little and speed wins.

### Multi-AP grid — local alignment points

Seeing distorts different parts of a wide frame differently; a single global shift can't correct that. Splitting into a grid and solving a local shift per cell does — this is the core idea behind AutoStakkert!'s alignment points. Denser grids for **extended low-contrast fields** (Sun Granulation 12×12); a Mars-class tiny disc uses a *coarser* 6×6 because a fine grid would land cells on noise. Patch size scales with feature size: prominences / full-disc use large patches (32) for stable correlation on soft gradients; belt / Mars detail uses small patches (16) to track fine structure.

### Sharpening — Wiener vs Lucy-Richardson vs Wavelet

- **Wiener deconvolution** (linear, MSE-optimal for a known PSF; Wiener 1949) — used on **Jupiter / Saturn**, where the disc-on-dark-sky limb gives a clean PSF estimate and edges (GRS rim, Cassini division) benefit from a sharp linear inverse. SNR set conservatively (60 Jupiter, 80 Saturn — Saturn's body is lower contrast, so higher regularisation avoids boosting disc noise).
- **Lucy-Richardson** (iterative, non-negative; Richardson 1972, Lucy 1974) — used on **Mars** (20 iter) and **Jupiter Belt Detail** (35 iter): better behaved on photon-noise-dominated, small, faint targets where Wiener ringing would be objectionable.
- **Wavelets** (multi-scale à-trous boost, the RegiStax / AstroSurface paradigm) — the **solar / lunar** workhorse. Extended low-contrast surface detail responds to per-scale frequency boosting far better than to PSF deconvolution (which assumes a point/disc PSF that solar surface doesn't have). That's why Sun-Granulation leans hardest on the finest wavelet band (2.4).

---

## Granulation vs Full Disk vs Hα — the three Sun presets

These three look similar on paper but target different physics:

| | **Granulation** | **Full Disk** | **Hα Prominence** |
| --- | --- | --- | --- |
| Subject | White-light surface micro-detail | Whole solar disc | Off-limb Hα prominences |
| Mode | Scientific | Lightspeed | Scientific |
| Keep | 20 % | 50 % | 40 % |
| Multi-AP | off + sigma-clip | off | off + sigma-clip |
| Sharpen | Fine wavelets [2.4…] | Balanced wavelets + S-curve | Soft unsharp, **no wavelet**, strong stretch |
| Why | Granulation is sharpness-limited → low keep keeps only the lucky frames; multi-AP OFF because per-cell SAD smears low-contrast surface + warps the limb (benchmark 2026-05-22); sigma-clip rejects the worst seeing; fine wavelets pull out cell structure post-stack | Whole disc has little *local* distortion → single-align Lightspeed; the mild S-curve lifts mid-tones; more frames kept for even SNR across the disc | Faint off-limb plasma is SNR-limited → higher keep; multi-AP off (even lower contrast than granulation); strong stretch reveals the plasma, soft unsharp adds just enough edge, wavelets off so they don't amplify sky noise |

In short: **Granulation = resolve fine surface texture**, **Full Disk = clean pleasing whole-disc**, **Hα = reveal faint off-limb structure without amplifying noise**.

---

## What makes sense — and what doesn't, even though you *can*

The app exposes every knob; not every combination is wise. The ones worth knowing:

### Solar

| Do | Don't | Why |
| --- | --- | --- |
| **Multi-AP OFF** on surface detail (the retuned Sun presets do this) | **Dense multi-AP on low-contrast surface** | Per-cell SAD smears low-contrast granulation (noise-dominated) and warps the smooth limb (aperture problem — the SAD is a *valley* along a straight edge). A 10-stack benchmark (2026-05-22) found dense multi-AP the WORST across all grid sizes; lightspeed/global align won. An aperture-rejection gate now drops ambiguous cells to global, but for solar surface it's cleaner to leave multi-AP off entirely |
| Surface: low keep (10–20 %). Prominences: high keep (30–50 %) | **One keep-% for all solar** | Surface granulation is sharpness-limited (lucky imaging → low keep); faint off-limb Hα is SNR-limited (→ high keep). See the keep-% section above |
| Wavelet sharpening | **Aggressive Wiener / AutoPSF on the surface** | AutoPSF measures a PSF from a disc-on-dark-sky *limb*. A granulation / sunspot / Hα-surface close-up has no clean limb → AutoPSF bails (by design — a wrong σ is worse than none), so the deconv you expect simply doesn't happen. Use the Sun presets' wavelets instead |
| No drizzle (solar is usually well/over-sampled) | **Drizzle a well-sampled solar capture** | Drizzle reconstructs *undersampled* data (Fruchter & Hook 2002). On already-Nyquist-sampled solar it adds no resolution, only interpolation softening + grid artefacts |
| No derotation | **Derotation on the Sun** | Solar rotation is ~27 days — negligible over a capture. Derotation is a Jupiter / Saturn tool (≈10 h rotation) |

> **AutoNuke + Sun:** AutoNuke forces AutoAP + AutoPSF-Wiener + auto-keep. On full-disc Sun the limb may let AutoPSF lock on; on **surface close-ups AutoPSF bails and AutoNuke leaves no fallback**, so it reduces to AutoAP + auto-keep with *no* sharpening. For solar, the built-in Sun presets (wavelet-tuned) are the better starting point than AutoNuke.

### Planetary

| Do | Don't | Why |
| --- | --- | --- |
| Low keep-% (20–25 %), Wiener / LR + RFF | **Push keep-% high "to be safe"** | Defeats the lucky-imaging premise; you average the bad seeing back in |
| Drizzle 1.5×–2× *only if undersampled* | **Drizzle when already at/above Nyquist** | No new resolution, just bigger softer files (Fruchter & Hook 2002). Sample first: f-ratio ≈ 5× pixel-pitch-in-µm puts you near Nyquist for the diffraction limit |
| Derotation for >3 min Jupiter / Saturn sessions | **Derotation on Mars / Moon / Sun** | Only the fast-rotating gas giants smear meaningfully within a multi-minute capture |
| Lucy-Richardson on faint / noisy Mars | **High-SNR Wiener on a noisy small disc** | Wiener ringing is ugly on low-SNR small targets; LR's non-negativity behaves better |

### General

| Do | Don't | Why |
| --- | --- | --- |
| One deconvolution method (Wiener **or** LR) + one boost (Unsharp **or** Wavelet) | **Stack two of the same family** (Wiener+LR, Unsharp+Wavelet) | Same-category methods compound the same artefacts. The dual-picker enforces this |
| 32-bit float accumulation (automatic) | — | Half-precision banding shows up after sharpening; the engine always accumulates in 32-bit float |

---

## Smart auto-detection

When you open a folder, AstroSharper scans filenames + parent-folder names for target keywords and pre-applies the matching built-in:

| Keyword match | Auto-applied target |
| --- | --- |
| `sun`, `sol(ar)`, `halpha`, `h-alpha`, `ha_`, `lunt` | Sun |
| `moon`, `mond`, `lunar`, `luna` | Moon |
| `jup`, `jupiter` | Jupiter |
| `sat`, `saturn` | Saturn |
| `mars` | Mars |

Case-insensitive. **Auto-apply preserves your section toggles** (Sharpen / Tone on-or-off) so a file change never silently flips a section. **Explicitly picking** a target chip or a preset from the menu *does* honour the preset's saved enable flags — so clicking "Sun" turns on the sections that preset needs. You can disable filename auto-detect in the preset dropdown.

---

## User presets + iCloud

**Save as New Preset…** captures all current settings into a Codable `Preset` (name + target tag + optional notes) stored in `NSUbiquitousKeyValueStore`, so your presets roam across Macs on the same Apple ID (local `UserDefaults` is the offline fallback). **Update Current** re-snapshots the active *user* preset (built-ins are read-only).

---

## Scientific & best-practice basis (for the skeptics)

The peer-reviewed foundations behind the choices above:

- **Lucky imaging / short-exposure statistics** — Fried, D. L. 1978, *"Probability of getting a lucky short-exposure image through turbulence"*, JOSA 68, 1651. Law, N. M., Mackay, C. D. & Baldwin, J. E. 2006, *"Lucky imaging: high angular resolution imaging in the visible from the ground"*, A&A 446, 739.
- **Atmospheric seeing / Fried parameter r₀** — Roddier, F. 1981, *"The Effects of Atmospheric Turbulence in Optical Astronomy"*, Progress in Optics 19, 281.
- **Drizzle is for undersampled data** — Fruchter, A. S. & Hook, R. N. 2002, *"Drizzle: A Method for the Linear Reconstruction of Undersampled Images"*, PASP 114, 144.
- **Lucy-Richardson deconvolution** — Richardson, W. H. 1972, *"Bayesian-Based Iterative Method of Image Restoration"*, JOSA 62, 55; Lucy, L. B. 1974, *"An iterative technique for the rectification of observed distributions"*, AJ 79, 745.
- **Wiener / linear MSE restoration** — Wiener, N. 1949, *Extrapolation, Interpolation, and Smoothing of Stationary Time Series*; standard treatment in Gonzalez & Woods, *Digital Image Processing*.
- **Sampling** — Nyquist–Shannon sampling theorem (Shannon 1949); the amateur planetary "f-ratio ≈ 5× pixel-pitch-µm" rule is the practical Nyquist-at-the-diffraction-limit guideline.

Items flagged in the text as "community practice / consensus" (e.g. exact solar keep-% bands, the f/5×pixel rule of thumb) are established amateur best practice — codified in tools like **AutoStakkert!** (E. Kraaikamp) and **RegiStax** (C. Berrevoets) and the broader solar / planetary imaging community — rather than a single citable paper. They're marked as such so you know which claims are peer-reviewed and which are practitioner consensus.

---

## Implementation

- `Engine/Presets/Preset.swift` — `Preset` struct, `PresetTarget` enum, `BuiltInPresets.all()`, auto-detect keyword table.
- `Engine/Presets/PresetManager.swift` — `ObservableObject` singleton, built-in + user lists, iCloud KVS sync.
- `App/Views/PresetMenu.swift` + `App/Views/BrandHeader.swift` — the dropdown + target chips (explicit picks pass `userInitiated: true`).

## See also

- [Lucky Stack](Lucky-Stack.md) — modes, quality grading, multi-AP, variants
- [Sharpening](Sharpening.md) — the bake-in / post-stack sharpen pipeline
- [Workflow](../WORKFLOW.md) — end-to-end recipes per target
