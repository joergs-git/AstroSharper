# Tone Curve

Editable Catmull-Rom spline mapped to a 1D LUT, applied per-channel on the GPU.

## How it works

You drag 3–5 control points on a curve editor. AstroSharper interpolates a smooth Catmull-Rom spline through them, samples it into a 256-entry 1D `MTLTexture`, and the `tone_curve` Metal kernel reads that LUT once per output pixel.

## When to use it

- **Black point lift** — add a control point at (0.05, 0) to raise the floor without flattening the brights.
- **Mid-tone S-curve** — pull (0.3, 0.25) and push (0.7, 0.78) for a contrast boost.
- **Highlight roll-off** — add (0.95, 0.92) to soften clipped highlights on overexposed solar discs.

## Editor controls

- **Click** an empty area of the curve to add a point.
- **Drag** any point to move it.
- **Right-click** a point to delete (minimum 3 points enforced).
- The curve is locked at (0,0) and (1,1) — can't drag the endpoints off.

## Histogram overlay

The current frame's luminance histogram renders behind the curve. Toggle log-scale with the small "log" button — useful when shadow detail is buried under bright planetary disc tones.

## Apply Tone Curve hero button

Same dual-context behaviour as Sharpening:

- **Memory tab** — applies the LUT in-place to memory frames. Op trail appends "tone".
- **Inputs tab** — runs file batch with tone-only.

## Pipeline order

Tone curve always runs **after** sharpening, never before. This is intentional: sharpening at non-linear gamma produces ringing artefacts, so AstroSharper keeps sharpening in linear space and tone-mapping at the very end.

## See also

- [Sharpening](Sharpening.md)
- [Lucky Stack](Lucky-Stack.md) — bake-in applies the tone curve to the stacked output too
