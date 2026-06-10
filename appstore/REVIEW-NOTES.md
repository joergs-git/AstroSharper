# App Review Notes — AstroSharper

Paste the block below into **App Store Connect → your app → the version page
→ App Review Information → Notes**, and attach the sample file in the
**Attachment** field (or rely on the download link in the notes).

- **No account / login is required.** All processing is on-device.
- **Sample capture file** (the app needs a SER astronomy capture to do
  anything visible — reviewers won't have one):
  - Attached to this submission, **and** downloadable at:
    `https://github.com/joergs-git/AstroSharper/raw/main/appstore/sample/AstroSharper-Sample-Jupiter.ser`
  - It is a real 30-frame planetary capture of Jupiter (ZWO ASI224MC,
    656×424, 8-bit colour), 8.3 MB.

---

## Reviewer notes (copy into the Notes field)

AstroSharper is a "lucky imaging" tool for solar, lunar and planetary
astrophotography. It stacks the sharpest frames of a SER capture video into
one crisp image. No account or network connection is required; everything
runs locally on the GPU.

To test the core flow with the provided sample:

1. Launch AstroSharper.
2. Click **Open** in the toolbar (or press ⌘O) and select the folder
   containing the sample file `AstroSharper-Sample-Jupiter.ser`
   (download link above). A frame of Jupiter appears in the preview.
3. Make sure the **AutoNuke** toggle in the "Lucky Stack" section is ON
   (it is by default), then click **Run Lucky Stack**.
4. After a moment a stacked, sharpened result is written to the output
   folder shown at the bottom-left (default: a `_astrosharper` folder), and
   the result is displayed in the preview.

That exercises file loading, the GPU stacking pipeline, automatic
parameter selection and saving the output. The Sharpen / Tone Curve panels
on the left can then be used to post-process the result.

Optional anonymous telemetry and an opt-in community thumbnail share can be
toggled from the status bar at the bottom of the window; both are described
in the privacy policy and neither is required to use the app.
