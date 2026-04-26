# Lessons Learned

Patterns and gotchas captured from this project. Read at session start; append after every correction.

## [2026-04-26] — Share GPU helpers, cache temp textures by shape
- **Mistake:** `SharpnessProbe` was instantiated **per file** in the thumbnail loader. Importing 500 TIFFs created 500 probes + 500 Metal command queues + 500 destination-texture allocations. Per-call allocation in `compute()` also allocated fresh Laplacian-dest + stats-dest textures every single call — even though all SER frames in a scan share the same shape.
- **Rule:** For any small GPU helper used at high frequency (probe, stats, etc.), expose a `static let shared` singleton with its own command queue. Cache scratch textures by shape `(w, h, pixelFormat)` so the inner loop reuses allocations. Wrap the cache in `NSLock` if the shared instance can be touched from multiple `Task.detached` workers.
- **Applies to:** `Engine/Pipeline/QualityProbe.swift::SharpnessProbe.shared`. Pattern is reusable for any future MPS-backed metric.

## [2026-04-26] — Mouse model for any preview = AstroTriage's, copied verbatim
- **Mistake:** Twice "improved" the preview pan/zoom to my own scheme (plain drag = pan). User rejected both, asked for "exactly as astrotriage repo is showing it. e.g. photoshop style zoom".
- **Rule:** For preview viewers, **port** AstroTriage's `ZoomableMTKView` mouse model — anchored click-drag zoom on plain drag, ⌥-drag pan, double-click fit, anchored pinch zoom. Don't redesign.
- **Reference:** `/Users/joergklaas/Desktop/claude-code/AstroTriage-blinkV2/AstroTriage/UI/ImageViewerView.swift` lines ~410-650.
- **Applies to:** `App/Views/PreviewView.swift::ZoomableMTKView`.

## [2026-04-26] — MTKView for static previews must be on-demand, not free-spin
- **Mistake:** Default `isPaused = false; preferredFramesPerSecond = 60` made window-resize sluggish with a 4 K SER loaded — the display loop competed with AppKit's resize.
- **Rule:** For preview MTKViews, set `enableSetNeedsDisplay = true; isPaused = true`. Every mutation site already calls `needsDisplay = true`, so behaviour is unchanged but the GPU stops spinning idle.

## [2026-04-26] — Don't auto-run expensive per-file analysis
- **Mistake:** Auto-scanned SER quality on every file click — sample 64 frames + GPU pass per click. Browsing felt sluggish.
- **Rule:** For non-trivial per-file work: cache fingerprinted by (path → size+mtime), and add an explicit "Calculate X" button in the relevant UI. Static-image scoring is cheap enough to run-once-on-import + cache, but still cache.
- **Applies to:** `Engine/IO/QualityCache.swift`, `Engine/Pipeline/QualityProbe.swift`, `App/Views/PreviewStatsHUD.swift`'s "Calculate Video Quality" button.

## [2026-04-26] — Scrub lag was a stale "after" texture, not slow decode
- **Mistake:** Scrubbing SER frames felt laggy. First instinct was decode/upload speed, but the decode is sub-millisecond.
- **Root cause:** `loadCurrentSerFrame` only updated `beforeTex`; the user was viewing `afterTex` (sharpened), which only refreshed when the heavy pipeline (sharpen + LR deconv + tone curve) completed.
- **Rule:** When swapping the source texture during a scrub, also drop `afterTex = nil` so the raw frame paints in the next display tick (~16 ms) and the sharpened version replaces it asynchronously.

## [2026-04-26] — Hide rather than show idle UI affordances
- **Mistake:** Flip-column rendered a grey icon on every row. Most rows aren't post-meridian — the icons were noise.
- **Rule:** Toggle controls that are off most of the time should render an invisible hit-target (preserves layout + click-toggle) and only become visible when on. Discoverability for the off→on path moves to the context menu.

## [2026-04-26] — SourceKit inline errors are stale during xcodegen file adds
- **Mistake:** Reacted to "Cannot find type 'AppModel'" diagnostics that the IDE surfaced after adding new Swift files via xcodegen.
- **Root cause:** SourceKit indexes lazily; xcodebuild was happy.
- **Rule:** After adding a file, regen with xcodegen and check `xcodebuild ... | grep -E "error:|BUILD"`. If `BUILD SUCCEEDED`, ignore SourceKit.

## [2026-04-26] — Apple Developer App ID capabilities ≠ entitlements
- **Mistake:** Told the user to tick "App Sandbox" on the Apple Developer App ID Capabilities list — it doesn't exist there.
- **Rule:** App Sandbox is an entitlement (set in `*.entitlements`), not an App ID capability. App ID Capabilities are the upstream services (iCloud, Push, etc.) that need server-side enablement.

## [2026-04-26] — Auto-managed Developer ID profile is enough for notarized GH releases
- **Mistake:** Tried to switch the project to manual signing referencing a hand-created `AstroSharper Developer ID` profile, broke archives ("No profile for team ... matching ... found").
- **Rule:** Xcode's auto-managed *"Mac Team Direct Provisioning Profile"* (created on first archive with `-allowProvisioningUpdates`) covers Developer ID notarization. No manual profile needed unless you have a deterministic-build constraint. Manual signing is for Mac App Store submission, not Developer ID.
- **Applies to:** `project.yml` `CODE_SIGN_STYLE`. Keep `Automatic`.

## [2026-04-26] — DC removal before Hann window for solar phase correlation
- **Mistake:** First-pass solar stabilization used straight Hann + FFT, with the result that the bright disc's DC component dominated the cross-power spectrum and the correlation peak drifted between frames.
- **Root cause:** Phase correlation normalises by magnitude, but the Hann window is centred at 0.5 amplitude — a frame with mean luminance ≠ 0 still has huge low-frequency energy.
- **Rule:** Subtract the mean from luminance buffers *before* Hann windowing whenever the subject is a high-DC scene (sun, moon, planet against dark sky).
- **Applies to:** `Engine/Pipeline/Align.swift` — both `phaseCorrelate` and `phaseCorrelateROI`.

## [2026-04-26] — Reference frame: never trust frame 0
- **Mistake:** Default `referenceMode = .firstSelected` produced jittery alignment because real captures often have poor seeing in the first second.
- **Rule:** Default to user-pinned reference (gold star, R key). When user hasn't pinned anything, fall back with a visible warning. Add a `.brightestQuality` mode that auto-picks by Laplacian variance for users who don't want to choose.
- **Applies to:** Stabilization UX. Same principle for Lucky Stack reference picking.

## [2026-04-26] — Stabilize must use memory textures when called from Memory tab
- **Mistake:** `Stabilizer.run` always re-loaded source files from disk, silently wiping any in-memory sharpening / tone-curve edits the user had applied.
- **Rule:** When the user has in-memory state (Memory tab + non-empty playback frames), pass the current textures to the sequence operator instead of forcing a disk reload. Also append to `appliedOps` rather than reset — the op trail is part of the user's mental model.
- **Applies to:** `Stabilizer.Inputs.preloadedTextures`, `AppModel.runStabilizationInMemory`.

## [2026-04-25] — Float TIFF thumbnails through 8-bit RGB context
- **Mistake:** ImageIO's default thumbnail path preserves Float16 sample values >1.0, so AstroSharper-written 16-bit float TIFFs came back as saturated white tiles.
- **Rule:** Always render thumbnails through an explicit 8-bit RGB CGContext to clamp [0,1] and normalise gamma. Pass `kCGImageSourceShouldAllowFloat` for the source decoder so it doesn't bail.
- **Applies to:** `Engine/FileCatalog.swift::ThumbnailLoader.load`.

## [2026-04-24] — Texture pool needs explicit recycling AFTER GPU completion
- **Mistake:** `Pipeline.recycle(borrowed)` was called immediately after encoding, before the GPU finished using the texture. Resulted in random pixel corruption when the pool reused an in-flight texture.
- **Rule:** Either `cmdBuf.waitUntilCompleted()` before recycling, or attach to `cmdBuf.addCompletedHandler { _ in pipeline.recycle(t) }`. Prefer the latter for async paths.
- **Applies to:** Anything that uses `Pipeline.borrow / recycle`.

## [2026-04-24] — Threadgroup memory must be initialised by ALL threads dispatched
- **Mistake:** `lucky_accumulate_with_shifts` SIGABRT'd on multi-AP grids >8×8 because only the first 64 threads zero-initialised the 1024-slot accumulator.
- **Rule:** When using threadgroup memory, init *every* slot regardless of how many threads are dispatched in the threadgroup — use a loop with `tid + i*threadgroup_size` covering all slots.
- **Applies to:** `Engine/Shaders/Shaders.metal` — anywhere `threadgroup` arrays live.

## [2026-04-24] — Dictionary mutation across actor boundaries needs a lock
- **Mistake:** `lumaCache` was a plain `Dictionary` mutated from both completion handlers and Task background reads. Crashed under load.
- **Rule:** Any shared mutable state accessed from multiple threads needs `NSLock` (cheap, simple) or actor isolation (more invasive). For simple key/value caches, NSLock is the right tool.
- **Applies to:** `Engine/Pipeline/LuckyStack.swift::lumaCache`, `Pipeline::pool`.

## [2026-04-23] — Sandbox writes need a probe, not a blind try
- **Mistake:** Naive `data.write(to:)` failed with NSCocoaErrorDomain 513 on NAS shares that *appear* writable but reject writes.
- **Rule:** Before committing to a write target, write a tiny temp file, then delete it. If that fails, fall back to the next level (auto folder → sandbox container).
- **Applies to:** `AppModel::resolveWritableOutputFolder`, anywhere we choose between user-picked and fallback paths.

## [2026-04-22] — Memory tab must clear preview cache on section switch
- **Mistake:** `PreviewCoordinator.loadCurrentFile` short-circuited when `playback.hasFrames`, so switching from Memory back to Inputs left the last memory texture on screen.
- **Rule:** Tie the early-return only to `displayedSection == .memory`, not to "memory has frames". Force `currentFileID = nil` on `displayedSection` changes to bypass the cache.
- **Applies to:** `App/Views/PreviewView.swift::loadCurrentFile`, `subscribe`.

## [2026-04-22] — Reset-on-toggle for sticky UI state
- **Mistake:** Section "expand" override stuck after the user toggled the section's enable switch — confusing "I turned it off, why is it still expanded" feedback.
- **Rule:** When a binary toggle resets the UX intent, clear any sticky local state at the same time. `onChange(of: isOn)` → reset `userExpanded`.
- **Applies to:** `SettingsPanel.SectionContainer`.

## [2026-04-21] — Match existing UX, never invent without asking
- **Mistake:** Replaced grey path bar with a borderless minimal one without checking — user wanted the original 12pt monospaced path retained but moved to status bar.
- **Rule:** Never change visible UX (colours, layout, copy) without explicit user request. If a refactor incidentally drops a UI element, point it out and ask before deleting.
- **Applies to:** All view code. Especially toolbar / status bar / section headers.

## [Forever] — User identity protection
- **Rule:** Use `joergsflow` everywhere in code, configs, commits. Never expose real name, hostname, address, or non-`joergsflow@gmail.com` email anywhere public-facing. The Apple Developer signing AppleID is used only inside Xcode signing dialogs — never written to files or commits.
- **Applies to:** `AppMeta.AppLinks`, README, CHANGELOG, every commit message.

## [Forever] — No emojis unless explicitly requested
- **Rule:** Default to no emojis in code, comments, commit messages. Marketing / README content can use them sparingly when the user explicitly asks for "marketing tone".
- **Applies to:** All written output.

## [Forever] — Read before edit
- **Rule:** Before any non-trivial edit, read all affected files, not just the entry point. SourceKit "cannot find type" warnings are usually false positives during a workspace cache rebuild — trust the actual `xcodebuild` output.
- **Applies to:** Every multi-file change.
