# AstroSharper — Project Memory

A running record of where we are, what's done, and what's next. Update at the end of every session.

## Current state (v0.3.0 — released 2026-04-26)

- Public GitHub repo: https://github.com/joergs-git/AstroSharper
- Latest release: **v0.3.0** notarized + stapled, available on GitHub Releases
- Mac App Store submission: deferred ("another time" per user)
- All Apple infra in place for next notarized GH release: Developer ID cert installed, `notarytool` keychain profile configured, auto-managed provisioning profile present

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
- [ ] **F3 Regression harness** — runs full pipeline on every file in `TESTIMAGES/biggsky/`, `TESTIMAGES/jupiter/`, `TESTIMAGES/sun/`. Writes metrics JSON (sharpness, SNR-flat, FFT-energy, alignment RMS, runtime) and visual diff PNG. Side-by-side against `TESTIMAGES/biggsky/2026-03-05-0055_5-MPO_Jupiter__lapl6_ap126.png` (AS!3 reference output). Non-zero exit on metric regression beyond per-test tolerance.
- [ ] **F4 SourceReader protocol** — new `Engine/IO/SourceReader.swift`. Refactor SerReader/AviReader to conform. Required so LuckyStack/Stabilizer/QualityProbe consume any input format identically. Unblocks AVI lucky-stack and FITS.
- [ ] **F5 32-bit float TIFF output + render modes** — extend `Engine/Exporter.swift` for 32-bit float (deconv peaks routinely > 65535). Render modes (Clip / AutoRange / Manual Min Max) in display path; doesn't affect file content.

### Block A — Quality intelligence
- [ ] **A.1 LAPD as primary metric** — replace VL in `QualityProbe.swift::SharpnessProbe` with Diagonal Laplacian (MDPI 2076-3417/13/4/2652). Same MPS infra, new kernel coefficients.
- [ ] **A.2 Two-stage quality** — global LAPD + per-AP local contrast in `LuckyStack.swift`. Each AP picks its own top-N% subset (PSS approach).
- [ ] **A.3 Strehl-ratio supplement** — for high-frame-count regime. 2D Moffat fit on brightest disc/feature.
- [ ] **A.4 Lucky keep-% formula** — `SerQualityScanner.makeDistribution`. Anchor at BiggSky-default 25%, frame-count floor `max(50, ceil(0.25 × N))`, knee detection at percentile p where `score(p) ≤ 0.5 × p90`. Display % AND absolute frame count. Auto-applied as status line, no popup.
- [ ] **A.5 Median HFR + XY-shift sparkline** — in `PreviewStatsHUD.swift`. HFR via centroid+moments, XY-shift from Stabilizer drift cache.
- [ ] **A.6 Multi-percentage stacking in one pass** — comma-separated input "20, 40, 60, 80" in `LuckyStackSection.swift`. Single read pass, multiple weighted accumulators, multi-output write.

### Block B — Alignment & stacking
- [ ] **B.1 Sigma-clipped stacking** — kernel `lucky_accumulate_sigma_clip` in `Shaders.metal` (Welford + clipped re-mean). σ slider default 2.5 in LuckyStackSection.
- [ ] **B.2 Feathered AP blending** — replace bilinear with raised-cosine fall-off + accumulated-weight normalization. Uniform `apFeatherRadius` default = AP_size × 0.25.
- [ ] **B.3 Adaptive AP placement / auto-rejection** — new `Engine/Pipeline/APPlanner.swift`. Per-cell local contrast + luminance; drop bottom 20%. Sparse-AP mask honored by accumulator.
- [ ] **B.4 Cumulative drift tracking** — `Stabilizer.swift` caches last-frame shift, seeds next phase-corr search.
- [ ] **B.5 MultiLevelCorrelation** (PSS-style coarse-to-fine) in `Align.swift`: 2× decimated phase corr → fine refine around peak.
- [ ] **B.6 Drizzle 1.5×/2× with anti-aliasing pre-filter** — new `Engine/Pipeline/Drizzle.swift` + Metal kernel splatting onto upsampled accumulator with `pixfrac` (default 0.7). Pre-filter avoids the high-freq grid moiré BiggSky warns against. Auto-engage when undersampled (pixel scale > FWHM/2.4).

### Block C — Deconvolution paradigm (BiggSky parity)
- [~] **C.1 Blind deconvolution (v0 — limb-LSF auto-PSF + Wiener + RFF)** — `Engine/Pipeline/AutoPSF.swift` estimates Gaussian PSF sigma from the planetary limb's LSF + auto-bails on textured / cropped subjects. `LuckyStack.radialDeconvBlend` (RFF — Radial Fade Filter) reuses the auto-detected disc geometry to fade Wiener strength near the limb, eliminating Gibbs ringing. Smart-auto SNR=200 universal sweet spot empirically verified across Saturn/Jupiter/Mars (2026-04-29). RFF original to AstroSharper — README marketing copy added. **Open work for full C.1**: iterative joint refinement (re-estimate PSF after first-pass deconv), Moffat / anisotropic PSF, per-tile PSF for C.3.
- [ ] **C.2 PSF from auto-ROI** — high-contrast region detection avoiding limb/saturation. Lunar: avoid terminator+limb. Planetary: interior crescent away from rim.
- [~] **C.3 Tiled deconvolution with green/yellow/red mask (v0 — global PSF)** — `LuckyStack.tiledDeconvBlend` reuses APPlanner. Cells dropped by APPlanner = RED (skip deconv). Surviving cells split at the median LAPD score: top half = GREEN (full deconv), bottom half = YELLOW (half-strength deconv). Mask uploaded as r32Float (apGrid × apGrid), GPU `lucky_mask_blend` shader bilinear-samples for smooth tile boundaries. v0 uses a SINGLE global PSF from AutoPSF; per-tile PSF estimation deferred to C.3 v1+. CLI `--tiled-deconv [--tiled-grid N]`, GUI toggle. Empirical 2026-04-28: visibly cleaner backgrounds on BiggSky Jupiter; full-kit output closes most of the visible gap to the reference. Mask Bkg override toggle for v1+.
- [ ] **C.4 Tile-size auto-calc** — `tileSize = round(focalLengthMM / pixelPitchUm × barlowMag, 100)`, min 200, overlap 10–20%. Auto toggle on deconv section.
- [x] **C.5 Dual-stage denoise** — `LuckyStack.denoiseTexture` wraps `Wavelet.sharpen` with amounts=[1,1,...] (perfect reconstruction) + per-band soft-threshold scaled from 0..100 percent → 0..0.025 threshold (same upper end as the existing manual wavelet denoise). Pre-denoise fires before AutoPSF + Wiener (cleaner LSF, less noise amplification through the inverse filter); post-denoise fires after Wiener (suppress amplified noise + ringing). CLI `--denoise-pre N --denoise-post N`, GUI sliders revealed when Auto-PSF is on. Defaults 0 (off); BiggSky-typical 75/75.
- [ ] **C.6 Capture gamma compensation** — input camera gamma value (1, 2, …) or UI value (100, 50). Pre-linearizes before deconv to remove planetary edge ringing.
- [ ] **C.7 Process Luminance Only** — for OSC. PSF estimated on weighted Y, applied to all channels. Default ON for color captures.
- [ ] **C.8 Border crop after deconv** — configurable, defaults `SaveView_BorderCrop=32`, data crops 0.
- [ ] **C.9 Saturn-style ROI workaround** — auto-expand ROI to bbox of bright connected components for ringed bodies.

### Block D — Calibration & color
- [ ] **D.1 Pre-stack calibration** — new `Engine/Pipeline/Calibration.swift`. Master darks/flats/bias from a folder; apply before quality grading.
- [ ] **D.2 Auto-skip calibration when not needed** — short-exposure bright targets (≤15 ms on Moon/Sun/Venus/Jupiter) → off by default; user can override.
- [ ] **D.3 Auto white balance for OSC** — histogram-based per-channel offset + scale.
- [~] **D.4 Per-channel atmospheric dispersion correction (Path B)** — `Engine/Pipeline/LuckyStackPerChannel.swift`. Each Bayer channel extracted at half-res (true measured pixels, no demosaic interpolation), independently phase-correlated + accumulated against a SHARED reference frame (LAPD-graded on green), then recombined with a Bayer-pattern-aware bilinear upsample. CLI `--per-channel`. Geometry verified correct on three Jupiter SERs in TESTIMAGES/biggsky/. **Bare-stack output is near-identical to baseline** — the per-channel dispersion correction is sub-pixel and not visible until aggressive post-stack sharpen / deconv lands. Marked as architecturally complete but NOT yet demonstrating a visual win; full validation depends on Block C blind deconv / dual-stage denoise. v0 still lightspeed-only — multi-AP / sigma-clip / drizzle / two-stage are NOT wired into the per-channel path.

### Block E — IO & interop
- [ ] **E.1 AVI lucky-stack** via SourceReader (depends on F4).
- [ ] **E.2 FITS input + output** — pure-Swift `Engine/IO/FitsReader.swift` + `FitsWriter.swift`. 2D images only.
- [ ] **E.3 Auto target detection from filename** — regex on `jup_/jupiter`, `sat_/saturn`, `mars_/mars`, `sol_/solar/sun`, `lunar/luna_/moon`, `_ha/_oiii/_sii`. Sets active preset on import. Chip in file row, click to override.
- [ ] **E.4 SER capture-side header validator** — new `Engine/IO/CaptureValidator.swift`. Non-modal warnings in HUD: exposure > 15 ms; frame rate < 30 fps; histogram peak > 90%; 8-bit on lunar/solar; capture window > 3 min on Jupiter/Saturn.

### Block F — Performance & infra
- [ ] **F.1 Re-enable MPSGraph FFT path** at `Engine/Pipeline/GPUPhaseCorrelator.swift:194`.
- [ ] **F.2 Verify memory-mapping on >4 GB SERs** — patch any 32-bit-offset assumptions; tested against `TESTIMAGES/biggsky/*.ser` (3.3–4.0 GB each).
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

### Pre-existing bugs to fix in v1.0 cycle
- [ ] **Anchored-zoom drift on click-drag** — `App/Views/PreviewView.swift::ZoomableMTKView.anchoredZoom`. Per-axis math (`tpv = texSize / (viewSize × fitScale_axis)`) instead of isotropic baseFit. Math derived in `tasks/lessons.md:5-8`.

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

- AVI lucky-stack support is stubbed — engine is SerReader-coupled
- MPSGraph FFT path is disabled (vDSP CPU path is active and working)
- Multi-AP grid >12×12 may exceed threadgroup memory on older Apple Silicon
- Centroid alignment requires the disc to be brighter than ~25 % of max luminance — overexposed shots without a clear background fail
- Notarization not yet automated — manual step before Release builds

## Session log

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
