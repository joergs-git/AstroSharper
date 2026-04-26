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

## Pending — roadmap

### Near-term
- [ ] **Anchored-zoom drift on click-drag (BUG — open)** — During plain drag (Photoshop click-drag zoom), the image pixel under the cursor doesn't stay locked. User reports it as "left is right, up is down" — actually a magnitude error in the pan-compensation, possibly large enough to feel like a sign flip when texPerView ≠ baseFit.
  - **Root cause:** `anchoredZoom` in `App/Views/PreviewView.swift::ZoomableMTKView` uses an isotropic `baseFit = min(viewW/texW, viewH/texH)` and applies it equally to X and Y. The display shader (`Engine/Shaders/Shaders.metal`'s `display_fragment`) actually uses **per-axis** `fitScale.x` / `fitScale.y` — so `tex pixels per view pixel` differs from `baseFit` whenever the image+view aspect ratios mismatch.
  - **Correct math** (already derived; just needs implementation): For each axis define `tpv = texSize / (viewSize * fitScale_axis)` where the fitScale matches the shader's branch. Then for a zoom from `oldZ → newZ` with anchor offset `relX, relY` from view center: `panPx_new = panPx_old + relAxis * tpv * (1/oldZ − 1/newZ)`.
  - Reuses my existing sign convention (`+panPx.x` shifts image LEFT on screen; `+panPx.y` shifts image UP). ⌥-pan is correct, no change there.
  - Test cases: zoom in / out / in / out cycle on (a) large SER ≈3000² in landscape view, (b) tall TIFF 2000×4000 in landscape view — anchor should stay locked in both.

- [ ] **Lucky-stack keep-% recommendation is too lenient** — `Engine/Pipeline/QualityProbe.swift::SerQualityScanner.makeDistribution` always returns 75% even for bad captures. The current `spread = p90/p10` heuristic overweights tight distributions. Replace with a scientific-lucky-imaging-aware formula that also considers frame count.
  - **Research first:** AutoStakkert / Registax / scientific-lucky-imaging literature recommendations. Rough starting points to validate:
    - Planetary (Mars/Jupiter/Saturn): 1–15 % typically; high-resolution work uses 1–5 %.
    - Solar (Hα / WL): 10–30 % when seeing is steady; 5–15 % when turbulent.
    - Lunar high-res: 5–25 %.
  - **Frame-count floor:** stack SNR is √N — keeping 5 % of 100 frames = 5 frames is unusable. Recommendation must enforce a minimum kept-frame count (≥ 100 typical, ≥ 50 absolute floor) — formula: `keepCount = max(absoluteFloor, ceil(idealFraction * total))`, then `keepFraction = keepCount / total`.
  - **Distribution-aware:** instead of bare p90/p10 ratio, compute the percentile threshold where sharpness drops sharply — e.g., the percentile *p* where `score(p) ≤ 0.5 × p90`. That's the meaningful "keep above this" cutoff.
  - **Jitter consideration:** keep current "tighten by one band on jitter > 15 px" but recalibrate the threshold against real captures.
  - **Display:** show both the percentage AND the absolute frame count (e.g. *"Recommend: keep top 8 % (160 of 2000 frames) — sharp tail well-defined."*).
  - **Validation:** run against the SERs in `TESTIMAGES/` before claiming the formula is right.

- [ ] AVI lucky-stack engine — currently the demuxer (`Engine/IO/AviReader.swift`) only feeds the preview / scrub / quality scanner. Lucky-Stack needs a `SourceReader` protocol abstraction over `SerReader` / `AviReader` so the tight read-loop in `Engine/Pipeline/LuckyStack.swift` can consume either.
- [ ] 16-bit histogram overlay on preview (currently using basic Histogram)
- [ ] Drizzle 1.5×, 2× reconstruction (C5 task)
- [ ] CompiledFFT path: re-enable MPSGraph phase correlator (currently disabled, vDSP CPU path is the active route)

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

### Mid-term
- [ ] FITS / RAW / DNG input
- [ ] Pre-stack calibration frames (darks / flats / bias)
- [ ] Folder watching (auto-batch on new files)
- [ ] Animated preview transitions (zoom-to-1:1 etc.)
- [ ] Color-aware tone curve (per-channel splines)
- [ ] Star-aware sharpening for deep-sky (out of scope for v1)

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

- **2026-04-26** (PM) — v0.3.0 ship: Preview HUD + sharpness probe + SER quality scanner + on-disk cache + sortable Type/Sharpness columns + filename filter + AstroTriage mouse port + flip-icon hide-when-off + MTKView on-demand redraw + native app icon. Public GitHub repo + notarized GH release.
- **2026-04-26** (AM) — Solar stabilization improvements: R-key reference, alignment modes, memory-texture path, DC removal. Full docs written.
- **2026-04-25** — D14 polish, inline player, thumbnail fix
- **2026-04-22** — D12 brand identity, About panel, How-To window
