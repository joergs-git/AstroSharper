# Lessons Learned

Patterns and gotchas captured from this project. Read at session start; append after every correction.

## [2026-05-03] — Pin `ARCHS=arm64` in `project.yml`, not just at the xcodebuild invocation
- **Mistake:** During the v0.4.0 release pipeline, the first Release-config build failed with `Float16` errors because Xcode tried to compile both arm64 and x86_64 slices. The arm64-only rule existed in memory (`feedback_arm64_only.md`) but only as a per-invocation flag — XcodeGen-generated targets had no architecture lock baked in.
- **Rule:** Bake architecture lock into `project.yml` `settings.base` (`ARCHS / ONLY_ACTIVE_ARCH / VALID_ARCHS / EXCLUDED_ARCHS`) so any subsequent `xcodebuild ... archive` cannot accidentally cross-compile the unsupported slice. A flag the human has to remember every time is a flag they will forget every other time.
- **Applies to:** Any project where one architecture has compile-only language features (e.g. `Float16`, NEON intrinsics, Apple-Silicon-only Metal types) — pin in `project.yml`, not in the build scripts.

## [2026-05-03] — Probe common `notarytool` keychain profile names instead of asking
- **Mistake:** First attempted `notarytool submit --keychain-profile AstroSharper` (matching the project name) and got "No Keychain password item found for profile" — was about to ask the user. Trying common patterns (`AC_PASSWORD`, `notarytool`, project / brand names) takes <5 s per probe and `xcrun notarytool history --keychain-profile <name>` fails fast for wrong names.
- **Rule:** When a credential profile name is unknown, probe a short list of common patterns (`AC_PASSWORD` is the Apple-docs default) before bouncing back to the user. Each failed probe costs ~1 s; user round-trip costs minutes.
- **Applies to:** `notarytool / altool / xcrun` keychain profiles, `aws --profile`, `gh auth token` lookups, any tool with a named credential set.

## [2026-05-03] — `Color.clear.frame(width:)` defaults to fill all available height
- **Mistake:** Used `Color.clear.frame(width: 260)` as a right-side balancer in BrandHeader to keep the target picker centered. Without an explicit `height:`, Color claimed all available vertical space — the brand bar inflated to ~150 pt of empty grey.
- **Rule:** Any `Color.clear` placeholder used as a layout spacer needs an explicit `height: N` (use `1` for a near-zero footprint). Combine with `.frame(height:)` on the outer container as a hard cap — child intrinsic sizes can never push past it.
- **Applies to:** `App/Views/BrandHeader.swift` and any future SwiftUI bar / strip layout that needs invisible spacers.

## [2026-05-03] — `JSONEncoder` omits nil optional keys; some servers require them present-with-null
- **Mistake:** `TelemetryEvent` and `CommunityShareMetadata` used default Codable synthesis with `Optional<T>` fields. Swift's encoder OMITS the key entirely when nil; the Supabase edge functions' validators required the key present (with `null`) and returned HTTP 400 for missing keys.
- **Rule:** When the wire format requires `"field": null` for absent values (e.g. strict server validators, or downstream consumers that compute over a fixed schema), provide a manual `encode(to:)` that uses `container.encode(value, forKey:)` — that path emits null for nil values. The default synthesised version uses `encodeIfPresent` which skips them.
- **Applies to:** Any future Codable struct on the network boundary. Server-side: tolerate both forms (`null` and missing) defensively to avoid this kind of round-trip failure.

## [2026-05-03] — Sandboxed app needs `com.apple.security.network.client` to even resolve DNS
- **Mistake:** Added telemetry + community share HTTP POSTs without updating the entitlements file. The app sandbox blocked `mDNSResponder` on first network call → URLSession returned `-1003 ServiceNotRunning` → "Telemetry POST failed: A server with the specified hostname could not be found."
- **Rule:** Adding ANY outbound HTTP to a sandboxed app requires `com.apple.security.network.client = true` in the entitlements file. Without it the failure is misleading (looks like DNS, is actually sandbox blocking the resolver). The Sandbox `deny network-outbound /private/var/run/mDNSResponder` log line is the definitive smoking gun.
- **Applies to:** `AstroSharper/AstroSharper.entitlements`. The entitlement is the FIRST step before any URLSession code, not an afterthought.

## [2026-05-03] — Nested SwiftUI View body has a finite type-check budget
- **Mistake:** Inlining the third alert (update checker) into the existing `WindowGroup` body that already had 2 sheets + 2 alerts + 3 observers triggered SwiftUI's "expression too complex" compile error. Symptom is a build failure on a body that LOOKS reasonable; root cause is the generic resolver giving up on the modifier chain.
- **Rule:** Whenever a `body` chain accumulates ≥3 `.alert` / `.sheet` calls or has multiple `Binding(get:set:)` constructions, extract into a dedicated wrapper View with its own `body`. Per-button `@ViewBuilder` helper methods further reduce per-call complexity. The compile failure is reversible by refactoring; don't disable `-Xfrontend` flags as escape hatches.
- **Applies to:** `App/AstroSharperApp.swift::RootContent` is the canonical extraction pattern. Re-use for any future top-level App view.

## [2026-05-03] — Don't inject tone manipulation into "preview thumbnail" exports
- **Mistake:** Added 1%/99% percentile auto-stretch + γ 2.2 to `CommunityShare.makeThumbnailJPEG` to make bare-accumulator outputs visible in the feed. On properly-toned outputs (lunar surface stacks), the stretch crushed natural midtones and the community feed showed high-contrast over-processed "negatives" of what the user actually saved.
- **Rule:** A "thumbnail" of a saved file should be a faithful downscale of the saved bytes — never re-tone, never re-balance. If the source is dark, the thumbnail is dark; that's the truth. Push the tone decision to the saved-file pipeline (Bake-in / Auto-tone toggles), not to the export step.
- **Applies to:** `App/CommunityShare.swift::makeThumbnailJPEG`. Same principle for any future "send a preview elsewhere" path.

## [2026-04-27] — Lucky-stack accumulator must be 32-bit float, not half-precision
- **Mistake:** Used `rgba16Float` for the stacked-output accumulator (and the drizzle accumulator). With ~10 bits of mantissa in the 0..1 mid-range, weighted-mean accumulation across hundreds of frames + a final unsharp+wavelet pass surfaced as visible colour banding on smooth Jupiter cloud detail. Existing comments warned about this for the sigma-clip Welford state, but the standard / two-stage / drizzle paths missed the upgrade.
- **Rule:** Any pipeline stage that *accumulates* across many frames must use `rgba32Float` (single precision). Half-precision is fine for pass-through textures (per-frame sharpen output, display blits) but never for the running mean / weighted sum / variance state. Memory cost: 2× per accumulator — negligible on Apple Silicon.
- **Applies to:** `Engine/Pipeline/LuckyStack.swift::makeAccumulator`, drizzle accumulator. Same principle for any future blind-deconv / tiled-deconv accumulators.

## [2026-04-27] — No auto-probe on file/frame switch in interactive UI
- **Mistake:** Both `loadCurrentFile` and `loadCurrentSerFrame` ran `SharpnessProbe.compute` on the freshly-loaded full-resolution texture so the HUD showed a "current sharpness" number. At source resolution that's 5–30 ms per click — bearable on one file, unbearable when fanning through a folder of large SERs or holding next-frame.
- **Rule:** Anything more expensive than ~1 ms must NOT auto-run on routine UI navigation (file selection, frame scrub). Wire it behind an explicit "Calculate / Analyze" button (the SER distribution scanner already does this — pattern to follow). Acceptable to compute for cached entries on-disk in a background pass once at import; never on every click.
- **Applies to:** `App/Views/PreviewView.swift`, future per-frame probes (HFR sparkline, jitter score, capture validator on scrub). Same principle for any new "show me a metric" UI.

## [2026-04-27] — Anchored-zoom math is per-axis, not isotropic
- **Mistake:** Ported AstroTriage's `anchoredZoom` using a single `baseFit = min(viewW/texW, viewH/texH)` for both axes. The display shader uses **per-axis** `fitScale.x` / `fitScale.y` (different when image and view aspect ratios differ), so the pan-compensation has the wrong magnitude on at least one axis — large enough that the user perceives it as a sign flip ("left is right, up is down").
- **Rule:** Any anchor-preserving viewport math must read the SAME fit-scale convention the shader uses. Compute `tex pixels per view pixel` per axis as `tpv_axis = texSize_axis / (viewSize_axis * fitScale_axis)`, then `panPx_new = panPx_old + relAxis * tpv_axis * (1/oldZ − 1/newZ)`.
- **Applies to:** `App/Views/PreviewView.swift::ZoomableMTKView.anchoredZoom`. Sign convention notes already in place in the file's comments.

## [2026-04-27] — Lucky-keep-% can't be a pure spread heuristic
- **Mistake:** `SerQualityScanner.makeDistribution` derived the recommended keep fraction from `p90/p10` alone, defaulted to 75% for "tight" distributions. Result: even objectively bad SERs got a 75% recommendation, which contradicts every lucky-imaging best practice.
- **Rule:** The recommendation must (a) anchor in scientific-lucky-imaging norms (planetary 1–15%, solar 10–30%, lunar 5–25%), (b) enforce an absolute floor on the *kept frame count* (~100 frames; SNR ∝ √N), and (c) detect the sharpness "knee" via percentile, not just `p90/p10`. Always display both the percentage AND the absolute frame count so the user can sanity-check.
- **Applies to:** `Engine/Pipeline/QualityProbe.swift::SerQualityScanner.makeDistribution`. Validate against `TESTIMAGES/` before declaring the formula correct.

## [2026-04-26] — Share GPU helpers, cache temp textures by shape
- **Mistake:** `SharpnessProbe` was instantiated **per file** in the thumbnail loader. Importing 500 TIFFs created 500 probes + 500 Metal command queues + 500 destination-texture allocations. Per-call allocation in `compute()` also allocated fresh Laplacian-dest + stats-dest textures every single call — even though all SER frames in a scan share the same shape.
- **Rule:** For any small GPU helper used at high frequency (probe, stats, etc.), expose a `static let shared` singleton with its own command queue. Cache scratch textures by shape `(w, h, pixelFormat)` so the inner loop reuses allocations. Wrap the cache in `NSLock` if the shared instance can be touched from multiple `Task.detached` workers.
- **Applies to:** `Engine/Pipeline/QualityProbe.swift::SharpnessProbe.shared`. Pattern is reusable for any future MPS-backed metric.

## [2026-04-26] — Mouse model for any preview = AstroTriage's, copied verbatim
- **Mistake:** Twice "improved" the preview pan/zoom to my own scheme (plain drag = pan). User rejected both, asked for "exactly as astrotriage repo is showing it. e.g. photoshop style zoom".
- **Rule:** For preview viewers, **port** AstroTriage's `ZoomableMTKView` mouse model — anchored click-drag zoom on plain drag, ⌥-drag pan, double-click fit, anchored pinch zoom. Don't redesign.
- **Reference:** AstroTriage repo, `AstroTriage/UI/ImageViewerView.swift` (`ZoomableMTKView`, lines ~410-650).
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

## [2026-04-29] — Don't feed coalesced retries back through the same Combine subject
- **Mistake:** When the live-preview pipeline took longer than the 33 ms throttle interval, an in-guard `reprocessSubject.send(())` retry from `PreviewCoordinator.reprocess` fed BOTH the throttle subscriber AND a newly-added 200 ms debounce subscriber. The debounce timer kept resetting on every retry-send, the throttle kept re-firing while `inFlight` was true, and each pipeline cycle kicked off another one — "Processing" spinner + section pulsing ran forever even when the user wasn't touching anything.
- **Root cause:** Multiple subscribers on a single `PassthroughSubject` mean a single `.send(())` reaches all of them. Self-sends from inside a sink create feedback loops that compound when the work outside the sink takes longer than the throttle interval.
- **Rule:** When a sink needs to "queue another pass after the current one finishes", don't `subject.send` back into the same subject. Use a coalesced state flag (e.g. `pendingPreview: Bool?`) on the coordinator and drain it directly when the current run lands. Direct re-call from the completion block doesn't poke any Combine subscribers awake.
- **Applies to:** `PreviewView.PreviewCoordinator.reprocess`. Pattern generalizes to any Combine sink with a busy-retry path.

## [2026-04-29] — Always-on auto-recovery needs a histogram-shape gate, not a percentile clamp
- **Mistake:** Shipped a stack-end histogram remap that ran unconditionally (1%/99% percentile → [0, 0.97] linear). Lunar / solar / textured subjects fill the histogram natively; on those the remap pushed already-wide range to extremes. Output was crushed shadows + blown rims — same "unnatural over-contrast" failure mode the old user-facing autoStretch toggle had.
- **Root cause:** Treated mean-stacking compression as universal. It's only universal for *dark-dominated* histograms (planet on dark sky); *mid-tone-dominated* histograms (lunar terrain, solar disc) start full-range so any stretch over-shoots.
- **Rule:** For an always-on tonal recovery, gate on the input's median luminance (or a similar histogram-shape signal), not just on percentile spread. Threshold: median ≥ 0.30 → skip remap (data already fills range); median < 0.30 → apply (planet on sky, compression to undo).
- **Applies to:** `Pipeline.applyOutputRemap`. Pattern generalizes to any "fix the obvious failure mode" auto-recovery — confirm the failure mode actually applies before touching the data.

## [2026-04-29] — Eager-compile MTLComputePipelineState in init
- **Rule:** Lazy `MTLComputePipelineState` building is ~5–8 ms per kernel on Apple Silicon. With 14 kernels in `Pipeline`, the first slider drag eats an 80–100 ms hiccup. Move all PSOs to immediate construction in `Pipeline.init` — the cost shifts onto app launch (covered by the SwiftUI splash) and the live preview is smooth from tick zero.
- **How to apply:** When init needs to run a closure that touches `self.device`, capture the device into a local FIRST and have the helper closure reference the local. Otherwise Swift errors with "self used before all stored properties are initialized".
- **Applies to:** `Engine/Pipeline/Pipeline.swift`. Same pattern in any future Metal pipeline class with multiple PSOs.

## [2026-04-29] — Test before building manual UI
- **Mistake (avoided):** Saw a BiggSky note about Saturn using 28 *manually placed* APs and almost spec'd a manual AP placement UI for v1.
- **Rule:** Before committing to a manual-UI feature that mirrors a manual workflow in another tool, run a regression test with our automation against the manual reference. If automatic gets within 90% (or beats it), skip the UI; if not, build it. Saved the work after a 13-line python script showed our auto-grid 6×6 (36 APs) hits 1.13× the LAPD sharpness of BiggSky's 28 manual APs on the same Saturn SER (after histogram normalization).
- **Applies to:** Any "users in tool X do this manually, should we expose a knob?" decision.

## [2026-04-29] — CLI prints can drift from real behavior
- **Mistake:** `cli/Stack.swift` printed `keep=\(plan.percent)%` after a stack run, which reported the *configured* keep% rather than the *resolved* one. Under `--auto-keep`, the actual stack used a 75% recommendation (correct, NSLog'd) but the print said 25% — looked like the auto-keep flag wasn't applied. It was; only the print was wrong.
- **Rule:** When an option re-resolves a value at runtime (auto-keep, auto-PSF, auto-keep-count, …), the user-facing print should reflect what was actually used, not what was passed in. Annotate the mode (`(auto-keep)`) so the discrepancy is explained.
- **Applies to:** Every CLI summary line. Same lesson applies to GUI status badges that surface a derived value.
