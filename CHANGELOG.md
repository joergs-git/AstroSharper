# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows semantic versioning once it leaves 0.x.

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

_Nothing yet — track new work here._

## [0.2.0] — 2026-04-25

Initial brand identity, About panel, How-To window, app icon, version display.

## [0.1.0] — 2026-04-22

First runnable build: open folder, sharpening, basic stabilization, batch export.
