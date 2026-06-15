# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows semantic versioning once it leaves 0.x.

## [Unreleased]

## [0.5.2] - 2026-06-15

### Added
- **Coverage-map crop for jumpy / tightly-framed captures** — replaces the old
  `2×max-shift` common-area crop (where a single jumpy frame shrank the whole
  output) with a coverage-aware pipeline on the standard stacking path. Each output
  pixel is normalised by how many frames actually covered it (correct exposure at
  the drift border instead of a smeared clamp), then cropped by a coverage
  threshold. On a tight 312×296 Jupiter this preserved ~44% more of the disc. New
  Lucky Stack toggles **Reject jump frames** and **Coverage crop (keep field)**
  with a "Field kept" slider; CLI `--no-reject-jumps`, `--no-coverage`,
  `--coverage-threshold N`. Default ON; output is byte-identical on well-tracked
  captures. AutoNuke forces both on.
- **Jump-outlier rejection** — drops frames whose alignment shift is a statistical
  (median + MAD) outlier before stacking, so a seeing jump / gust / tracking jerk
  can't corrupt the stack. Steady drift preserved; capped at 15% of frames.

## [0.5.0] - 2026-06-01

### Added
- **SER/AVI trim · crop · export pipeline** — set Start/End trim markers on the
  scrub bar, crop, rotate (0/90/180/270), resize (1:1 … 1:16), bake in the live
  Sharpen + Tone + Coloring, and export the clip to **GIF, MP4, APNG** or a single
  TIFF frame. Export runs in a draggable panel with a Duration-driven UX and a
  post-export preview window; trim/crop/export settings persist per source SER.
- **Coloring section — Affinity-style 4-curve gradation editor** under Tone, with
  per-channel hue tint + channel mixer. Applied on every output path (live preview,
  Apply, Stack, Batch, Export) and saved/restored as part of a Preset.
- **QuickLook integration** — Finder thumbnails and spacebar playback for SER files,
  plus AVI thumbnails, via embedded QuickLook app-extensions.
- **Solar Dual-Zone tone curve** (`ToneCurveSettings.solarDualZone`) — fixed-LUT
  asinh off-limb + linear disc, auto-enabled in Sun — Full-Disk and Sun — Hα
  Prominence presets, revealing prominences without touching the stacking pipeline.
- **Delete File context menu** (with confirmation) in the file list.
- **RGB histogram overlay** for SER/AVI scrub frames, read from the decoded Metal
  texture, shown in the tone-curve editor for OSC stacks.
- **Lucky Region stacking mode** (`LuckyStackMode.region`, CLI `--mode region`)
  — AS!4-style per-tile frame selection. The image is divided into 32×32
  tiles; for each tile, the engine picks adaptively 1-10 of the kept frames
  where local quality at THAT tile was sharpest, then averages only those
  (bilinear-blended at tile boundaries). Closes the gap on solar captures
  where bare global stacking systematically lost 40-60% edge energy vs Frame 0
  (the "stacking that's worse than a single frame is pointless" problem).
  Verified on /Volumes/ASTRO/LUNT/AUTOTRANS/ Hα captures: bare stack -49%
  edges, Lucky Region -16%, and visually CLEANER than Frame 0 with more
  filamentary detail visible. Reuses the existing GPU quality-grader
  threadgroup partials for the per-tile scoring (zero extra GPU work for
  scoring; new `lucky_accumulate_region` Metal shader for the assembly).
  Currently must be picked manually (Sun presets still ship with the older
  `multiAPGrid: 0` setting pending Hα prominence verification).
- **Live file-size refresh in the Inputs list** — a 5 s poller re-stats every
  catalog file. The size column ticks up while SharpCap (or another capture
  tool) is still writing to disk / NAS, and the row visibly indicates the
  upload-in-progress state: dimmed text, an orange upload arrow next to the
  filename, and the size in orange. When the size stops changing (one poll
  with no growth), the row flips back to normal — that's the "OK to start
  stacking now" signal. Cost is one stat() per Inputs file every 5 s
  (negligible even over a NAS share).
- **"If you like it — ☕ buy me a coffee" link** added to the splash footer
  next to GitHub / AstroBin (the modal About sheet already had it).
- **Drift correction (opt-in)** for slowly-drifting planets. When a long
  capture's planet wandered across the frame, enable "Drift correction
  (planet wandered)" in the Lucky Stack section (CLI `--drift-correct`).
  It aligns by the background-subtracted disc CENTROID instead of phase
  correlation — robust for a bright disc that drifts, and used for both
  the reference build and the final per-frame shifts so the reference
  can't ghost either. Default OFF (always-on perturbed the F3 baselines).
  Note: this needs a reasonably-exposed disc; it can't rescue a very
  low-contrast capture where the planet barely stands out from a bright
  sky (the alignment is data-limited there — fix it capture-side with
  more exposure / darker sky / shorter sub-captures).
- **Stop button in the stacking progress overlay** (2026-05-22). Aborts an
  in-flight lucky stack — the engine polls cancellation per frame, drains
  its staging semaphore cleanly, removes any partial output, and resets
  the UI immediately.
- **Resizable preview / file-list split** — drag the divider between the
  preview and the file list; defaults now favour the preview.
- **Stacked outputs are never overwritten** — when a file of the same
  name already exists, the new stack is numbered up (`name_1.tif`,
  `name_2.tif`, …) so repeated stacks of the same source with different
  settings sit side-by-side for comparison.

### Changed
- **SER scrubbing is now live** while dragging the frame slider (was: only
  updated on release). The scrubber is a custom drag-gesture control — the
  old NSSlider ran a modal tracking loop that blocked CoreAnimation from
  presenting the Metal preview — backed by a synchronous decode + forced
  redraw and a monotonic seq guard so fast scrubs don't flicker backwards.
- **Info HUD defaults OFF** — the stats overlay no longer covers the image
  on open; toggle it with the "i" button.
- **Sun presets retuned** from a 10-run headless stacking benchmark:
  Sun — Granulation and Sun — Hα Prominence now stack with NO multi-AP +
  sigma-clip (Granulation also drops to keep 20%). Dense multi-AP was
  shown to smear low-contrast solar surface and warp the limb.
- **Outputs land next to the data.** Folder-watch writes
  `<watchedFolder>/_luckystack`; a folder open writes
  `<openedRoot>/_AstroSharper`. The sandbox container is now a transient
  last-resort only (no longer "sticks").

### Fixed
- **Multi-AP smearing / blocky limb on low-contrast solar surface.** New
  aperture-rejection gate in the AP-shift kernel: a cell earns a local
  shift only when the SAD minimum is well-defined in BOTH axes (a real 2D
  feature). The smooth solar limb (an aperture-problem valley) and flat
  granulation cells fall back to global alignment. F3 confirms Jupiter
  multi-AP unaffected.
- **Crash stacking / scrubbing very large SERs (23–26 GB)** whose header
  over-reports its frame count. New `SerReader.readableFrameCount` clamps
  every frame loop (scrub, grade, accumulate, AutoAP, per-channel) to the
  frames actually present in the mapped data; the scrubber stops at the
  last truly-readable frame instead of freezing.

### Changed
- **AutoNuke button reads "AutoNuke is ON" / "AutoNuke is OFF"** so the
  current state is unambiguous at a glance.
- **Explicitly picking a preset now re-activates its section toggles.**
  Choosing a target chip or a preset from the menu honours the enable
  flags the preset saved (Sharpen / Tone Curve / Stabilize, plus the
  noise / wavelet sub-flags) — so picking "Sun" actually turns on the
  sections that preset needs. Auto-apply on file open / scroll / folder
  watch still preserves the user's session toggle states (a file change
  never silently flips a section back on). New `applyPreset(_:userInitiated:)`
  distinguishes the two paths.

### Fixed
- **Crash when fast-forwarding / scrubbing a SER whose header overstates
  its frame count** (truncated copy or a capture still being written).
  `SerReader.withFrameBytes` guarded truncation with a `precondition` — a
  fatal trap that the prefetcher's `try?` can't catch — so a speculative
  prefetch past the real end of the file killed the whole app on the
  `serPrefetch` queue. New `SerReader.canReadFrame(at:)` does a cheap
  data-length check and `SerFrameLoader.loadFrame` now throws a catchable
  error for missing frames, so they're skipped instead of crashing.

### Changed
- **Folder-watch control moved to the top toolbar** (next to Open). It
  has to be reachable on an EMPTY capture folder before the session
  starts, but the Lucky Stack section is SER-gated and disabled when no
  files are present — so the control lived somewhere unusable. Now a
  compact toolbar button (Watch / green watching-capsule + stop).
- **Folder watch no longer interrupts the unattended flow with the
  community-share prompt.** The share decision is made ONCE when arming
  the watch (Auto-share / Don't share), then honoured silently for the
  session — skipped entirely when community share is globally disabled.
- **Inputs list auto-refreshes during folder watch.** New captures merge
  into the Inputs file list on switch-into-Inputs and live while viewing
  it, so you no longer have to re-open the folder to see them. Append-only
  — existing selection / marks / preview survive.

### Added
- **Folder watch + auto-stack** (LSW 5.2 "realtime" parity, 2026-05-22).
  Point AstroSharper at a SharpCap / FireCapture capture folder and it
  stacks each new SER the moment its capture finishes — leave it running
  overnight and wake up to stacked TIFFs. New `Engine/IO/FolderWatcher`
  (kqueue `DispatchSource` on the folder fd) + pure-Swift
  `WatchStabilityTracker` (size-stable completion detection, so half-
  written SERs are never stacked). Existing files at start are snapshotted
  as "seen" (backlog ignored); each new file is auto-stacked one-at-a-time
  through the existing lucky-stack queue with its target auto-detected from
  the filename (falling back to the active preset). Session-only —
  explicit Start / Stop, no auto-resume on launch. UI lives in the Lucky
  Stack section (`FolderWatchControl`).
- **LSW 6.21.1 parity wave** (2026-05-21) — five LuckyStackWorker User Manual
  gaps closed under the Quality + Speed + minimal-user-action filter:
  - **Highlight-clipped overlay** (LSW 8.8). Toolbar toggle, keyboard shortcut
    `C`. Tints per-channel ≥ 0.995 pixels solid red over the preview so polar
    overexposure / Wiener overshoot is visible at a glance. Saved files
    unaffected.
  - **Pre-sharpen highlight suppression** (LSW 3.1.3). Hue-preserving tanh
    roll-off above knee 0.85 fires in the AutoPSF post-pass when the bare
    stack's p99 ≥ 0.98. Default ON; fixes the long-open upper-half
    over-exposure on stacked Jupiter output. CLI `--no-pre-sharpen-suppression`
    + `--pre-sharpen-knee N`.
  - **Channel-Normalize** (LSW 7.2.1). Per-channel histogram stretch aligning
    [p1, p99] windows on the green reference. Auto-engaged for OSC sources
    via `OscDefaults.applyDefaults` as a sibling of `autoWB`.
  - **Synthetic-PSF cascade fallback** (LSW 3.2.1). `AutoPSF.estimateCascade`
    gains a seeing-index-driven Gaussian fall-through after planetary +
    auto-ROI both bail. Default OFF per the lunar-bail lesson; opted in via
    CLI `--synthetic-psf --seeing-index N` (Meteoblue 1–5 scale).
  - **Purple-fringe auto-suppression** (LSW 7.1). Hue-targeted desaturation
    around 290° with cos² falloff over ±30°. Auto-engaged on OSC sources
    alongside autoWB + channelNormalize.

### Fixed
- **Output tab post-Apply lands on the newest file** instead of the
  alphabetically-first one. `scanOutputFolder` now sorts by
  `contentModificationDate` so Apply Sharpen / Apply Tone Curve runs select
  + preview the file the batch just wrote, not a leftover from an earlier
  session.
- **Mouse-pan Y-axis inversion**. Dragging up no longer drives the image
  down. AppKit's bottom-up `+Y` mouse delta now pairs with the shader's
  top-down UV via `panPx.y = startOffset.y + delta.y` (X stays
  `- delta.x`); hand-tool semantics restored on both axes.
- **`batchTargetIDs` preview-file fallback**. Run Lucky Stack no longer
  requires an extra click when a single file is already shown in the
  preview — `previewFileID` is treated as the implicit target if nothing
  is marked or selected. Precedence stays `marked > selected > preview`.

- **AVI / MOV / MP4 / M4V lucky-stack** (E.1 SourceReader-driven LuckyRunner).
  `LuckyRunner` now consumes the `SourceReader` protocol instead of being
  hard-wired to `SerReader`. SER captures keep the zero-copy mmap fast path
  via the cached `serFastPath` reference; non-SER readers feed the runner
  with their own `loadFrame(at:device:)` implementation (AVI today via
  `AVAssetImageGenerator`, FITS multi-frame later). Per-channel stacking
  (Path B) still gates on Bayer SER since AVI sources arrive
  pre-debayered.
- **Coffee support dialog** is now enabled for v0.4.0 first-public-release
  cohort. Cadence (every Nth launch + minimum interval) is gated inside
  `CoffeeSupportDialog.presentIfDue` itself.

### Changed
- CLI `astrosharper stack` accepts `.avi / .mov / .mp4 / .m4v` in addition
  to `.ser`.
- **"Pick a target first" warning** moved from the small status-bar error
  to a big red banner over the preview. Auto-engages whenever SER input is
  loaded but no target preset is active; auto-clears the moment a target
  chip is clicked. `allowsHitTesting(false)` so it never blocks the
  preview underneath.

### Internal
- `project.yml` pins `ARCHS = arm64` + `EXCLUDED_ARCHS = x86_64`. Engine
  code uses `Float16(bitPattern:)` which doesn't exist on Intel; without
  the lock, Release / Archive builds fail trying to compile the x86_64
  slice.
- Regression sweep: 6/6 BiggSky SER fixtures byte-identical after the
  `SerReader` → `SourceReader` migration. AVI smoke-test pending real
  capture fixtures.

## [0.4.0] — 2026-05-03

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
- **In-app update checker** (`App/UpdateChecker.swift`) — fetches a
  small JSON manifest from `raw.githubusercontent.com/joergs-git/
  AstroSharper/main/latest-release.json` on every launch + on demand
  via Help → "Check for updates…". Compares semver to the running
  `MARKETING_VERSION`; surfaces an alert with **Open release page**
  / **Direct download** / **Skip this version** / **Later** when a
  newer release exists. "Skip" remembers per-version in UserDefaults
  so a NEW release re-unblocks the prompt automatically. 5 s timeout,
  silent on failure. Anonymous GET — no machine UUID, no telemetry.
  See `memory/project_release_workflow.md` for the release procedure.
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
