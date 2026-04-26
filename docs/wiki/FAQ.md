# FAQ

### Why a new app instead of porting AutoStakkert! / ImPPG / Registax?

Three reasons:

1. **None of them are Mac-native.** ImPPG is wxWidgets via a clunky port; AutoStakkert! and Registax are Windows-only. AstroSharper is Swift + Metal from the ground up.
2. **Apple Silicon performance.** Metal compute kernels and `MPSGraph` FFT outperform any CPU-based pipeline by 5–20× on M-series Macs.
3. **UX.** The competing tools are 1990s "wizard with separate file dialogs". AstroSharper is one window, three sections, one hero button.

### Will AstroSharper read my old AutoStakkert! settings?

No, but the presets cover the same target/mode space. Pick the preset closest to what you used in AS3, tweak the sliders, save it as your own preset.

### How does it compare to PixInsight for solar / planetary?

PixInsight is a deep-sky toolkit with planetary as an afterthought. AstroSharper is the inverse — solar / lunar / planetary are the entire focus, deep-sky stacking is out of scope. Use both: AstroSharper for the stack + sharpen, PixInsight for any further deep-sky-style processing.

### Can I use it for deep-sky stacking?

Not in v1. The lucky-imaging quality grader expects high-frame-rate captures with seeing-limited variation between frames. Deep-sky exposures are minutes long and need calibration frames (darks/flats/bias) which AstroSharper doesn't handle. Use Astro Pixel Processor or PixInsight for deep-sky.

### How big a SER can it open?

The reader is memory-mapped, so the file size doesn't matter — only the per-frame size does. Tested up to 30 GB SERs. The whole-stack memory budget depends on the keep-percentage; at 25 % a 4K-frame 5000-frame SER needs ~5 GB RAM during stack.

### Does it work on Intel Macs?

It builds and runs on Intel macs running macOS 14+, but `MPSGraph` FFT and the Metal kernels are tuned for Apple Silicon. Performance on Intel will be 3–5× slower. Officially we test on M-series only.

### Why the "Marked" reference mode as default?

Previous default was "First Selected" — fine if your selection is already in quality order. Real captures have great frames in the middle of the sequence, not at the start. "Marked" forces the user to make a one-keystroke choice (`R`), and that choice is dramatically more impactful than any other Stabilize setting.

### Does the app upload anything?

No telemetry, no analytics, no network calls (except when you click GitHub / App Store / Buy Me A Coffee links). Everything runs locally.

### Can I scriptable / batch from the command line?

Not in v1 — that's an explicit non-goal. The whole pitch is "one window, no scripts". If you need scripted batching, the file-batch flow combined with `Apply ALL Stuff` does the job interactively in seconds.

### How is iCloud sync handled?

User presets sync via `NSUbiquitousKeyValueStore`. Sandbox-safe, no extra entitlements, no manual setup. If iCloud is off, presets fall back to local `UserDefaults`.

### Can I add my own preset?

Yes — Save as New Preset… in the preset menu. Capture all current sliders, tag with a target (sun / moon / planet / other) and notes. iCloud-synced automatically.

### Does it support Hα / SII / OIII narrowband?

Yes for the imaging pipeline (it's grayscale or Bayer-RGB indistinguishable). No for narrowband-aware operations like channel combine (out of scope). Process each filter's stack separately, combine in PixInsight or Photoshop.

### Can I help?

Yes:

- ⭐️ Star the repo
- ☕️ [Buy me a coffee](https://buymeacoffee.com/joergsflow)
- 📝 Leave a review on the App Store when it lands
- 🐛 Open issues with reproducible bugs
- 🛠️ PRs welcome — read [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) first
