# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows semantic versioning once it leaves 0.x.

## [Unreleased]

### Added
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

### Changed
- Stabilize boundary default is now **Crop** (was Pad).
- Default reference mode is now **Marked** — falls back to first-selected with a warning when nothing is pinned.
- Quality-weighted lucky stack uses gamma-shaped weights (`0.05…1.5`) for crisper Scientific stacks.
- Default playback fps is **18**.

### Fixed
- Sandbox NAS-write errors auto-fall back to the container Documents folder.
- Float-TIFF thumbnails now render normalised (no more blown-out white tiles).
- Memory tab no longer leaks a stale playback frame after backspace-delete.
- Lucky-stack threadgroup-memory race that caused `SIGABRT` on large multi-AP grids.

## [0.2.0] — 2026-04-25

Initial brand identity, About panel, How-To window, app icon, version display.

## [0.1.0] — 2026-04-22

First runnable build: open folder, sharpening, basic stabilization, batch export.
