# Lessons Learned

Patterns and gotchas captured from this project. Read at session start; append after every correction.

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
