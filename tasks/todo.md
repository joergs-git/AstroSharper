# AstroSharper — Project Memory

A running record of where we are, what's done, and what's next. Update at the end of every session.

## Suggested next-session focus

End-of-2026-05-03 (latest): **C.2 + C.4 + A.5 (v0+v1) + sRGB tone + Hα fix + LRU prefetch + AVI smoke + Step1/2 reset + Compare side panel all shipped on `feature/v1-foundation`.** AutoPSF cascades to `AutoPSFAutoROI` for lunar / textured (default OFF, validated end-to-end on 13 GB lunar SER — gentle Wiener, no ringing, conservative gate doing its job). Scope-formula tile size live (`--auto-tile-size --focal-length-mm N --pixel-pitch-um N [--barlow N]`). HUD now shows median HFR + Drift sparkline after Stabilize. Tone-op block runs in perceptual sRGB (gamma-encode → ops → gamma-decode wrap). AP-cell quilting on solar Hα fixed (rank sigmoid 10 % → 20 %). SER LRU + 4-frame prefetch via `SerFramePrefetcher`. Compare side panel (toolbar `B`) shows current file + source SER thumbnails at default 2× zoom with linked pinch + drag. Step 1 + Step 2 reset buttons. AVI pipeline confirmed working on AVFoundation-supported video; SharpCap raw AVI documented as the open codec gap. **All 301 unit tests + 6/6 F3 baselines still byte-identical (default-off flags ensure no behaviour drift).**

**Top of stack for next session:**

1. **Native AVI rawvideo decoder** — SharpCap's typical mono capture (`codec=rawvideo` + `pal8` + zero FourCC) is invisible to AVFoundation; the AviReader returns "noVideoTrack" with a now-clear error pointing to the ffmpeg one-liner workaround. Real fix is a small native parser that reads the AVI container manually + decodes the rawvideo stream. ~500–800 lines, multi-day. Most-requested gap once non-power users run into it.

2. **C.2 cascade tightening** — lunar bracket showed conf=3.15 (gate=3) on the terminator → marginal Wiener nudge with no visible improvement. v1 should tighten the gate (5 instead of 3, or stricter dirStd ≤ 8°) to either deliver a clear sharpness win or bail. Needs more sample lunar captures to bracket.

3. **G.1 + G.2 derotation** — Jupiter / Saturn warp each kept frame back to a reference rotation epoch using SER timestamps + ellipsoid projection. Auto-engage when capture window > 3 min. ~600 lines new `Engine/Pipeline/Derotation.swift` + LuckyRunner integration. 1–2 days, plus needs a long capture in TESTIMAGES to validate.

4. **F3 v1.4 polish**: drop more reference images into TESTIMAGES so RMSE fires on more baselines (only 4/7 today); add unit tests for the PSS cascade and drizzle AA pre-filter; bracket-script convenience subcommand.

5. **B.6 polish** (auto-engage FWHM/2.4 trigger + float scales), **D.1 polish** (folder-scan master-frame builder), **A.2 two-stage quality**, **A.3 Strehl supplement** — small wins; none individually session-sized.

6. **Tone-op preset re-bracket** — slider semantics changed when the tone block moved into perceptual sRGB; existing iCloud presets carry over but their visual effect shifted. User may want a one-shot re-tune of the built-in presets (Sun / Moon / Jupiter / Saturn / Mars).

**Telemetry follow-ups (deferred until ~500 opt-out events accumulate):**
- **Stack-time leaderboard window.** Mirror AstroTriage's `BenchmarkLeaderboardWindow.swift` pattern against `stack_telemetry` (`elapsed_sec / frame_count` ranking).
- **Privacy summary page.** Splash screen + Help menu item linking to a one-page "What we collect" doc.
- **Disk-backed retry queue.** Currently fire-and-forget; only add if real telemetry shows lossy networks dominating.
- **AutoAP / AutoPSF feedback loop.** After ~500 events, re-fit the closed-form constants (patchHalf coefficient, RFF knee, multi-AP gate threshold) against population data.

**Done this session (post-v0.4.0 tag):**
- 0a: Coffee popup re-enabled (`coffeePromptEnabled = true`).
- 3: LuckyRunner refactor (E.1) — `SerReader` → `SourceReader` migration; AVI / MOV / MP4 / M4V accepted by CLI.
- arm64-only lock in `project.yml` so Release builds can't fail on `Float16` for x86_64.
- **C.2 v0 — AutoPSF auto-ROI cascade** (`AutoPSFAutoROI.swift`, ~330 lines + 10 unit tests). Sobel gradient → top-K candidates with non-max suppression → score by direction-stability + step-contrast → slanted-edge LSF (21 parallel lines, ±10 px perpendicular sweep) → second-moment integration → confidence gate. Pure-Swift core; new cascade enum `AutoPSFEstimate { .planetary | .autoROI }` decides whether RFF applies (planetary only — no disc geometry for auto-ROI). Default OFF in CLI (`--auto-psf-roi`) and GUI sub-toggle; AutoNuke does not engage it. Existing `disableRFF` behaviour preserved (bare Wiener output, no tiled-deconv).
- **C.4 — tile-size auto-calc** (BiggSky scope formula). `LuckyStackOptions` gained `autoTileSizeFromScope` + `scopeFocalLengthMM` + `scopePixelPitchUm` + `scopeBarlowMagnification`. New `LuckyRunner.applyScopeFormulaTileSize` runs after `applyAutoAP` so the scope formula wins over the subject-driven heuristic. CLI flags `--auto-tile-size`, `--focal-length-mm`, `--pixel-pitch-um`, `--barlow`; GUI inputs in the tiled-deconv block.
- **A.5 v0 — median HFR** added to `SharpnessDistribution` + populated by `SerQualityScanner` from the same luminance buffers the sharpness probe uses (one extra CPU pass per sample, ~3 ms each → negligible on the once-per-SER 64-sample budget). Surfaced in `PreviewStatsHUD` beneath the existing jitter row. XY-shift sparkline deferred (requires a Stabilizer.Result API extension to expose per-frame shifts).

## Current state (v0.4.0 — released 2026-05-03)

- Public GitHub repo: https://github.com/joergs-git/AstroSharper
- Latest release: **v0.4.0** — AutoNuke + AutoAP + telemetry + community feed + in-app update checker
- All Apple infra in place: Developer ID cert installed, `notarytool` keychain profile configured, auto-managed provisioning profile present
- In-app update checker live: every launch fetches `latest-release.json` from `main` and prompts users on a newer version. See `memory/project_release_workflow.md`.

## Current state (v0.2.0 + unreleased)

- Native macOS app, Swift 5.9 + Metal, macOS 14+
- Full lucky-imaging pipeline operational: SER (mono + Bayer) → quality grade → multi-AP align → weighted accumulate → bake-in (sharpen + tone) → 16-bit float TIFF
- Three-section UI (Inputs · Memory · Outputs) with stash-on-switch state
- Sandbox-safe with security-scoped bookmarks + container fallback
- Preset system with smart auto-detection + iCloud sync (10 built-ins)
- Brand identity, About / How-To windows, app icon, version display
- Apply ALL Stuff hero button (⇧⌘A)
- Cmd zoom shortcuts (⌘= ⌘- ⌘0 ⌘1 ⌘2)
- R-key reference frame marker
- Three alignment modes: full frame, disc centroid, reference ROI
- Stabilize-from-memory preserves in-place edits

## Done — recent batches

### 2026-05-01 — Display chain + re-validation + F3 regression harness
- **sRGB display chain fix**: tagged `CAMetalLayer.colorspace` as `sRGB` (was the `rgba16Float` default `extendedLinearSRGB`); removed the unconditional shader `pow(., 2.2)` encode. Saved TIFs in our app now render pixel-for-pixel identical to Preview.app / Photoshop. Per-file Auto default: SER/AVI ON, TIFF/PNG/JPEG OFF (commits `8302c8b` / `582e5d8` / `c8dffc9`).
- **Bake-gamma re-validation** (`/tmp/gamma-recheck/`): user re-bracketed `applyOutputRemap` defaults on the corrected display. Wide-bright (solar/lunar) γ=2.5 stays; dark-dominated (Jupiter/Saturn/Mars) γ=1.3 → γ=1.0 (bare accumulator). Prior 1.3 was eye-tune compensation for the under-encoded display chain. New `--bake-gamma <X>` CLI flag for future tone work (`734432e`).
- **Wiener SNR re-validation** (`/tmp/snr-recheck/`): smart-auto SNR=200 → 100 on Jupiter bracket. Same eye-tune compensation pattern as bake gamma — high SNR was recovering apparent detail that was actually being lost to the broken display gamma. RFF math unchanged (geometry-driven, robust to display gamma). README marketing copy retuned (`8c003aa`).
- **F3 regression harness shipped** (`f87cf6e`): `astrosharper validate <testimages-dir>` walks for `.ser`, runs `analyze` + `stack --smart-auto --keep 25` on each, diffs metrics against committed baselines under `Tests/Regression/baselines/`. ±2 % tolerance on `outputBytes`; volatile fields (timing, absolute paths) stripped. `--regenerate` rewrites baselines after intentional calibration; `--filter` narrows; `--quiet` for CI. 14 baselines (7 SERs × analyze + stack) regenerated on the calibrated build. Cleaned 8 orphan baselines from a prior file-rename. ~3 min wall-clock for the full run; 7/7 green at session end.
- Memory updated with: `feedback_display_industry_standard.md` (rewritten to match the actual final solution — sRGB-tagged layer + pass-through shader), `feedback_revalidate_after_display_fix.md` (meta-lesson: any visually eye-tuned default needs re-bracketing after a display chain change), `project_rff_and_snr_empirical.md` (SNR=100 supersedes SNR=200), `feedback_test_harness_mandatory.md` (regression harness now shipped, references the actual command).

### v0.3.0 — Preview HUD, quality intelligence, viewer polish (this session)
- Preview HUD overlay (filename / dims / bit-depth / Bayer / size / capture date / current frame / live sharpness)
- SER quality scanner with on-demand "Calculate Video Quality" button
- Disk-persistent quality cache (`Application Support/AstroSharper/quality-cache.json`)
- Sortable Type and Sharpness columns
- Live filename filter with Include / Exclude (eye / eye-slash) toggle
- In-SER play / pause + autostop on file switch
- Photoshop-style anchored click-drag zoom ported from AstroBlinkV2
- Flip icon hidden when off
- MTKView switched to setNeedsDisplay-driven (window-resize fix)
- Native macOS app icon wired through AppIcon asset catalog
- README expanded into 5 themed Highlights sections
- Public GitHub repo created
- v0.3.0 notarized release on GitHub

### Solar stabilization fix (current session)
- DC removal before Hann window — fixes solar disc drift
- Reference frame marker (R key, gold star)
- Three alignment modes (full frame / disc centroid / reference ROI)
- ROI capture from current preview viewport
- Stabilize-from-memory uses memory textures (preserves in-place edits)
- Pre-flight confirm before re-aligning over edited frames
- ReferenceMode picker: marked / firstSelected / brightestQuality
- Append "aligned" to appliedOps trail instead of resetting
- Click-anywhere section header collapse
- AVI catalog recognition + friendly fallback for lucky-stack

### D14 — UX polish
- Inline player, status-bar path, lighter accent, thumbnail normalising fix
- Lucky Stack section gating when no SER files present

### D13 — Memory workflow
- Mini-player, per-section apply hero buttons, smart suffix naming
- Sortable file-list columns, How-To floating window

### D12 — Brand + scaffolding
- Brand identity, About panel, How-To window, app icon, version display

## Pending — roadmap (v1.0 single-shot completion)

**Single-milestone v1.0 plan, locked 2026-04-27.** No interim shipping. Locked principles: Quality + Speed are the only filter; automate over expose; UI scaffolding stays. Full strategy: `~/.claude/plans/check-if-this-project-drifting-pnueli.md`. Reference data: `TESTIMAGES/biggsky/` (3 Jupiter SERs ~11 GB + 1 AS!3 reference PNG).

### Foundation (must land first — unblocks everything)
- [ ] **F1 Headless CLI target** (`AstroSharperCLI`) — `astrosharper stack file.ser --keep auto --metric lapd --align lapd-multilevel --sigma 2.5 --drizzle 1.5 --decon blind --out outdir/ --metrics-json out/metrics.json`. Subcommands: stack, align, decon, analyze, validate. New target in `project.yml`. **Required so every algorithm is verifiable without GUI.**
- [ ] **F2 Test target** (`AstroSharperTests`) — Swift Testing or XCTest. Cover every Engine/Pipeline algorithm with synthetic-input unit tests + GPU-vs-CPU-reference asserts. Tests for: phase corr (<0.1 px shift recovery), LAPD/VL ranking parity, sigma-clip outlier %, drizzle MTF, Welford accumulator, Bayer demosaic, blind deconv (PSF FWHM <10% off, image PSNR >30 dB).
- [x] **F3 Regression harness** — `astrosharper validate <dir>` (v1 `f87cf6e` 2026-05-01, v1.1 sharpness `292444c`, v1.2 FFT band fractions `d73ea85`). Walks `.ser` files, runs analyze + stack on each, diffs metrics against committed baselines. Per-key tolerance: ±2 % `outputBytes`, ±5 % quality bucket (`outputSharpness` + `outputFFTMidFraction` + `outputFFTHighFraction`). Volatile fields stripped (timing, absolute paths). `--regenerate` rewrites baselines after intentional calibration changes; `--filter` narrows; `--quiet` for CI. 14 baselines for 7 SERs, all green. Spatial sharpness + frequency-domain bands are complementary axes (sharpness conflates edges with noise; FFT separates medium structure from fine detail). **Open work for F3 v1.3**: per-pixel RMSE vs the AS!3 reference output `TESTIMAGES/biggsky/2026-03-05-0055_5-MPO_Jupiter__lapl6_ap126.png`. Adds visual-identity axis on top of the existing two quality axes.
- [~] **F4 SourceReader protocol** — Audited 2026-05-01, partially advanced same day. Protocol shape good (~64 lines). `SerReader` + `AviReader` + new `FitsFrameReader` (Fits.swift wrapper class, commit `cb97123`) all conform. `SourceReader.open(url:)` factory dispatches by extension. **Remaining gap is now narrower than the audit suggested**: the 3 `SerReader(url:)` sites in `LuckyStack.swift:649` / `QualityProbe.swift:296` / `OscDefaults.swift:31` all sit inside SER-only code paths *by design* (raw byte access, header-specific introspection). The actual remaining work to enable AVI / FITS lucky-stack is to refactor `LuckyRunner` to abstract over byte / RGB / Float32 frame inputs — that's a multi-day effort, not a quick swap. Promote to its own roadmap item if it becomes a v1 blocker.
- [ ] **F5 32-bit float TIFF output + render modes** — extend `Engine/Exporter.swift` for 32-bit float (deconv peaks routinely > 65535). Render modes (Clip / AutoRange / Manual Min Max) in display path; doesn't affect file content.

### Block A — Quality intelligence
- [x] **A.1 LAPD as primary metric** — `quality_partials` and `compute_lapd_field` shaders both use `laplacian_at` (Diagonal Laplacian, 8-neighbour, cardinal weight 1.0 + diagonal 0.5). Active across `LuckyStack` quality grading + `SharpnessProbe` HUD. Pure-Swift `LAPDProbeTests` suite verifies the math. Already shipped.
- [ ] **A.2 Two-stage quality** — global LAPD + per-AP local contrast in `LuckyStack.swift`. Each AP picks its own top-N% subset (PSS approach).
- [ ] **A.3 Strehl-ratio supplement** — for high-frame-count regime. 2D Moffat fit on brightest disc/feature.
- [x] **A.4 Lucky keep-% formula** — `QualityProbe.computeKeepRecommendation` clamps to BiggSky empirical [0.20, 0.75] band (was [0.05, 0.50]). Knee detection at p where score(p) ≤ 0.5 × p90; jitter tightening applied BEFORE clamp so it stays visible across the band; frame-count floors (50 absolute, 100 typical) preserved. Wired through `--auto-keep` CLI flag + `LuckyStack.run` resolves at quality-grade time. Tests updated to 0.20 floor / 0.75 cap. CLI output annotates `(auto-keep)` so the resolved value is explained alongside `plan.percent`. Tuning data: all real BiggSky reference SERs (Saturn / Jupiter ×3 / Mars / Moon) hit the 75% cap with our LAPD scoring; synthetic wide distributions correctly drop to 20% floor (verified via `LuckyKeepRecommendationTests`). Manual AP placement skipped after empirical regression test on Saturn (auto 6×6 grid achieves 1.13× LAPD sharpness vs 28 manual APs).
- [~] **A.5 Median HFR + XY-shift sparkline (v0 — HFR readout only)** — `HalfFluxRadius.compute` was already implemented + unit-tested; this session wired it. `SharpnessDistribution` gained `medianHFR`; `SerQualityScanner` reads luminance via `AutoPSF.readLuminance` and computes HFR per sample (~3 ms each on 1280×720, negligible on the 64-sample once-per-SER budget). HUD renders the median beneath the jitter row. **Open work for v1**: XY-shift sparkline — needs Stabilizer.Result API extension to expose per-frame shifts to AppModel.
- [x] **A.6 Multi-percentage stacking in one pass** — `LuckyStackVariants` (3× absoluteCounts + 3× percentages) in `Engine/Pipeline/LuckyStack.swift`; GUI provides the f1/f2/f3 + p1/p2/p3 input grid in `LuckyStackSection`; `AppModel` enqueues a separate `LuckyStackItem` per non-zero entry so each variant gets its own `f100/`, `p25/` subfolder. CLI accepts `--keep 20,40,60,80` (comma-separated → multi-stack queue). Each percentage shares the same quality-grade pass; only the kept-set selection differs per variant.

### Block B — Alignment & stacking
- [x] **B.1 Sigma-clipped stacking** — engine path was already implemented as `LuckyStack.accumulateAlignedSigmaClipped` (Welford pass + clipped re-mean). 2026-04-29 surfaced the `--sigma N` CLI flag to the GUI: toggle + threshold slider (default 2.5σ matching AS!4 / RegiStax, range 1.5–4.0) appears inside the Multi-AP block of LuckyStackSection because both are Scientific-mode features. Wired via `LuckyStackUIState.sigmaClipEnabled` + `sigmaClipThreshold` → `perItemOpts.sigmaThreshold`.
- [x] **B.2 Feathered AP blending** — `lucky_accumulate_per_ap_keep` now uses raised-cosine per-axis weights `0.5·(1±cos(π·d))` instead of bilinear `1-d / d`. Continuous derivatives at AP centres + neighbour centres eliminate the bilinear tent's grid quilting. Sum-to-1 invariant preserved via `cos(π·(1-d)) = -cos(π·d)`. CPU reference: `APFeather.cosineWeight`. 2 new APFeatherTests verifying partition-of-unity sum-to-1 across `[0,1]²`.
- [ ] **B.3 Adaptive AP placement / auto-rejection** — new `Engine/Pipeline/APPlanner.swift`. Per-cell local contrast + luminance; drop bottom 20%. Sparse-AP mask honored by accumulator.
- [x] **B.4 Cumulative drift tracking** — `DriftCache.validateChronologically` (pure-Swift, fully testable) replays per-frame phase-corr shifts in chronological order, replacing outliers (>10 px from linear-extrapolated prediction) with the prediction. `Stabilizer.run` invokes it after the alignment loop; outlier replacements logged via os_log. Reference frame anchored at `(0,0)` so predictions across it stay continuous. 4 new DriftCacheTests covering clean drift, single outlier, ref-in-middle, empty input.
- [x] **B.5 MultiLevelCorrelation** — Proper PSS cascade shipped 2026-05-01 (commit `f1f300f`). Coarse 256² runs first, peak gets mapped to fine-grid coords, fine FFT correlation runs but its peak-find is *constrained* to a search window (radius 8 fine-grid px) around the coarse-derived centre. Peaks outside the window are unreachable by construction — the noise-basin failure mode is structurally prevented, not just post-validated. `fft2dPhaseCorrelation` gains optional `searchCenter` + `searchRadius` (default args preserve global-scan behaviour for the LuckyStack hot path). SER regression suite 7/7 still green at unchanged baselines (constrained search picks the same peaks unconstrained did on clean inputs). **Future polish**: dedicated unit tests exercising the cascade vs the global-fallback path on synthetic peak-locking inputs.
- [x] **B.6 Drizzle 1.5×/2× with anti-aliasing pre-filter** — Closed 2026-05-01. Splatting feature-complete (CPU + GPU + 8 unit tests). GUI shipped (Off/2×/3× picker + pixfrac slider in the Scientific block, commit `9b99578`). AA pre-filter shipped via MPSImageGaussianBlur (default σ=0.7 input-pixels, matches pixfrac so the blur radius ≈ drop size; commit `a74acb2`). CLI `--drizzle-aa-sigma <X>` (0=off); GUI AA σ slider revealed when scale>1. **Future polish (not v1 blockers)**: auto-engagement trigger (FWHM/2.4 undersampling), float scale factors (1.5× — engine is integer-only today).

### Block C — Deconvolution paradigm (BiggSky parity)
- [~] **C.1 Blind deconvolution (v0 — limb-LSF auto-PSF + Wiener + RFF)** — `Engine/Pipeline/AutoPSF.swift` estimates Gaussian PSF sigma from the planetary limb's LSF + auto-bails on textured / cropped subjects. `LuckyStack.radialDeconvBlend` (RFF — Radial Fade Filter) reuses the auto-detected disc geometry to fade Wiener strength near the limb, eliminating Gibbs ringing. Smart-auto SNR=200 universal sweet spot empirically verified across Saturn/Jupiter/Mars (2026-04-29). RFF original to AstroSharper — README marketing copy added. **Open work for full C.1**: iterative joint refinement (re-estimate PSF after first-pass deconv), Moffat / anisotropic PSF, per-tile PSF for C.3.
- [x] **C.2 PSF from auto-ROI (v0 — slanted-edge LSF)** — `Engine/Pipeline/AutoPSFAutoROI.swift` (~330 lines + 10 unit tests). Sobel gradient → NMS-filtered candidates anchored on `pMax × 0.30` (percentile thresholds break for thin edges) → magnitude-weighted axial-direction circular-std + step contrast scoring → 21-line slanted-edge LSF (±10 px perpendicular sweep, ±8 second-moment integration covers the σ=5.0 upper clamp without truncation underestimation) → confidence gate. Cascades AFTER `AutoPSF.estimate` returns nil. `AutoPSFEstimate` enum gates the RFF path (planetary only — no disc geometry for auto-ROI); tiled-deconv (geometry-free) still applies when enabled. CLI `--auto-psf-roi`, GUI sub-toggle. Default OFF + AutoNuke does not engage it (bracketed per-subject before relying on). **Open work for v1+**: empirical lunar SER bracket, default-on for explicitly lunar-flagged smart-auto.
- [~] **C.3 Tiled deconvolution with green/yellow/red mask (v0 — global PSF)** — `LuckyStack.tiledDeconvBlend` reuses APPlanner. Cells dropped by APPlanner = RED (skip deconv). Surviving cells split at the median LAPD score: top half = GREEN (full deconv), bottom half = YELLOW (half-strength deconv). Mask uploaded as r32Float (apGrid × apGrid), GPU `lucky_mask_blend` shader bilinear-samples for smooth tile boundaries. v0 uses a SINGLE global PSF from AutoPSF; per-tile PSF estimation deferred to C.3 v1+. CLI `--tiled-deconv [--tiled-grid N]`, GUI toggle. Empirical 2026-04-28: visibly cleaner backgrounds on BiggSky Jupiter; full-kit output closes most of the visible gap to the reference. Mask Bkg override toggle for v1+.
- [x] **C.4 Tile-size auto-calc (BiggSky scope formula)** — `CaptureGeometry.tileSize` was already implemented + unit-tested; this session wired it. `LuckyStackOptions` gained `autoTileSizeFromScope` + scope params; new `LuckyRunner.applyScopeFormulaTileSize` runs after `applyAutoAP` so the scope formula wins over the subject-driven heuristic. CLI `--auto-tile-size --focal-length-mm N --pixel-pitch-um N [--barlow N]`; GUI inputs in the tiled-deconv block. End-to-end smoke: Saturn 512×320, focal=2000 mm, pixel=5 µm → tileSize=400 px → grid=4×4 (correctly overrides AutoAP's grid=7).
- [x] **C.5 Dual-stage denoise** — `LuckyStack.denoiseTexture` wraps `Wavelet.sharpen` with amounts=[1,1,...] (perfect reconstruction) + per-band soft-threshold scaled from 0..100 percent → 0..0.025 threshold (same upper end as the existing manual wavelet denoise). Pre-denoise fires before AutoPSF + Wiener (cleaner LSF, less noise amplification through the inverse filter); post-denoise fires after Wiener (suppress amplified noise + ringing). CLI `--denoise-pre N --denoise-post N`, GUI sliders revealed when Auto-PSF is on. Defaults 0 (off); BiggSky-typical 75/75.
- [x] **C.6 Capture gamma compensation** — `Wiener.deconvolve` now accepts a `captureGamma` parameter (default 1.0). When != 1.0, each channel is `pow(x, gamma)`-linearised before FFT and `pow(x, 1/gamma)`-re-encoded after IFFT, restoring the linear-forward-model assumption. Wired into all 3 `Pipeline.process` Wiener call sites (live preview path uses `sharpen.captureGamma`) and the LuckyStack AutoPSF post-pass (uses new `LuckyStackOptions.captureGamma`). CLI `--capture-gamma N` accepts an exponent (1, 1.5, 2, 2.2) or a camera slider value (>4.5 → SharpCap/ZWO 50..200 dialect). Existing 13 CaptureGammaTests cover the math.
- [x] **C.7 Process Luminance Only** — `Wiener.deconvolve.processLuminanceOnly`: when true, computes Y = 0.299·R + 0.587·G + 0.114·B, runs ONE Wiener pass on Y, adds Δ = Y' − Y to every channel. Halves FFT cost vs 3-channel default and avoids per-channel ringing on OSC bayer sources where R/G/B noise floors differ. Default ON across all paths (`SharpenSettings.processLuminanceOnly` was already true; `LuckyStackOptions.processLuminanceOnly` new field default true). CLI escape hatch `--per-channel-deconv`. Mono sources produce numerically identical output regardless of the flag.
- [x] **C.8 Border crop after deconv** — `LuckyStack.cropBorder` allocates a smaller private texture and blit-copies the interior region. Hides the FFT wrap-around / Wiener edge ring on the saved view file. Default 32 px (BiggSky `SaveView_BorderCrop`); pass-through when 0 or when crop would over-shoot. New `LuckyStackOptions.borderCropPixels` (default `BorderCrop.defaultViewBorderCropPixels`). CLI `--border-crop N` (0..256, 0 disables).
- [ ] **C.9 Saturn-style ROI workaround** — auto-expand ROI to bbox of bright connected components for ringed bodies.

### Block D — Calibration & color
- [x] **D.1 Pre-stack calibration** — Engine + CLI + 16 unit tests + GUI all live (commit `b73e64c`, 2026-05-01). `(light − dark) / flatNorm` with NaN-safe edges runs in `LuckyRunner.decodeFrame` before quality grading. CLI flags `--master-dark <path>` + `--master-flat <path>`. GUI: two NSOpenPanel-backed pickers in the Lucky Stack panel between the Scientific block and the filename / bake controls; "active" tag when at least one master is set; X button to clear. Missing / dimension-mismatched masters log + drop without crashing. **Future polish (not v1 blockers)**: folder-scan master builder (averages N darks/flats into a master automatically — currently relies on the typical PixInsight / ASTAP workflow where users build masters externally); auto-detect calibration folder by convention (e.g. `<capture-folder>/darks/*.tif`).
- [ ] **D.2 Auto-skip calibration when not needed** — short-exposure bright targets (≤15 ms on Moon/Sun/Venus/Jupiter) → off by default; user can override.
- [x] **D.3 Auto white balance for OSC** — `Engine/Pipeline/OscDefaults.swift` peeks at the SER colorID (or treats AVI as RGB post-AVFoundation) and turns on `ToneCurveSettings.autoWB` when the source is OSC. Mono sources are left untouched (gray-world collapses to identity on a single channel anyway). Wired into `AppModel.openFolder` / `openMixed` after the existing `autoApplyDefaultPreset` call; idempotent via the "no-op when already on" path. `WhiteBalance.computeGrayWorld` + the live `wbPSO` Metal kernel were already wired in `Pipeline.process`; D.3 just toggles the gate to ON when the source is OSC. 7 new OscDefaultsTests.
- [~] **D.4 Per-channel atmospheric dispersion correction (Path B)** — `Engine/Pipeline/LuckyStackPerChannel.swift`. Each Bayer channel extracted at half-res (true measured pixels, no demosaic interpolation), independently phase-correlated + accumulated against a SHARED reference frame (LAPD-graded on green), then recombined with a Bayer-pattern-aware bilinear upsample. CLI `--per-channel`. Geometry verified correct on three Jupiter SERs in TESTIMAGES/biggsky/. **Bare-stack output is near-identical to baseline** — the per-channel dispersion correction is sub-pixel and not visible until aggressive post-stack sharpen / deconv lands. Marked as architecturally complete but NOT yet demonstrating a visual win; full validation depends on Block C blind deconv / dual-stage denoise. v0 still lightspeed-only — multi-AP / sigma-clip / drizzle / two-stage are NOT wired into the per-channel path.

### Block E — IO & interop
- [ ] **E.1 AVI lucky-stack** via SourceReader (depends on F4).
- [x] **E.2 FITS input + output** — Both directions shipped 2026-05-01 (import `cb97123`, export `762c750`). Import: `FitsFrameReader` class conforms to `SourceReader`; FITS recognised by `FileCatalog`; preview / thumbnails / `ImageTexture.load` route through the FITS reader; CLI `analyze` dispatches by extension and emits FITS-specific text + JSON (BITPIX, NAXIS, DATE-OBS via four format fallbacks). Export: `ImageTexture.write` dispatches `.fits` / `.fit` extensions through a new `writeFITS(...)` helper that renders linearSRGB Float32 RGBA into a CPU buffer, collapses to mono via Rec. 709 luma, and serialises through `FitsWriter.write` with CREATOR + OBJECT metadata. Verified end-to-end: SER → stack `--smart-auto` → `.fits` reads clean in both astropy and our own `analyze` CLI. **Remaining (separate item)**: lucky-stacking FITS *input* frames depends on the `LuckyRunner` refactor under F4 — that abstracts byte / RGB / Float32 frame inputs and unblocks AVI lucky-stack at the same time.
- [~] **E.3 Auto target detection from filename** — `Engine/Presets/Preset.swift::PresetAutoDetect.detect` matches keywords for sun (sun/solar/sonne/halpha/h-alpha/ha_/lunt), moon (moon/mond/lunar/luna), jupiter (jup/jupiter), saturn (sat/saturn), mars (mars). `AppModel.autoApplyDefaultPreset` fires on file import (`autoDetectPresetOnOpen = true` by default), pre-applies the matching built-in preset (sets keepPercent / mode / multiAP / etc.). Smart auto button correctly layers RFF on top of the auto-applied preset. **Open work for v1+**: file-row target chip (cosmetic, click to override), `_oiii`/`_sii` narrowband-filter tags (ambiguous — could be solar OR deep-sky), CLI-side auto-detect when no `--keep` etc. are passed.
- [x] **E.4 SER capture-side header validator** — `Engine/IO/CaptureValidator.swift` parses SharpCap / FireCapture's `key=value` pairs out of the SER `observer` / `instrument` / `telescope` strings (regex `([A-Za-z_]+)=(-?[0-9]+(?:\.[0-9]+)?)`) and runs them against rules: bit-depth on lunar/solar, frame count < 100, frame size < 200 px (tile floor), missing UTC timestamp, exposure > 15 ms (planetary), fps < 30 (planetary), capture window > 3 min on Jupiter/Saturn. `PreviewStats.captureWarnings` populated when a SER loads (target inferred via `PresetAutoDetect` on filename + folder); HUD renders each as a yellow ⚠ chip with optional remediation suggestion. Non-modal — purely informational, no pipeline gating. Tests in `CaptureValidatorTests`. Histogram-peak rule deferred (needs a frame analysis pass; not a header check).

### Block F — Performance & infra
- [ ] **F.1 Re-enable MPSGraph FFT path** at `Engine/Pipeline/GPUPhaseCorrelator.swift`. Investigated 2026-04-29: sliced FFT output tensors keep the `complex<f32>` element-type flag, which breaks the magnitude-clamp `graph.maximum(mag, eps, ...)` because `eps` is real `f32` (`'mps.maximum' op requires the same element type for all operands`). Real fix needs either an explicit tensor-type cast after the slice or a rework of the cross-power spectrum to avoid sliceTensor on the FFT output. Not a 5-line fix; vDSP CPU path is fast enough on Apple Silicon (8+ cores via shared FFTSetup), so the 2–3× MPSGraph win isn't urgent. Defer until a real perf wall surfaces.
- [x] **F.2 Verify memory-mapping on >4 GB SERs** — Audit conclusion: no 32-bit-offset assumptions exist in `SerReader` / `SerFrameLoader`. All offset arithmetic uses Swift `Int` which is 64-bit on Apple Silicon; `Data(.alwaysMapped)` on Darwin wraps real `mmap`. Empirically validated against the existing 12 GB lunar SER (`TESTIMAGES/biggsky/mond-00_06_53_.ser`). Defensive: boundary check in `withFrameBytes` traps cleanly on truncated / corrupt files; file-level comment documents the audit. `SyntheticSER` gains `stampFrameIndices` flag for the 2 new SerFrameBytesTests verifying multi-frame offset math.
- [ ] **F.3 Per-frame time budget instrumentation** — timing hooks in `BatchJob.swift`; emit via metrics JSON.

### Block G — Derotation
- [ ] **G.1 Jupiter/Saturn derotation** — new `Engine/Pipeline/Derotation.swift`. Differential rotation across capture window from SER timestamps; warp to reference rotation epoch via great-circle map projection (Jupiter/Saturn ellipsoid).
- [ ] **G.2 Auto-engage** when capture window > 3 min on Jupiter/Saturn; off otherwise. UI takes UT capture-time at *middle* of window.

### Block H — Automation layer (no extra clicks)
- [ ] **H.1 Auto-target-detection wired to preset** (depends on E.3).
- [ ] **H.2 Auto-place ROI for PSF** (depends on C.2).
- [ ] **H.3 Auto-tune dual denoise from frame-noise estimate**.
- [ ] **H.4 Auto-detect undersampling → propose drizzle on** (depends on B.6).
- [ ] **H.5 Auto-skip calibration for short-exposure bright targets** (depends on D.2).
- [ ] **H.6 Auto-keep-% from frame-count + distribution** (depends on A.4).
- [ ] **H.7 Auto-compute deconv tile size from SER header** (depends on C.4).
- [ ] **H.8 Auto white balance on OSC import** (depends on D.3).
- [ ] **H.9 Auto-engage derotation when capture window long** (depends on G.2).
- [ ] **H.10 `Apply ALL Stuff (⇧⌘A)` becomes the BiggSky "Do It All" equivalent** — calibration → align → quality grade → multi-AP → stack → deconvolve → tone → export with H.1–H.9 automated. Manual overrides still available in section panels.

### Open user-reported items (2026-05-01)
- [x] **AP-cell boundaries visible after wavelet sharpening on solar Hα** (2026-05-03 — sigmoid widened) — Mitigation #2 applied: rank-based sigmoid transition width 10% → 20% in `LuckyStack.swift::accumulateAlignedTwoStage`. Neighbouring APs now share more frames in the keep mask → less per-pixel brightness drift across cell boundaries → wavelet-sharpening can't amplify the cellular pattern any more. F3 regression unaffected (default smart-auto path doesn't use two-stage). Needs user-side re-test on the original Hα fixture before declaring fully closed.
- [x] **Crash on increased AP grid + multiple stacking features active** — 2026-05-01 EXC_BREAKPOINT. Two-stage AP grid was unbounded on the high end; 20×20 + 5k frames allocated 16 MB keepMask and pushed Metal's threadgroup-dispatch envelope. Clamped to ≤16×16 in `accumulateAlignedTwoStage` (matches the existing tiledDeconv ceiling). Re-test if the crash recurs after the clamp; if it does, capture the full crash report including non-main threads.
- [x] **Tone curve / B+C / Highlights / Shadows in perceptual (sRGB) space** (2026-05-03 — shipped) — Two new Metal kernels (`gamma_encode` / `gamma_decode`) wrap the entire tone-op block in `Pipeline.process`. Slider midpoints now land at perceptual midtone (≈ linear 0.214) instead of linear 0.5, matching Photoshop / Lightroom semantics. Skipped when no tone op is active so the no-op case costs zero. Existing presets carry through; user-tuned values may want a one-time re-bracket because slider arithmetic shifted.
- [x] **Common-area auto-crop** — already shipped in a previous session as `LuckyStack.cropToCommonArea` (default ON, fired automatically). Today's smoke-test log confirmed: `Common-area crop: 1280x1024 → 1258x1010 (margin 11,7 px)`. Todo entry was a stale duplicate of the already-implemented feature.
- [x] **SER playback — pre-fetch + frame cache** (2026-05-03 — shipped) — `Engine/IO/SerFramePrefetcher.swift` (~140 lines, lock-protected). 16-slot FIFO cache + serial 4-frame look-ahead queue. `applyLoadedSerFrame` extracted as a shared helper so the cache-hit fast path skips the GCD round-trip entirely. `setURL(_:)` invalidates on file switch.

### Pre-existing bugs to fix in v1.0 cycle
- [ ] **Anchored-zoom drift on click-drag** — `App/Views/PreviewView.swift::ZoomableMTKView.anchoredZoom`. Per-axis math (`tpv = texSize / (viewSize × fitScale_axis)`) instead of isotropic baseFit. Math derived in `tasks/lessons.md:5-8`.
- [ ] **Upper-half over-exposure on stacked output (2026-04-29 user observation)** — On the BiggSky Jupiter SER output, the polar / upper region of the disc tends toward ~1.0 luminance (close to clipped white). Likely culprits: (a) `Pipeline.applyOutputRemap` 1%/99% percentile remap is symmetric but Jupiter's polar regions are intrinsically brighter, so the 99th percentile clamps the polar peaks before the mid-band detail — needs an asymmetric-aware version (cap the 99th-percentile target below 1.0 or use a softer roll-off above the 95th); (b) RFF (`radialDeconvBlend`) lifts central-disc brightness; (c) AutoPSF Wiener restores high-frequency power that the 1%/99% stretch then re-amplifies. Action: instrument the remap + RFF outputs separately on a Jupiter SER, identify which stage produces the brightness overshoot, fix at the right layer.

### Done — 2026-04-29 wave (live preview perf + UX + auto-recovery + auto-keep tuning)
- [x] **Stack-end auto-recovery** — `Pipeline.applyOutputRemap` linearly remaps the [1%, 99%] luma window into [0, 0.97] when median < 0.30 (planet on dark sky); skips on lunar / solar / textured subjects (median ≥ 0.30) where data already fills the range. Always-on at the end of `LuckyStack.run`. Replaces the user-facing `autoStretch` toggle entirely (removed from `ToneCurveSettings` / SettingsPanel / PreviewView). Decoder is backwards-compatible — old preset JSON still loads.
- [x] **Live-preview spinner** — top-right "Processing…" capsule (`ProgressView` in `.ultraThinMaterial`) tied to new `AppModel.processingInFlight`. Fades in/out via 180 ms easeInOut so sub-50 ms passes don't render it.
- [x] **Per-stage section highlight** — `Pipeline.process` emits `.colourLevels → .sharpening → .toneCurve → nil` transitions through a new `onStageChange` callback; PreviewCoordinator forwards to `AppModel.activePreviewStage` on main; SettingsPanel sections (and the inline Colour & Levels box) overlay an animated `accentColor.opacity(0.18)` tint when their `PreviewStage` matches.
- [x] **Eager PSO compile** — all 14 compute pipelines (`unsharpPSO`, `divPSO`, …, `waddPSO`) built in `Pipeline.init` instead of lazy. ~80 ms one-time cost shifted from first-slider hiccup to app launch.
- [x] **Wiener live-preview perf (3A)** — new `preview: Bool` parameter on `Pipeline.process`. Throttle path (33 ms) runs Wiener at 50% downsampled (~4× faster FFT, σ × 0.5); debounce path (200 ms) runs at full res. PreviewCoordinator subscribes to both off `reprocessSubject`.
- [x] **Deadlock fix** — coordinator's old in-guard `reprocessSubject.send(())` retry created a feedback loop with the new debounce subscriber: each retry-send reset the debounce timer AND re-fired the throttle, sustaining "Processing…" forever even idle. Replaced with `pendingPreview: Bool?` flag drained directly when the run lands; `preview:false` (drag-end) takes precedence over `preview:true` (drag-tick). Lesson logged in `tasks/lessons.md`.
- [x] **Auto-select first file on open** — `AppModel.openFolder` / `openMixed` now sets `selectedFileIDs = Set([firstID])` after load (was `removeAll`). User can run Apply / Lucky Stack without an extra click on the file row.
- [x] **Section header UX** — `SectionContainer` + `LuckyStackSection` headers now: chevron is 12 pt bold inside a 16 pt frame (was 10 pt / 12 pt), title is `.bold` (was `.semibold`), full row (chevron + icon + title) is the click target via `contentShape(Rectangle())`, every section sits on a soft `Color.secondary.opacity(0.07)` rounded card so section boundaries are visible. The active-stage accent tint animates on top of the card.
- [x] **Smart auto button** — centered pill with blue→violet gradient, white bold label, soft purple drop shadow. Replaces the small left-aligned default Button. Visually pairs with the Run Lucky Stack hero gradient.

### Pending — open natural next steps
- **A.2 Two-stage quality** — global LAPD + per-AP local contrast in `LuckyStack.swift`. Each AP picks its own top-N% subset (PSS approach).
- **A.5 Median HFR + XY-shift sparkline** — in `PreviewStatsHUD.swift`. HFR via centroid+moments, XY-shift from Stabilizer drift cache.
- **B.3 Adaptive AP placement / auto-rejection** — new `Engine/Pipeline/APPlanner.swift`. Per-cell local contrast + luminance; drop bottom 20%.
- **B.5 MultiLevelCorrelation** (PSS-style coarse-to-fine) in `Align.swift`: 2× decimated phase corr → fine refine around peak.
- **B.6 Drizzle 1.5×/2× with anti-aliasing pre-filter** — auto-engage when undersampled.
- **C.4 Tile-size auto-calc** — `tileSize = round(focalLengthMM / pixelPitchUm × barlowMag, 100)`.
- **C.9 Saturn-style ROI workaround** — auto-expand ROI to bbox of bright connected components.
- **D.1 Pre-stack calibration** — master darks/flats/bias from a folder.

### Validation gate (must pass before declaring v1.0 done)
- [ ] All F2 unit tests green.
- [ ] F3 regression harness runs end-to-end on every TESTIMAGES file with no metric regression.
- [ ] Visual diff vs `TESTIMAGES/biggsky/2026-03-05-0055_5-MPO_Jupiter__lapl6_ap126.png` reference within tolerance.
- [ ] Performance budget: 4 GB Jupiter SER end-to-end ≤ 10 min on M2; sigma-clip ≤ 2× current accumulate time; 4K Sun unsharp <10 ms preserved; blind deconv 1024² ≤ 30 s on M2.
- [ ] User does the *final* eyeball pass on each TESTIMAGES file via Apply ALL Stuff. Everything before this is automated and CI-checkable.

### Anti-goals (explicit drops — Quality+Speed filter excludes these)
- Interim v0.4.0/v0.5.0/v0.6.0/v0.7.0 ships → ALL eliminated (single v1.0 release only).
- 16-bit histogram overlay → drop unless trivial.
- Animated zoom transitions → drop.
- Folder watching (auto-refresh on new files) → defer unless trivial.
- Voronoi AP grids → drop (staggered grid + auto-rejection covers it).
- CoreML quality assessment → defer (LAPD + Strehl is enough).
- Star-aware deep-sky sharpening → confirmed out of scope.
- Starnet++ integration → defer (DSO domain).
- Mosaic stitching → defer (Microsoft ICE handles it).

### App Store path (deferred — pick up when user says "set up MAS submission")
- [ ] Register app in App Store Connect (https://appstoreconnect.apple.com/apps)
- [ ] Create `Mac App Distribution` certificate (one-shot CSR via Keychain Assistant)
- [ ] Create `Mac Installer Distribution` certificate (same CSR)
- [ ] Create `AstroSharper Mac App Store` provisioning profile
- [ ] Add MAS export-options.plist + Release-MAS scheme/config
- [ ] Replace `idPLACEHOLDER` in `AppLinks.appStoreReview` with real App Store ID (after first MAS submission)
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`)
- [ ] App Store screenshots (required: 1280×800, 1440×900, 2560×1600, 2880×1800)
- [ ] App Store description, keywords, support URL, age rating
- [ ] Pricing tier decision

### Documentation
- [x] README.md — marketing tone, slogan, App Store / BMC links
- [x] CHANGELOG.md
- [x] docs/ARCHITECTURE.md — code structure, pipeline, layered overview
- [x] docs/WORKFLOW.md — solar / lunar / planetary recipes
- [x] docs/wiki/ — Home, Getting-Started, Lucky-Stack, Stabilization, Sharpening, Tone-Curve, Presets, Keyboard-Shortcuts, File-Formats, Output-Folders, Troubleshooting, FAQ
- [x] tasks/lessons.md
- [x] tasks/todo.md (this file)
- [ ] LICENSE file (MIT)
- [ ] CONTRIBUTING.md
- [ ] Screenshots / GIFs in README

## Test images

`TESTIMAGES/` holds sample SER captures used during development. Don't commit personal captures with metadata that could leak location.

## Known limitations

- AVI lucky-stack untested on real captures (E.1 refactor merged 2026-05-03; SER byte-identical on regression set, AVI fixture pending in TESTIMAGES)
- MPSGraph FFT path is disabled (vDSP CPU path is active and working)
- Multi-AP grid >12×12 may exceed threadgroup memory on older Apple Silicon
- Centroid alignment requires the disc to be brighter than ~25 % of max luminance — overexposed shots without a clear background fail
- Notarization not yet automated — manual step before Release builds

## Session log

- **2026-04-29** (PM) — 7-item batch: F.2 memory-map audit + B.4 cumulative drift validator + B.2 raised-cosine AP blending + C.6 capture gamma + D.3 OSC auto-WB + C.7 luminance-only deconv + C.8 saved-view border crop. Each shipped with unit tests (256 → 270 green). Single Wiener.deconvolve gained both `captureGamma` and `processLuminanceOnly` parameters; LuckyStackOptions gained matching fields so the AutoPSF post-pass has its own configuration source independent of bake-in. New file `Engine/Pipeline/OscDefaults.swift` (32 lines + 7 tests). 7 commits on `feature/v1-foundation`. GUI + CLI + Tests schemes all green.

- **2026-04-29** — Live-preview UX + perf wave + A.4 auto-keep tuning + auto-recovery shipping.
  - **Stack-end auto-recovery (replaces autoStretch toggle):** Mean-stacking compresses dynamic range — outputs looked washed out; user complained, autoStretch toggle removed earlier in the session was the wrong UX. Now: always-on `Pipeline.applyOutputRemap` does a 1%/99% percentile linear stretch into [0, 0.97], gated on median < 0.30 so lunar / solar / textured subjects (which fill the range natively) skip the remap. Verified end-to-end: planetary stacks recover; lunar stacks pass through unchanged.
  - **Live-preview perf:** Spinner overlay surfacing `inFlight`; eager PSO compile in `Pipeline.init` (kills first-slider hiccup ~80 ms); Wiener now runs at 50% downsampled during drag, full-res on a 200 ms drag-end debounce; per-stage section highlight (Colour & Levels / Sharpening / Tone Curve panels light accent-tinted when their stage is executing).
  - **Deadlock fix (post-shipping):** "Processing" + section pulsing ran forever even when idle. Root cause = an in-guard `reprocessSubject.send(())` retry feeding both the new 200 ms debounce sink and the existing 33 ms throttle sink — each retry reset the debounce timer + re-fired the throttle, sustaining a self-feeding loop while pipeline > 33 ms. Replaced with a `pendingPreview: Bool?` flag drained directly by the completion block (no Combine round-trip). Lesson logged.
  - **A.4 auto-keep tuning (the (b) of "b first a after"):** Clamp range moved [0.05, 0.50] → [0.20, 0.75], anchored on BiggSky reference SER metadata (Saturn 75 / Jupiter f/14 75 / Mars 67 / Jupiter SCT 65 / Jupiter UL16 20). Jitter tightening moved BEFORE the clamp so it stays visible across the band. Tests updated; CLI annotates `(auto-keep)` so resolved value is explained.
  - **(a) Saturn manual-AP regression test:** Ran our auto-grid 6×6 (36 APs) vs BiggSky's 28 manually-placed APs on the same Saturn SER. After histogram-matching to remove dynamic-range bias, our LAPD on the planet body region was 15.82 vs BiggSky's 13.99 — 1.13× edge for automatic placement. Verdict: **manual AP placement UI not needed for v1.0**. Side-by-side at `/tmp/saturn-regression/saturn_compare_side_by_side.png`.
  - **Section header UX:** Chevron sized up to 12 pt bold / 16 pt frame; title now `.bold`; full row clickable; every section sits on a soft rounded card so boundaries are visible at a glance.
  - **Smart auto button:** Centered pill with blue→violet gradient, white bold label, drop shadow. Visually pairs with Run Lucky Stack.
  - **Auto-select first file on open:** Was clearing selection; now sets `selectedFileIDs = Set([firstID])` so Apply / Lucky Stack runs without an extra click.
  - 254/254 tests green; build clean. Side-by-side test image saved at `/tmp/saturn-regression/saturn_compare_side_by_side.png`. Memory + lessons + todo all updated.

- **2026-04-28** (PM, fourth wave) — Block C v0 wave: GUI toggles for `--per-channel` + `--auto-psf` brought to parity with CLI. C.5 dual-stage denoise (pre + post) wraps the auto-PSF + Wiener pipeline. C.3 tiled deconv v0 ships green/yellow/red mask blend (APPlanner-classified, single global PSF for now). Post-pass moved fully into engine — `LuckyStack.run` is now the single source of truth (CLI's duplicated post-pass logic deleted). Empirical: full BiggSky-default kit (`--per-channel --auto-psf --tiled-deconv --denoise-pre 75 --denoise-post 75`) closes most of the visible gap to the reference. 254/254 tests still green. Three commits: `dfa477d` (toggles + denoise), `3a872ea` (tiled deconv), and the docs commit. C.1 / C.3 marked `[~]` (v0 partial — per-tile PSF + iterative refinement deferred to v1+); C.5 ticked.

- **2026-04-28** (PM, third wave) — AutoPSF v0 shipped (`Engine/Pipeline/AutoPSF.swift` + `--auto-psf` CLI flag). Limb-LSF Gaussian sigma estimator + Wiener post-pass — closes the user-facing "I don't have to know what sigma to use" problem. Two design lessons: (a) second-moment integration over the WHOLE LSF saturates at the 5-px clamp because cloud-band gradients on the disc-side inflate M₂ — fix is outer-side-only integration; (b) the outer-side window must be tight (6 px) because real planetary discs have a slow atmospheric-scatter halo beyond that point that integrates as PSF tail and re-saturates the clamp. Synthetic-disc tests pass at 12-px window because they have no halo. Empirical on BiggSky Jupiter SERs: σ 3.1-3.5 px, confidence 100-200, visibly improved band detail. 8 new pure-Swift tests in `AutoPSFTests`; 254/254 green. Closes the v0 part of C.1; iterative blind refinement is C.1 v1+. Commit `3aa7552`.

- **2026-04-28** (PM, second wave) — Path B chromatic-alignment fix. (`LuckyStackPerChannel.swift` + 3 new Metal kernels: `unpack_bayer16_channel_to_rgba`, `unpack_bayer8_channel_to_rgba`, `lucky_combine_channel_planes`). Dispatcher in `LuckyStack.run` engages on Bayer + `--per-channel`; mono SER falls through. v0 is lightspeed-only. New pure-Swift unit suite `BayerChannelSiteTests` (12 tests) validates the pattern × channel × cell math. 246/246 tests green.
  - **First commit (`cad623b`) was geometrically wrong**: each channel computed its own argmax-by-quality reference frame and the combine kernel placed half-res R/B values at the same output pixel even though they came from diagonally opposite corners of the 2×2 Bayer cell. Both bugs surfaced as visible chromatic fringing on the user's eye check ("3 colors not matching").
  - **Second commit fixes**: single shared LAPD grade on green channel (used for scores / kept set / reference index / per-frame quality weights across all three channels); combine kernel now takes Bayer pattern uniform and applies per-channel sub-pixel sampling offsets so each output pixel samples R and B from raw-coord-aligned half-res positions.
  - **Honest empirical readout**: post-fix, per-channel and baseline outputs are nearly indistinguishable on bare lucky-stacks. The first commit's "correct color" appearance was the misalignment artifact spreading colors into adjacent pixels, NOT real chromatic-dispersion correction. The actual visible gap to BiggSky's reference is post-stack deconv + denoise (Block C), not the stacking algorithm. D.4 demoted from `[x]` to `[~]` — architecturally complete but not yet demonstrating a visual win; full validation depends on Block C deconvolution landing on top.

- **2026-04-27** — Plan finalized as single-shot v1.0 milestone. After two BiggSky pub Google Docs surfaced concrete techniques (tiled deconv with green/yellow/red mask, dual-stage denoise, capture-gamma compensation, multi-% stacking, auto-target detection from filename, 32-bit float TIFF default, BiggSky default 25% keep), expanded gap matrix to 30 items. User locked principles: NO interim shipping (single big release at ~90% completion); test harness MANDATORY (CLI + unit tests + regression vs `TESTIMAGES/biggsky/*.ser`); Quality + Speed are the ONLY filter; automate-over-expose (every auto-detectable setting becomes auto, no extra button); UI scaffolding stays. Reference dataset: `TESTIMAGES/biggsky/{2022-10-25-0055_2.ser, 2022-12-10-0254_3.ser, 2026-03-05-0104_6-.ser, 2026-03-05-0055_5-MPO_Jupiter__lapl6_ap126.png}`. Full strategy: `~/.claude/plans/check-if-this-project-drifting-pnueli.md`. Restructured todo into Foundation (F1-F5) + 8 parallel work blocks (A–H) + Validation gate + Anti-goals. No code changes this session.

- **2026-04-26** (PM) — v0.3.0 ship: Preview HUD + sharpness probe + SER quality scanner + on-disk cache + sortable Type/Sharpness columns + filename filter + AstroTriage mouse port + flip-icon hide-when-off + MTKView on-demand redraw + native app icon. Public GitHub repo + notarized GH release.
- **2026-04-26** (AM) — Solar stabilization improvements: R-key reference, alignment modes, memory-texture path, DC removal. Full docs written.
- **2026-04-25** — D14 polish, inline player, thumbnail fix
- **2026-04-22** — D12 brand identity, About panel, How-To window
