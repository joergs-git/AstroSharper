# Architecture

A short tour of how AstroSharper is wired together. Aimed at someone reading the code for the first time.

## Layered overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  SwiftUI Views    ContentView · SettingsPanel · FileListView ·       │
│                   BrandHeader (target picker) · SplashView ·         │
│                   CoffeeSupportDialog · StatusBar (opt-out icons)    │
├──────────────────────────────────────────────────────────────────────┤
│  AppModel         @MainActor, the single source of truth             │
│                   catalog · selection · marks · referenceID ·        │
│                   playback (memory) · sharpen / stabilize / tone     │
│                   settings · luckyStack (with autoNuke + autoAP) ·   │
│                   jobStatus · presets · pendingCommunityShare        │
├──────────────────────────────────────────────────────────────────────┤
│  Engine / Pipeline                                                   │
│   Sharpen   Stabilizer   LuckyStack   Wiener   Wavelet   Deconvolve  │
│   Align     ToneCurve    BatchJob     Pipeline (texture pool)        │
│   AutoPSF   AutoAP       APPlanner    LuckyStackPerChannel  Drizzle  │
├──────────────────────────────────────────────────────────────────────┤
│  Engine / IO     ImageTexture · SerReader · SerFrameLoader ·         │
│                   Fits · CaptureValidator · RotateTexture ·          │
│                   Histogram · Exporter                               │
├──────────────────────────────────────────────────────────────────────┤
│  Telemetry/Comm  MachineID · TelemetryClient · CommunityShare        │
│                  (opt-out, NSLog stubs — endpoint TBD per todo.md)   │
├──────────────────────────────────────────────────────────────────────┤
│  Metal           Compute kernels (Shaders.metal) · MPSGraph FFT ·    │
│                   shared MTLDevice / library / queue                 │
├──────────────────────────────────────────────────────────────────────┤
│  Accelerate      vDSP 2D FFT (phase correlation), Hann window        │
└──────────────────────────────────────────────────────────────────────┘
```

## Three-section model

The user always works in one of three sections. The same `FileListView` and `PreviewView` render whatever the active section's data is — no conditional UI.

```
   Inputs           Memory             Outputs
   ──────           ──────             ───────
   files on disk    aligned /          saved files
   (.ser .tif …)    sharpened          (_processed,
                    textures in RAM    _luckystack,
                    via playback       stabilized/, …)
                    .frames
```

`AppModel.displayedSection` switches between them; `stashedStates: [CatalogSection: CatalogSectionState]` parks the inactive section's catalog + selection so switching back is instant. `buildMemoryCatalog()` synthesises a virtual `FileCatalog` from `playback.frames` so the Memory tab reuses the same Table renderer.

## Pipeline order

Fixed order, applied per frame:

```
   Stabilize  →  Lucky Stack  →  Sharpen  →  Tone Curve
   (sequence)    (sequence)      (per-frame)  (per-frame)
```

Lucky Stack consumes a sequence and produces a single stacked frame, so it interrupts the chain. Stabilize also operates on a sequence but yields a same-length sequence.

The per-frame Sharpen + Tone-Curve pipeline lives in `Engine/Pipeline/Pipeline.swift`. It owns a small texture pool for ping-pong work (Lucy-Richardson iterations need it).

## Key files

| File | Responsibility |
| --- | --- |
| `App/AppModel.swift` | All app state. Marked `@MainActor`. Central command surface for views. |
| `App/AstroSharperApp.swift` | `@main`, `WindowGroup`, About / Help / View / Process menus. |
| `App/ContentView.swift` | Top-level layout (toolbar, HSplit settings/preview/list, status bar). |
| `App/Views/PreviewView.swift` | `MTKView` wrapper, zoom/pan gestures, ROI capture, Cmd-zoom shortcuts. |
| `App/Views/FileListView.swift` | Sortable Table, Mark / Reference-Star columns, R-key shortcut. |
| `App/Views/SettingsPanel.swift` | Collapsible sections (Lucky Stack, Stabilize, Sharpen, Tone, Output). |
| `App/Views/LuckyStackSection.swift` | Lucky-stack UI with mode picker, multi-AP grid, variants. |
| `Engine/Pipeline/Stabilizer.swift` | Sequence aligner — shifts, ROI, disc-centroid, crop. Now accepts pre-loaded textures. |
| `Engine/Pipeline/Align.swift` | Phase correlation (vDSP), ROI variant, disc-centroid, quality scoring. |
| `Engine/Pipeline/LuckyStack.swift` | Quality grading, top-N selection, multi-AP shifts, weighted accumulation, AutoAP integration. |
| `Engine/Pipeline/LuckyStackPerChannel.swift` | Path B per-channel Bayer stacking (chromatic-dispersion correction). |
| `Engine/Pipeline/AutoAP.swift` | Empirical AP-grid + patchHalf + drop-list resolver + multi-AP yes/no gate + feature-size cascade + kneedle keep-fraction. |
| `Engine/Pipeline/AutoPSF.swift` | Limb-LSF Gaussian σ estimator. Auto-bails on lunar / textured. |
| `Engine/Pipeline/APPlanner.swift` | Cell-LAPD + luma-cutoff scoring (drop-list + feature-size probe). |
| `Engine/Pipeline/Wiener.swift` | FFT-based Wiener deconvolution (per-channel). |
| `Engine/Pipeline/Deconvolve.swift` | Lucy-Richardson iterations (Metal). |
| `Engine/Pipeline/Drizzle.swift` | Drop splat reconstruction with AA pre-filter. |
| `Engine/Pipeline/Sharpen.swift` | Unsharp mask + à-trous wavelet sharpening. |
| `Engine/Pipeline/ToneCurve.swift` | Catmull-Rom spline → 1D LUT texture. |
| `Engine/Pipeline/BatchJob.swift` | File-level batch runner with cancel + progress events. |
| `Engine/Pipeline/Pipeline.swift` | Per-frame pipeline + texture pool. |
| `Engine/IO/SerReader.swift` | Memory-mapped SER reader (mono / Bayer, 8 / 16-bit). |
| `Engine/IO/SerFrameLoader.swift` | Single-frame extraction with GPU Bayer demosaic. |
| `Engine/IO/CaptureValidator.swift` | Parses fps / exp / gain from SER metadata strings (used by AutoAP gate). |
| `Engine/IO/Fits.swift` | FITS read + write. |
| `Engine/MetalDevice.swift` | Shared `MTLDevice`, `MTLLibrary`, `MTLCommandQueue` singleton. |
| `Engine/Shaders/Shaders.metal` | All compute and fragment kernels. |
| `App/MachineID.swift` | Stable random per-machine UUID (only identifying field in telemetry / community payloads). |
| `App/TelemetryClient.swift` | Opt-out anonymous telemetry payload + send stub. |
| `App/CommunityShare.swift` | Opt-out community thumbnail upload payload + stub. |
| `App/Views/BrandHeader.swift` | Headline bar + 6-target picker chips. |
| `App/Views/CoffeeSupportDialog.swift` | Floating NSWindow buy-me-a-coffee prompt (ported from AstroTriage). |
| `App/Views/SplashView.swift` | Welcome sheet on launch. |

## Data flow for a typical session

```
   user opens folder
      ↓
   FileCatalog.load()         scans dir, builds [FileEntry]
      ↓
   AppModel.catalog updated   FileListView re-renders
      ↓                        BrandHeader target picker re-detects
   user clicks Run Lucky Stack (or Apply to Selection ⌘R)
      ├── SER selected? → runLuckyStackOnSelection()
      │       → SerReader memory-maps frames
      │       → gradeAllFrames (Laplacian-variance compute kernel)
      │       → autoKeepPercent? → kneedle keep-% pick
      │       → topN frames selected
      │       → reference build (scientific: top-5% accumulator, lightspeed: argmax)
      │       → alignAgainstReference (vDSP 2D FFT phase correlation, parallel)
      │       → applyAutoAP (when autoAP != .off):
      │           · AutoPSF.estimate on reference luma
      │           · resolve grid + patchHalf + drop-list + tile-size
      │           · multi-AP yes/no gate from globalShifts variance
      │           · mutate options.{multiAPGrid, multiAPPatchHalf, useMultiAP, …}
      │       → accumulate (one of: standard, two-stage, drizzle, sigma-clip)
      │       → cropToCommonArea
      │       → optional bakeIn (Sharpen + Tone via Pipeline.process)
      │       → optional AutoPSF + Wiener + RFF post-pass
      │       → Exporter.writeTIFF → catalog.appendOutput
      │       → telemetry.recordStackCompleted (opt-out)
      │       → maybePromptCommunityShare (opt-out per-stack)
      │
      └── non-SER → applyToSelection() → BatchJob
              for each file:
                ImageTexture.load → Stabilizer (if N≥2)
                                  → Sharpen.process
                                  → ToneCurve.apply
                                  → Exporter.writeTIFF
                                  → status .done
```

Memory tab follows a parallel flow, but textures live in RAM and the same Pipeline functions are called in-place against `playback.frames[i].texture`.

## Concurrency

- `AppModel` is `@MainActor`. All UI mutation runs on the main thread.
- Long-running work uses `Task.detached(priority: .userInitiated)` and pushes results back via `await MainActor.run { … }` or `@MainActor` callbacks.
- Texture pool (`Pipeline.borrow / recycle`) is `NSLock`-protected so completion handlers can recycle from any thread.
- Phase correlation parallelises across frames with `DispatchQueue.concurrentPerform`.
- The `lumaCache` in `LuckyStack` is `NSLock`-protected — earlier versions raced and crashed.

## File formats

| Read | Write |
| --- | --- |
| TIFF (8 / 16-bit, RGB / RGBA, Float16) | TIFF 16-bit float (default) |
| PNG, JPEG | PNG, JPEG |
| SER (mono + Bayer, 8 / 16-bit) | — |
| AVI (catalog only — full demux pending) | — |

All in-engine textures are `rgba16Float` to keep Lucy-Richardson iteration numerically stable and tone-curve LUTs precise.

## Sandbox + persistence

- Output folder picker creates a security-scoped bookmark in `UserDefaults`. Re-opened on every launch.
- If the picked folder is unwritable (NAS, removed drive), AstroSharper auto-falls back through: picked → auto `_AstroSharper` next to inputs → sandbox container `Documents/AstroSharper Outputs`.
- Presets sync via `NSUbiquitousKeyValueStore` (iCloud), so the same Sun preset shows up on a second Mac.

## Build system

- **XcodeGen** — `project.yml` generates `AstroSharper.xcodeproj`. Re-run `xcodegen generate` after structural changes.
- **No SPM dependencies** — everything's stdlib + system frameworks (SwiftUI, AppKit, Metal, MetalPerformanceShaders, MetalPerformanceShadersGraph, Accelerate, ImageIO, CoreImage, AVFoundation).
- **Sandbox + Hardened Runtime** are on by default — required for App Store distribution.

## Adding a new operation

1. Add settings struct + Codable conformance (mirror `SharpenSettings`).
2. Add `@Published var myOp = MyOpSettings()` to `AppModel`.
3. Write a Metal kernel in `Shaders.metal` and a Swift wrapper in `Engine/Pipeline/MyOp.swift`.
4. Add a `MyOpSection` to `SettingsPanel.swift` with a `SectionContainer`.
5. Wire it into `Pipeline.process(input:sharpen:toneCurve:…)` so it runs per-frame.
6. Optionally expose a `runMyOpOnActiveSection()` action on `AppModel` for the section's hero button.

That's the whole map.
