# Smart workflow guide

Three end-to-end paths for the most common targets. Each one is one-pass — open the folder, follow the steps, walk away with a final image.

## Solar disc — full disc, granulation, prominences

**What you have:** a folder of SER captures of the Sun. Maybe one SER per filter (Hα, white light), maybe several pointings.

**Goal:** a clean, sharp final image without ghosting, drifting, or stacking artefacts.

```
1.  Open folder (⌘O)               — drag the SER folder onto the window
2.  Mark all .ser files (⌘A then space)
3.  Press R on the sharpest preview frame   ← anchor for stabilization
4.  Pick preset:
        – Sun · Granulation        for white-light surface
        – Sun · Prominences        for Hα limb features
5.  In Stabilize section:
        – Reference   : Marked
        – Alignment   : Disc Centroid    (locks onto the limb)
        – Boundary    : Crop
6.  Apply ALL Stuff (⇧⌘A)
        → AstroSharper runs Lucky Stack on the SERs.
        → Bake-in is ON, so each stack lands in OUTPUTS already
          sharpened + tone-curved.
7.  Switch to OUTPUTS, scrub through the saved files.
```

### When to pick which alignment mode for the Sun

| Subject | Alignment mode | Why |
| --- | --- | --- |
| Full disc, white light | **Disc Centroid** | The limb is the strongest signal; centroid is rock-stable across thin clouds. |
| Granulation close-up | **Full Frame** | Surface detail is everywhere, phase-correlation has lots of signal. |
| Hα prominences only | **Reference ROI** | Pin the rect over a specific prominence — surface granulation no longer pulls alignment around. |
| Sunspot tracking | **Reference ROI** | Drop the ROI on the spot; rotation drift over the session shows up as a cleanly trackable shift. |

## Lunar — terminator and craters

```
1.  Open folder, mark .ser files
2.  R on a frame where seeing froze nicely
3.  Preset: Moon · Detail
4.  Stabilize:
        – Alignment : Disc Centroid  (full Moon)
                      Reference ROI  (close-up of a crater field)
5.  Apply ALL Stuff
6.  In Memory tab, optionally tweak the Tone-Curve to lift terminator
   shadows — re-Apply (memory ops stay in RAM).
7.  Save All when happy.
```

## Planetary — Jupiter / Saturn / Mars

```
1.  Open folder of planetary SERs (typically multiple sub-minute clips)
2.  Mark all
3.  Pick the Jupiter / Saturn / Mars preset
        – multi-AP grid is preset-tuned (8×8 for Jupiter belts,
          12×12 for Mars surface, etc.)
4.  R on the cleanest frame
5.  Stabilize:
        – Alignment : Reference ROI on the planet's disc
        – Boundary  : Crop
6.  Apply ALL Stuff
7.  For each variant (e.g. f200 / f500 best-N stacks), AstroSharper
   writes its own subfolder: _luckystack/f200/, _luckystack/f500/, …
8.  Compare them in OUTPUTS, keep the one with the best detail/noise
   trade-off.
```

## Memory-tab power moves

The Memory tab is where AstroSharper diverges from AutoStakkert! / Registax. Operations stay in RAM until you commit.

```
After running Stabilize from Inputs:
   → switches to Memory automatically
   → playback.frames now hold aligned textures
   → press space-bar to play, ◀ ▶ to step
   → adjust Sharpening / Tone Curve sliders LIVE
       (preview updates per-frame, no re-export)
   → blink-compare with B (Before / After toggle)
   → mark the best frames, hit "Apply Sharpening" hero button
       (stays in memory, ops accumulate in appliedOps)
   → finally Save All — files land in OUTPUTS, named by their
     accumulated op trail (sun001_aligned_sharp.tif, etc.)
```

You can stabilize again from the Memory tab — AstroSharper reuses the current memory textures (no re-load from disk), so prior sharpening is preserved. A pre-flight confirm asks before re-aligning over edited frames.

## Sharpening pipeline order (STEP 1 → 2 → 3)

Three labelled STEPs in the Settings panel, applied in that visual top-to-bottom order:

```
STEP 1: SHARPEN
   ┌─ Deconvolution ─┐    ┌─ Boost ─┐
   │ Off / Wiener    │ +  │ Off /   │ + (orthogonal)  Noise Reduction
   │  / Lucy-R.      │    │ Unsharp │
   │  + Pre-gamma    │    │  / Wavelet │
   └─────────────────┘    └─────────┘

STEP 2: COLOUR & LEVELS
   ┌─ Auto White Balance (gray-world)
   └─ Atmospheric Chromatic Dispersion Correction

STEP 3: TONE CURVE
   ┌─ Histogram editor + B-spline curve
   ├─ Brightness / Contrast / Saturation
   └─ Highlights / Shadows
```

Two key rules the dual-picker enforces:

1. **One method per family.** Deconvolution (Wiener / LR) and Boost (Unsharp / Wavelet) are independent picks — you can stack one of each (classic pro pipeline) but not two of the same kind (Wiener+LR or Unsharp+Wavelet both compound artifacts).
2. **Engine reorders correctly.** Auto WB + ACDC actually run *before* sharpening internally (otherwise channel imbalance becomes coloured halos) — the step labels are written in workflow order, not pipeline order.

Recommended starting points:

- **Smart-auto stack output** (Wiener already baked in by Lucky Stack): Deconv = Off, Boost = Wavelet, NR low.
- **Bare-stack output** (`--no-stretch` or `disableOutputRemap = true`): Deconv = Wiener with Pre-gamma 1.0, Boost = Wavelet.
- **Solar Hα prominences**: Deconv = Wiener (σ ≈ 1.5, SNR 100), Boost = Wavelet with the inner bands lifted, NR off.
- **Photon-noisy planetary** (Saturn, Mars at low altitude): Deconv = Lucy-Richardson (15 iter), Boost = Wavelet, NR on.

Full reference: [`docs/wiki/Sharpening.md`](wiki/Sharpening.md).

## Reference frame: how to pick well

The single most impactful tweak. The reference is what every other frame is shifted to match — pick a poor reference and the whole session is jittery.

Good signs of a strong reference:
- **Sharp limb / horizon** for solar / lunar
- **Visible high-contrast feature** in the rect you want pinned (sunspot, crater pair, polar cap)
- **No motion blur** — short exposure, no wind, no shake
- **Centred subject** — if you'll use Crop boundary, off-centre frames cost overlap area

If you can't decide: switch the Stabilize Reference picker to **Best-Quality Frame** and let AstroSharper score every frame's Laplacian variance and pick the sharpest itself.

## Shortcut cheat sheet

| Shortcut | Action |
| --- | --- |
| `⌘O` | Open folder |
| `⇧⌘A` | Apply ALL Stuff |
| `⌘R` | Apply to Selection |
| `R` | Toggle Reference marker on highlighted row |
| `Space` | Toggle Mark on highlighted row(s) |
| `⌫` | Remove from list |
| `B` | Before / After toggle |
| `⌘=` `⌘-` | Zoom in / out 25 % |
| `⌘0` | Fit |
| `⌘1` `⌘2` | 1:1 / 200 % |
| `◀` `▶` | Step through memory frames |
| `P` | Play / pause |

Full list: [Keyboard Shortcuts wiki](wiki/Keyboard-Shortcuts.md).

## Output naming convention

```
   <input_basename>_<ops>.<ext>
```

Where `<ops>` is the accumulated op trail of that frame:

- `sun001_aligned.tif` — stabilized, no other ops
- `sun001_aligned_sharp.tif` — stabilized + sharpened in memory
- `jupiter_lucky.tif` — lucky-stack output (single file per SER)
- `jupiter_lucky_f500.tif` — lucky-stack variant in `_luckystack/f500/`

Subfolder picks: when every memory frame has the same op trail (e.g. all aligned + sharpened), AstroSharper writes them into one named folder (`stabilized_sharp/`). Mixed trails go into a generic `processed/`.

## When something looks wrong

- **Frames jittery after stabilize** → switch alignment mode to Disc Centroid (Sun / Moon) or define an ROI on a hard feature.
- **Stack looks soft** → bake-in is OFF; turn it on in the Lucky Stack section.
- **Output folder unwritable** → AstroSharper falls back to the sandbox Documents folder silently. The status bar shows where it landed.
- **Memory full** → reduce Variant counts in Lucky Stack, or close other apps. AstroSharper releases textures aggressively when sections switch.
