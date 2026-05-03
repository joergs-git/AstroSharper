# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows semantic versioning once it leaves 0.x.

## [0.4.0] — unreleased (in development on `feature/v1-foundation`)

The "engine decides everything" release. Replaces hand-tuned per-target presets
with empirical content-aware resolution, adds a Mac-native UX overhaul, and
ships opt-out anonymous telemetry + a community thumbnail feed.

### Added

- **AutoNuke master toggle** in the Lucky Stack panel. One switch hands every
  auto-feature to the engine: auto-PSF + auto-keep-% + AutoAP grid/patch + the
  multi-AP yes/no gate. Manual sliders grey out so there are no conflicting
  controls. Bake-in / Auto-tone stay independent (output-style choices, not
  stack-quality decisions).
- **AutoAP** — `Engine/Pipeline/AutoAP.swift` — empirical AP geometry resolver.
  Closed-form preflight from AutoPSF σ + APPlanner content scoring; multi-AP
  yes/no gate from per-frame shift variance (calibrated against the BiggSky
  fixture set); feature-size cascade for AutoPSF-bail subjects (lunar / solar
  surface). Beats hand-tuned presets on **6/6** regression fixtures (Jupiter
  +9 / +18 / +26%, Mars +1%, Moon +31%, Saturn +4%). CLI:
  `--auto-ap=off|fast|deep`. Sweep harness: `validate --auto-ap-sweep`.
- **Target picker chips** in the headline bar — six violet rounded-corner
  chips (Sun / Moon / Jupiter / Saturn / Mars / Other). Auto-detected target
  from filename keywords lights up; click any chip to override. Mandatory
  selection before Run Lucky Stack so the engine never runs against generic
  defaults.
- **Splash screen** on launch with "don't show again" checkbox + AstroBin /
  GitHub links + brand portrait credit. Re-openable via Help → Show Welcome
  Screen…
- **Buy-me-a-coffee dialog** ported verbatim from AstroTriage — floating
  NSWindow with portrait + first-person copy + Yes / Maybe later / No thanks,
  random scheduling offset 10..100 launches. Currently gated off via
  `coffeePromptEnabled = false` until first public release.
- **Anonymous opt-out telemetry** (`TelemetryClient.swift` + Supabase
  `stack-completed` edge function). Random per-machine UUID + AutoAP / AutoPSF
  parameters per stack — no filenames, no hostnames, no PII. Bottom-bar
  status icon toggles it off in one click.
- **Community Stacks feed window** ("Show other peoples thumbs"). Violet
  button in the headline bar + Help menu (⇧⌘C) opens a 3-column grid of
  recent uploads. Each card: thumbnail (loaded from signed URL), target chip,
  YOU badge if your machine, UTC date/time + duration + frame count + UUID
  short-form. Server caps each contributor at 6 entries + 50 total. Double-
  click any thumbnail to open at 1.5× size in a Mac-native pinch-zoomable +
  centered viewer (NSScrollView with magnification + custom centering clip
  view; pinch / smart-magnify / scroll-pan all native).
- **Per-stack community thumbnail upload** — opt-out per-stack alert after
  every successful run. JPEG ≤800 px on the long edge, ≤256 KB, no client-
  side tone manipulation (the saved TIFF's tone is the truth).
- **Saved-file pipeline summary** line under the Lucky Stack toggles — tells
  you in plain English which paths will modify the saved TIFF (`bare
  accumulator` vs `auto-PSF Wiener → bake-in (Sharpen + Tone) → auto-tone`).
- **Status-bar opt-out icons** (right end): iCloud sync (informational),
  telemetry, community share. Green when active, grey when off.
- **Help menu** entries: Show Welcome Screen…, Show other peoples' stacks…
  (⇧⌘C), Example images on AstroBin, Buy me a coffee ☕ (force-presents
  the dialog).
- **Preset round-trip** — new `LuckyPresetDetails` block on `Preset` captures
  every Lucky Stack setting (autoNuke, auto-PSF, denoise, drizzle, RFF,
  sigma-clip, bake-in, auto-tone, …). Save → reload → identical pipeline.
  Old presets decode cleanly with new fields defaulted (Optional decode).
- **Supabase shared with AstroBlink** — single project (`bpngramreznwvtssrcbe`)
  distinguished by `app` discriminator column on every table. See
  `supabase/DEPLOY.md` for migration + edge function deployment.
- **`docs/wiki/AutoAP-and-AutoNuke.md`** — full algorithm walkthrough +
  empirical regression results.

### Changed

- **Preview mouse model is now standard macOS** (rebuilt — supersedes the
  AstroTriage Photoshop drag-zoom): plain drag = pan, pinch = zoom anchored
  to cursor, ⌥+scroll = zoom, double-click = fit + center, plain scroll =
  pan when zoomed in.
- **Cmd-zoom shortcuts** updated: `⌘+` zoom in / `⌘-` zoom out / `⌘0` fit /
  `⌘1` 1:1 / `⌘2` 1:2 / `⌘3` 1:4 / `⌘4` 1:8. (Was `⌘=` which doesn't bind
  on a German keyboard layout.)
- **Auto-tone defaults OFF** (`autoRecoverDynamicRange = false`). Bare
  accumulator preserves highlight detail; the user prefers the truth.
- **Sandbox entitlement** — added `com.apple.security.network.client` so the
  app can resolve DNS + reach Supabase from inside the sandbox.
- **"Apply ALL Stuff" hero button removed** — AutoNuke + per-section Run
  buttons make the intent more visible. Process menu's "Apply to Selection"
  (⌘R) is the remaining single-action entry point.
- **"Smart auto" button** (one-shot preset application) replaced by the
  AutoNuke toggle — same effect, but disables the manual controls when on
  so the user can't end up with conflicting settings.
- **README + ARCHITECTURE + Wiki Home** all rewritten to match the current
  state.

### Fixed

- **`patchHalf` was hardcoded to 8 px in the multi-AP shader call** — the
  GUI slider was actually routed into `multiAPSearch` (search radius) AND
  the real correlation patch was pinned. Now properly threaded; AutoAP
  picks `patchHalf ≈ σ × 3` from AutoPSF.
- **`StatusBar` ProgressView assertion** — `total == 0` during stage
  transitions triggered the AppKitProgressView "min ≤ max" runtime check.
  Clamped to `max(total, 1)`.
- **Target picker click didn't update the highlight** — was reading from
  filename detection only; now reads from active preset target.
- **JSONEncoder omitted nil optional keys** in telemetry / community share
  payloads → server validators returned 400. Custom `encode(to:)` now
  always emits the keys with `null` values.
- **Sandboxed app couldn't reach the network** — missing
  `com.apple.security.network.client` entitlement was blocking
  mDNSResponder, so DNS resolution failed before any HTTP could leave.
- **Headline bar empty grey area** — `Color.clear.frame(width:)` without
  height defaults to fill all available vertical space, inflating the bar
  to ~150 pt of empty grey. Constrained to `height: 1`, plus hard
  `frame(height: 50)` cap on the outer HStack.
- **Community thumbnail looked over-stretched** — the auto-stretch + γ 2.2
  injected into the upload pipeline was crushing midtones on properly-
  toned outputs. Removed entirely; thumbnail is now a faithful downscale
  of whatever the user actually saved.

### Performance

- **AutoAP overhead**: ~50–100 ms CPU-side preflight, regardless of frame
  count. Total stack wall-clock ratio: **1.16×** baseline across the
  6-fixture regression sweep.
- **Telemetry / community network**: detached `URLSession` tasks, ≤5 s
  timeout, fire-and-forget. Failures are logged but don't block the
  user's stack workflow.

### Internal

- 290 unit tests pass (added 8 across 2 new AutoAP suites: closed-form
  preflight, AutoPSF-driven, refinement, kneedle, multi-AP gate,
  feature-size cascade).
- 6/6 regression baselines unchanged on `validate TESTIMAGES/biggsky/`.
- Memory entries added: `project_autoap_v1.md`, `project_supabase_shared.md`.
  Mouse memory rewritten: `feedback_astrotriage_mouse.md` (was "copy
  AstroTriage verbatim", now "standard macOS — do NOT re-introduce
  Photoshop drag-zoom").

## [0.3.0] — 2026-04-26

### Added
- **Preview HUD overlay** (bottom-left of the preview): filename, dimensions, bit-depth, Bayer pattern, file size, capture timestamp, current frame index, and a live variance-of-Laplacian sharpness number for the displayed frame.
- **SER quality scanner** with on-demand "Calculate Video Quality" button — samples up to 64 evenly-spaced frames, computes a sharpness distribution (`p10 / median / p90`), and recommends a lucky-stack keep-percentage based on the spread of the distribution.
- **Disk-persistent quality cache** (`Application Support/AstroSharper/quality-cache.json`) keyed by file size + mtime, so re-opening a previously-scanned SER is instant and per-image sharpness scores survive across sessions.
- **Sortable Type column** in the file list — groups SERs together vs. raster images.
- **Sortable Sharpness column** — variance-of-Laplacian, computed in the background after thumbnail load. SER / AVI rows show "video" instead.
- **Live filename filter** with Include / Exclude toggle — type a substring to either show only matches or hide them all.
- **In-SER playback**: play / pause button on the SER scrub bar advances frames inside the file at the configured fps; stops automatically when switching files.
- **Photoshop-style anchored zoom** ported from AstroBlinkV2: plain drag = anchored click-drag zoom, ⌥-drag = pan, double-click = fit + center, pinch = anchored zoom.
- **Native macOS app icon** wired through the asset catalog (16 → 1024).
- **Public GitHub repo** at <https://github.com/joergs-git/AstroSharper>.

### Changed
- Flip column shows the 180°-flip icon **only on rows that are actually flipped** — non-flipped rows render an invisible hit-target so the column still toggles on click.
- Preview MTKView switched to `enableSetNeedsDisplay = true; isPaused = true` (was free-spinning at 60 fps). Window resize with a SER loaded is no longer sluggish.
- Scrubbing a SER now drops the stale "after" texture immediately so the raw frame paints in ~16 ms instead of waiting for the full sharpen / deconv pipeline.
- SER quality scanning is **opt-in** via the HUD's Calculate button (was auto-on-open) — browsing many SERs is no longer slowed by repeated background scans.

### Fixed
- SER play button was missing entirely from `SerScrubBar`; now present and bound to `P`.
- Switching files mid-playback no longer leaves a runaway frame-advance timer.

### Also shipped in 0.3.0 (deferred from the prior 0.2.0 → 0.3.0 cycle)

#### Added
- **Reference frame marker**: press `R` on any row to pin it as the stabilization reference (gold star). Single-valued — only one row holds the marker at a time.
- **Alignment modes** for solar / lunar imaging:
  - `Disc Centroid` — locks onto the bright disc against dark sky, robust against thin clouds and seeing wobble.
  - `Reference ROI` — phase-correlate inside a user-defined rect; pin alignment to a sunspot, prominence, or crater.
- **Stabilize-from-memory** preserves any prior in-place edits (sharpen / tone). Pre-flight confirm asks before re-aligning over edited frames.
- **Apply ALL Stuff** (`⇧⌘A`) — single hero button that picks lucky-stack, in-memory ops, or file-batch depending on selection.
- **Cmd zoom shortcuts**: `⌘=` `⌘-` `⌘0` (fit) `⌘1` (1:1) `⌘2` (200 %).
- **Section header click-to-collapse** — entire title row is the toggle, not just the chevron.
- **AVI extension** is now recognised in the catalog (lucky-stack engine support coming next iteration).
- **DC removal** before phase-correlation Hann window — fixes solar-disc alignment drift.

#### Changed
- Stabilize boundary default is now **Crop** (was Pad).
- Default reference mode is now **Marked** — falls back to first-selected with a warning when nothing is pinned.
- Quality-weighted lucky stack uses gamma-shaped weights (`0.05…1.5`) for crisper Scientific stacks.
- Default playback fps is **18**.

#### Fixed
- Sandbox NAS-write errors auto-fall back to the container Documents folder.
- Float-TIFF thumbnails now render normalised (no more blown-out white tiles).
- Memory tab no longer leaks a stale playback frame after backspace-delete.
- Lucky-stack threadgroup-memory race that caused `SIGABRT` on large multi-AP grids.

## [Unreleased]

### Added
- **HUD toggle shortcut** (`I`) and View-menu item — show / hide the preview stats overlay.
- **Frame-to-frame jitter score** (RMS pixel shift, phase-correlated between adjacent samples) added to the SER quality scan; surfaced in the HUD distribution panel and used to refine the lucky-stack keep-% recommendation when jitter > 15 px.
- **ROI mini-map overlay** (top-leading corner of the preview) — Photoshop-Navigator-style thumbnail with a dashed yellow rectangle marking the visible viewport. Hidden when the full image fits in the view. Updates live during pan / zoom / pinch.
- **AVI preview support** — `AviReader` (AVFoundation-backed) decodes AVI frames into the same `rgba16Float` pipeline as SER. Browse, scrub, play, sharpness-probe and quality-scan AVI files exactly like SERs. Lucky-Stack on AVI still routes through its existing gate.
- **Downsampled load path for image sharpness** — `ImageTexture.loadDownsampled(maxDimension:)` uses ImageIO's thumbnail pipeline, so per-file sharpness scoring on 6 K TIFFs no longer triggers a full decode.

### Changed
- **`SharpnessProbe.shared`** singleton replaces per-call instantiation. Instantiating one probe per file in the thumbnail loader (500 TIFFs → 500 command queues) was the dominant import cost; now negligible.
- **Probe texture cache** keyed by `(width, height, pixelFormat)` — destination Laplacian / stats textures are allocated once per shape and reused. SER quality scans of 64 same-shaped frames now reuse the same two destination textures across the whole scan.
- **FFT-cached phase correlation** — `Align.computeFFT(of:)` + `Align.phaseCorrelate(refFFT:frameFFT:)` lets the SER quality scanner reuse each sample's FFT as the next pair's reference, halving CPU time for the jitter pass.

## [0.2.0] — 2026-04-25

Initial brand identity, About panel, How-To window, app icon, version display.

## [0.1.0] — 2026-04-22

First runnable build: open folder, sharpening, basic stabilization, batch export.
