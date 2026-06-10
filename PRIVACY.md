# Privacy Policy

**Effective Date:** June 9, 2026
**Developer:** joergsflow
**Contact:** joergsflow@gmail.com
**App:** AstroSharper (macOS)

---

## Summary

AstroSharper is a lucky-imaging app for the Sun, Moon and planets. All
image processing — quality grading, alignment, lucky stacking, sharpening,
deconvolution and tone editing — runs **entirely on your device**. No
personal information (name, email address, account, Apple ID, hostname) is
collected during normal use, and there is no user account.

Two optional features send a small amount of **anonymous** data to our
server (a Supabase project hosted in the EU region, Ireland `eu-west-1`):
anonymous usage telemetry and an opt-in community thumbnail share. Both are
described in detail below. There are no advertising, analytics or tracking
SDKs, and no data is ever used to track you across other apps or websites.

---

## What runs locally only

The following always stays on your device — no file contents, file paths,
file names or full-resolution pixel data ever leave your Mac for these:

- Reading SER / AVI / image files and SER Quick Look previews
- Quality grading, sharpness analysis, the on-disk quality cache
- Alignment, lucky stacking, drizzle, per-channel stacking
- Auto-PSF, deconvolution, wavelet sharpening, tone editing
- Folder-watch auto-stacking and all saved output files
- App settings and saved presets (UserDefaults)

---

## Anonymous Telemetry (default ON, opt-out)

To converge the engine's automatic defaults on what works across real
hardware and capture conditions, AstroSharper records one small event each
time a lucky stack completes.

**What is sent (the entire payload):**

| Field | Example | Notes |
|---|---|---|
| Random install ID | a UUID generated locally on first launch | **Not** derived from hardware; cannot be linked to you |
| Detected target | `jupiter` / `moon` / `sun` … or none | from the filename keyword only |
| Frame count, image width / height | `2000`, `1936×1216` | capture geometry |
| Measured PSF σ, AP grid, AP patch | technical engine numbers | used to tune auto-defaults |
| Alignment-shift variance, elapsed time | technical engine numbers | |
| AutoNuke on/off, app version, timestamp | `true`, `0.5.0`, ISO-8601 UTC | |

**What is never sent:** file names, file paths, telescope/camera names,
focal length, capture timestamps, IP-derived location, email, hostname, Mac
model, Apple ID, or any preset you saved.

**Where it goes:** a Supabase project in the EU region (Ireland, `eu-west-1`).

**Opt-out:** click the telemetry indicator in the bottom status bar of the
main window at any time. Once disabled, every send becomes an instant no-op —
no restart needed.

---

## Community Thumbnail Share (opt-in, off unless you confirm)

After a stack finishes, AstroSharper may ask whether you want to share a
small preview with the community feed. This only ever sends data when you
explicitly answer "Yes, upload" to that prompt.

**What is sent:** a JPEG thumbnail (max 800 px on the long edge — never the
full-resolution result), the detected target keyword, the frame count, and
the same random install ID described above.

**What is never sent:** the full-resolution image, file names or paths, or
any personal information.

You can turn the feature off permanently with the "Always off" button on the
prompt, or via the community indicator in the status bar.

*Note:* a shared thumbnail is a low-resolution picture of your result. Treat
it like any image you choose to publish.

---

## File Access

AstroSharper is fully sandboxed and only accesses files and folders **you
explicitly choose** — through the Open dialog, the folder picker, or the
folder-watch picker. Saved output files are written only to the location you
select (or, for folder-watch, a `_luckystack` subfolder of the folder you
pointed it at). The app never deletes your source files.

---

## Local Data Storage

| Data | Location | Purpose |
|---|---|---|
| App settings, presets | UserDefaults | Slider values, toggles, saved presets |
| Quality cache | `~/Library/Application Support/AstroSharper/quality-cache.json` | Skip re-scanning a capture you already analysed |
| Security-scoped bookmark | UserDefaults | Re-offer your last watch folder after relaunch |

None of this is transmitted.

---

## Third-Party Services

| Service | Purpose | Privacy Policy |
|---|---|---|
| Supabase | Stores anonymous telemetry and opt-in community thumbnails (EU region) | [supabase.com/privacy](https://supabase.com/privacy) |

No advertising, analytics or tracking SDKs are used.

---

## Children's Privacy

AstroSharper does not collect data from children under 13. It is designed
for adult astrophotography enthusiasts.

---

## Changes to This Policy

Updates will be posted on this page with an updated effective date.

---

## Contact

Questions about this policy, or want your shared data removed?

- **Email:** joergsflow@gmail.com
- **GitHub:** [github.com/joergs-git/AstroSharper](https://github.com/joergs-git/AstroSharper)

---

*This privacy policy is hosted on GitHub and linked directly from the Apple App Store listing.*
