// AstroSharper Metal kernels and shaders.
// Covers: display fit/pan/zoom, before/after split, unsharp mask, L-R helpers
// (divide / multiply), tone-curve LUT application, and shift+sample for
// stabilization.

#include <metal_stdlib>
using namespace metal;

// MARK: - Display vertex/fragment (textured quad with fit/pan/zoom)

struct DisplayUniforms {
    float2 texSize;     // image texture size in pixels
    float2 viewSize;    // drawable size in pixels
    float  zoom;        // 1.0 = fit
    float2 panPx;       // pan offset in image pixels
    float  splitX;      // 0..1 — fraction from left showing "after"; outside: before
    uint   hasAfter;    // 0 = only show before
    // Display-only auto-range stretch + gamma curve. AS!4-equivalent
    // path: (col − autoBlack) · autoScale → [0, 1] → pow(., autoGamma)
    // → · displayGain. autoBlack/autoScale are computed from the
    // current texture's percentiles; autoGamma defaults to 2.5 (user
    // bracket pick for solar Ha) and is fixed in the shader for now.
    // displayGain is the user's Brightness slider. autoRangeOn = 0 →
    // pass through, slider alone still applies. Saved files unaffected.
    float  autoBlack;
    float  autoScale;
    float  autoGamma;
    float  displayGain;
    uint   autoRangeOn;
};

struct DisplayVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle — no vertex buffer needed.
vertex DisplayVertexOut display_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uvs[3]        = { float2(0, 1),  float2(2, 1),  float2(0, -1) };
    DisplayVertexOut o;
    o.position = float4(positions[vid], 0, 1);
    o.uv = uvs[vid];
    return o;
}

fragment float4 display_fragment(
    DisplayVertexOut in [[stage_in]],
    texture2d<float, access::sample> before [[texture(0)]],
    texture2d<float, access::sample> after  [[texture(1)]],
    constant DisplayUniforms& u [[buffer(0)]]
) {
    // Map view UV (0..1 over drawable) to image UV with fit + zoom + pan.
    float imgAspect = u.texSize.x / u.texSize.y;
    float viewAspect = u.viewSize.x / u.viewSize.y;

    // Fit image into view preserving aspect.
    float2 fitScale;
    if (imgAspect > viewAspect) {
        fitScale = float2(1.0, viewAspect / imgAspect);
    } else {
        fitScale = float2(imgAspect / viewAspect, 1.0);
    }

    // Convert UV (0..1) to -1..1, apply inverse zoom around center, then
    // remove fit scale, then shift by pan (in UV).
    float2 centered = in.uv * 2.0 - 1.0;
    centered /= u.zoom;
    centered /= fitScale;

    // Clamp: outside = black bars.
    if (abs(centered.x) > 1.0 || abs(centered.y) > 1.0) {
        return float4(0, 0, 0, 1);
    }
    float2 uv = centered * 0.5 + 0.5;
    uv += u.panPx / u.texSize;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0, 0, 0, 1);
    }

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 colBefore = before.sample(s, uv);
    float4 col;
    if (u.hasAfter == 0u) {
        col = colBefore;
    } else {
        float4 colAfter = after.sample(s, uv);
        bool showAfter = in.uv.x < u.splitX;
        col = showAfter ? colAfter : colBefore;
        // Thin split line.
        float edge = abs(in.uv.x - u.splitX);
        if (edge < 0.001) {
            return float4(1, 1, 1, 1);
        }
    }
    // Auto-range stretch + gamma. Two-step process matching AS!4's
    // "Auto Range" + "Brightness pow" + the implicit sRGB display
    // gamma, validated by user bracket (file 26_stretch_g25 picked
    // for solar Ha):
    //   1. (col − p1) · autoScale → [0, 1] (stretch over the data range)
    //   2. pow(., 2.5) → midtone darkening (high contrast)
    //   3. user's Brightness slider multiplies on top
    //   4. sRGB display encode (pow ., 2.2) so the on-screen result
    //      matches what an sRGB-tagged PNG of the same math looks like
    //
    // Step 4 is the missing piece that made the live preview look
    // brighter / flatter than the bracket PNGs: my Python `pow(stretched,
    // 2.5) * 255` saves to PNG, Preview.app reads it as sRGB and applies
    // an implicit pow(., 2.2) decode at display. The Metal `rgba16Float`
    // swap chain by default is treated as EXTENDED-LINEAR by the macOS
    // compositor, so values written directly hit the display without
    // that extra encode. Adding it here re-creates the de-facto PNG
    // display chain inside the shader.
    //
    // Skipped entirely when autoRangeOn = 0; the slider alone still
    // applies and the sRGB encode is also skipped so users see bare
    // pixel values.
    if (u.autoRangeOn != 0u) {
        float3 stretched = clamp((col.rgb - u.autoBlack) * u.autoScale, 0.0, 1.0);
        col.rgb = pow(stretched, float3(u.autoGamma));
        if (u.displayGain != 1.0) {
            col.rgb = clamp(col.rgb * u.displayGain, 0.0, 1.0);
        } else {
            col.rgb = clamp(col.rgb, 0.0, 1.0);
        }
        col.rgb = pow(col.rgb, float3(2.2));   // sRGB display encode
    } else if (u.displayGain != 1.0) {
        col.rgb = clamp(col.rgb * u.displayGain, 0.0, 1.0);
    } else {
        col.rgb = clamp(col.rgb, 0.0, 1.0);
    }
    return col;
}

// MARK: - Unsharp mask

struct UnsharpParams {
    float amount;        // base amount
    float adaptiveMin;   // luminance below which amount = 0
    float adaptiveMax;   // luminance above which amount = full
    uint  adaptive;      // 0 = off, 1 = on
};

kernel void unsharp_mask(
    texture2d<float, access::read>  original [[texture(0)]],
    texture2d<float, access::read>  blurred  [[texture(1)]],
    texture2d<float, access::write> output   [[texture(2)]],
    constant UnsharpParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 o = original.read(gid);
    float4 b = blurred.read(gid);
    float4 diff = o - b;

    float amt = params.amount;
    if (params.adaptive != 0u) {
        float lum = dot(o.rgb, float3(0.2126, 0.7152, 0.0722));
        float t = smoothstep(params.adaptiveMin, params.adaptiveMax, lum);
        amt *= t;
    }

    float4 result = o + diff * amt;
    output.write(clamp(result, 0.0, 1.0), gid);
}

// MARK: - Lucy-Richardson helpers

// observed / (estimate ⊗ PSF), pixel-wise, with epsilon to avoid /0.
kernel void lr_divide(
    texture2d<float, access::read>  observed  [[texture(0)]],
    texture2d<float, access::read>  convolved [[texture(1)]],
    texture2d<float, access::write> ratio     [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= ratio.get_width() || gid.y >= ratio.get_height()) return;
    float4 o = observed.read(gid);
    float4 c = convolved.read(gid);
    const float eps = 1e-6;
    float4 r = o / max(c, float4(eps));
    ratio.write(r, gid);
}

// estimate <- estimate * correction  (correction = ratio ⊗ PSF)
kernel void lr_multiply(
    texture2d<float, access::read>        estimate   [[texture(0)]],
    texture2d<float, access::read>        correction [[texture(1)]],
    texture2d<float, access::read_write>  output     [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 e = estimate.read(gid);
    float4 c = correction.read(gid);
    float4 r = e * c;
    output.write(clamp(r, 0.0, 10.0), gid);  // allow mild over-shoot, clamp at display stage
}

// MARK: - Tone curve

kernel void apply_tone_curve(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    texture1d<float, access::sample> lut    [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float r = lut.sample(s, saturate(c.r)).r;
    float g = lut.sample(s, saturate(c.g)).r;
    float b = lut.sample(s, saturate(c.b)).r;
    output.write(float4(r, g, b, c.a), gid);
}

// MARK: - Chromatic dispersion correction (Path A)
//
// Per-channel sub-pixel shift on a stacked RGBA texture. Green stays
// anchored at the input grid; R and B sample from offset positions so
// the misregistered colour images re-align onto green. Offsets in
// pixels of the input texture's coord system (NOT normalised UV).
//
// out.r(gid) = input.r(gid - redOffset)
// out.g(gid) = input.g(gid)
// out.b(gid) = input.b(gid - blueOffset)
//
// Linear sampling preserves the sub-pixel precision of the offsets
// computed by phase correlation.

struct ChannelShiftParams {
    float2 redOffset;   // px in input grid; r samples at gid - redOffset
    float2 blueOffset;  // px in input grid; b samples at gid - blueOffset
};

kernel void shift_rb_channels(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant ChannelShiftParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 size = float2(output.get_width(), output.get_height());
    float2 baseUV = (float2(gid) + 0.5) / size;
    float2 redUV  = (float2(gid) + 0.5 - p.redOffset)  / size;
    float2 blueUV = (float2(gid) + 0.5 - p.blueOffset) / size;
    float r = input.sample(s, redUV).r;
    float g = input.sample(s, baseUV).g;
    float b = input.sample(s, blueUV).b;
    float a = input.sample(s, baseUV).a;
    output.write(float4(r, g, b, a), gid);
}

// MARK: - Auto white balance (gray-world correction)
//
// Applies a per-channel offset + scale: out.rgb = (in.rgb - offset) * scale.
// Offsets/scales are computed CPU-side via WhiteBalance.computeGrayWorld
// on a downsampled luminance readback of the input texture. The kernel
// itself is a single-pass per-pixel transform; the actual WB intelligence
// lives in the CPU helper.

struct WhiteBalanceParams {
    float3 offsets;
    float3 scales;
};

kernel void apply_white_balance(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant WhiteBalanceParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    float3 v = (c.rgb - p.offsets) * p.scales;
    v = max(v, float3(0.0));
    output.write(float4(v, c.a), gid);
}

// MARK: - Auto-stretch (histogram normalisation)
//
// Linear stretch that maps a pre-computed black-point and white-point
// onto [0, 0.95]. Bright tail (anything ≥ whitePoint) clips to ~0.95
// rather than 1.0 so post-stretch sharpening still has headroom; dark
// floor (anything ≤ blackPoint) clips to 0. Operates per-channel so
// the chromatic balance is preserved.
//
//   out = clamp((in - blackPoint) * scale, 0, 0.95)
//   scale = 0.95 / (whitePoint - blackPoint)
//
// blackPoint / whitePoint come from the percentile pass on a 256x256
// downsampled luminance readback (CPU side). Scale is pre-computed so
// the kernel doesn't divide per-pixel.

struct AutoStretchParams {
    float blackPoint;
    float scale;          // pre-computed = whiteCap / (whitePoint - blackPoint)
    float whiteCap;       // upper clamp — 0.97 for stack-end recovery (small headroom, no clip)
    float gamma;          // 1.0 = pure linear; <1 lifts midtones, >1 darkens midtones
};

kernel void apply_auto_stretch(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant AutoStretchParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    // Linear remap of the [blackPoint, whitePoint] luma window into
    // [0, whiteCap], optional pow-gamma on top. Used as a post-stack
    // auto-recovery: mean-stacking lifts the dark sky and flattens the
    // bright peaks, so without this final remap the saved TIF looks
    // washed-out (full histogram squished into the middle ~50% of the
    // range). The percentile choice (1%/99%) plus whiteCap=0.97 +
    // gamma=1.0 just undoes that compression — it does NOT amplify
    // contrast beyond the natural exposure of the stack.
    float3 stretched = clamp((c.rgb - p.blackPoint) * p.scale, 0.0, p.whiteCap);
    float3 v = pow(stretched, float3(p.gamma));
    output.write(float4(v, c.a), gid);
}

// MARK: - Bilateral noise reduction
//
// Edge-preserving smoother that runs as the LAST step of the sharpening
// chain. Sharpening (deconv → wavelet → unsharp) amplifies high-frequency
// content including residual stacking noise; bilateral smoothing knocks
// the noise floor down without un-doing the visible detail enhancement
// because it weights neighbour samples by both spatial AND range
// (intensity) distance — pixels across an edge contribute almost
// nothing.
//
// Two parameters tune the trade-off:
//   spatialSigma — controls neighbourhood size (1.0 ≈ tight 5×5 weights)
//   rangeSigma   — controls edge sensitivity in [0,1] intensity units;
//                  smaller = harder edge preservation, larger = stronger
//                  smoothing across edges.
// The fixed window radius bounds per-pixel cost (final kernel = 2r+1).

struct NoiseReduceParams {
    float spatialSigma;
    float rangeSigma;
    int   radius;
};

kernel void noise_reduce_bilateral(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant NoiseReduceParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    int W = int(input.get_width()), H = int(input.get_height());
    float4 center = input.read(gid);
    float spatialFactor = -0.5 / max(p.spatialSigma * p.spatialSigma, 1e-6);
    float rangeFactor   = -0.5 / max(p.rangeSigma * p.rangeSigma, 1e-6);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    int r = p.radius;
    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            int x = clamp(int(gid.x) + dx, 0, W - 1);
            int y = clamp(int(gid.y) + dy, 0, H - 1);
            float4 sample = input.read(uint2(x, y));
            float spatial = exp(spatialFactor * float(dx * dx + dy * dy));
            float3 diff = sample.rgb - center.rgb;
            float range = exp(rangeFactor * dot(diff, diff));
            float w = spatial * range;
            sum += sample.rgb * w;
            wsum += w;
        }
    }
    if (wsum > 0.0) {
        output.write(float4(sum / wsum, center.a), gid);
    } else {
        output.write(center, gid);
    }
}

// MARK: - Brightness + Contrast
//
// Luma-only lightness adjustment that runs as a discrete pipeline step
// right after the tone curve (so it operates on whatever curve the
// user dialled in) and before saturation.
//
// Per-channel contrast (the obvious `(c - 0.5) * k + 0.5` form) amplifies
// every pre-existing R/G/B micro-misregistration in the stacked image
// into a visible coloured fringe — sub-pixel atmospheric dispersion,
// rounding noise, anything that puts the three channels slightly out of
// register. Operating on luminance only and preserving the per-pixel
// chrominance ratio keeps colour neutral across contrast changes.
//
//   luma'  = clamp((luma - 0.5) * contrast + 0.5 + brightness, 0, 1)
//   ratio  = luma' / luma                       (1.0 if luma ≈ 0)
//   rgb_out = clamp(rgb * ratio, 0, 1)
//
// Identity = (brightness 0, contrast 1). The pipeline skips this step
// at identity so the no-op case costs nothing.

struct BrightnessContrastParams {
    float brightness;
    float contrast;
};

kernel void apply_brightness_contrast(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant BrightnessContrastParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    float adj  = clamp((luma - 0.5) * p.contrast + 0.5 + p.brightness, 0.0, 1.0);
    float ratio = (luma > 1e-4) ? (adj / luma) : 1.0;
    float3 v = clamp(c.rgb * ratio, 0.0, 1.0);
    output.write(float4(v, c.a), gid);
}

// MARK: - Pre-stack calibration (Block D.1)
//
// Apply the standard astrophoto calibration chain per pixel:
//
//   calibrated = (light − masterDark) / masterFlatNormalized
//
// `masterFlatNormalized` MUST already have its global mean ≈ 1.0 so
// dividing preserves overall brightness (CPU side: Calibration.buildMasterFlat).
// Pixels where the flat is at-or-below `flatEpsilon` pass through
// without the divide so a dust-blocked region doesn't blow up to
// infinity. Negative results clamp to zero so downstream sqrt / log
// stages don't NaN.
//
// `hasDark` / `hasFlat` flags let one kernel handle three cases:
// dark-only, flat-only, both. Dark and flat textures (when present)
// must match the light texture's dimensions.

struct CalibrationParams {
    uint  hasDark;
    uint  hasFlat;
    float flatEpsilon;
};

kernel void apply_calibration(
    texture2d<float, access::read>  light [[texture(0)]],
    texture2d<float, access::read>  dark  [[texture(1)]],
    texture2d<float, access::read>  flat  [[texture(2)]],
    texture2d<float, access::write> outTex [[texture(3)]],
    constant CalibrationParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 l = light.read(gid);
    float3 v = l.rgb;
    if (p.hasDark != 0u) {
        v -= dark.read(gid).rgb;
    }
    if (p.hasFlat != 0u) {
        float3 f = flat.read(gid).rgb;
        // Per-channel divide where the flat is above epsilon.
        v.x = (f.x > p.flatEpsilon) ? (v.x / f.x) : v.x;
        v.y = (f.y > p.flatEpsilon) ? (v.y / f.y) : v.y;
        v.z = (f.z > p.flatEpsilon) ? (v.z / f.z) : v.z;
    }
    outTex.write(float4(max(float3(0), v), l.a), gid);
}

// MARK: - Highlights / Shadows
//
// Hue-preserving tone mask: scales each pixel's RGB by the new-luma /
// old-luma ratio so chrominance stays put while the brightness response
// reshapes around the mid-tone.
//
//   highlightWeight = smoothstep(0.5, 1.0, Y)   (rises from 0 at mid → 1 at white)
//   shadowWeight    = 1 − smoothstep(0.0, 0.5, Y)   (rises from 0 at mid → 1 at black)
//   ΔY = highlights · highlightWeight · 0.5      (negative compresses, positive lifts)
//        + shadows   · shadowWeight   · 0.5
//   Y_new = clamp(Y + ΔY, 0, 1)
//   RGB_new = RGB · (Y_new / Y)                  (when Y > eps; else identity)
//
// At identity (highlights == 0 && shadows == 0) the kernel is a pure
// pass-through. Caller must skip the dispatch in that case to keep the
// no-op cost zero. Range-bound inputs to ±1.0 — beyond that the visible
// effect saturates and shadow recovery from negative values produces a
// visibly artificial roll-off.

struct HighlightsShadowsParams {
    float highlights;     // -1 .. +1 — negative compresses bright peaks, positive lifts
    float shadows;        // -1 .. +1 — positive lifts dark areas, negative deepens
};

kernel void apply_highlights_shadows(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant HighlightsShadowsParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    float Y = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    float hw = smoothstep(0.5, 1.0, Y);
    float sw = 1.0 - smoothstep(0.0, 0.5, Y);
    float dY = p.highlights * hw * 0.5 + p.shadows * sw * 0.5;
    float Yn = clamp(Y + dY, 0.0, 1.0);
    float ratio = (Y > 1e-4) ? (Yn / Y) : 1.0;
    float3 v = clamp(c.rgb * ratio, 0.0, 1.0);
    output.write(float4(v, c.a), gid);
}

// MARK: - Saturation
//
// Mix each RGB sample with its Rec.709 luminance to control colour
// saturation around the per-pixel luma:
//   sat = 0.0  → grayscale (luma in all three channels)
//   sat = 1.0  → identity (no change)
//   sat > 1.0  → boosted saturation; the colour pulls further away
//                from the grey luma. Capped only by the float range —
//                clipping happens at display.
//
// Stacked planetary frames trend toward the desaturated mean because
// per-channel weighted averaging pulls colour toward the achromatic
// noise. A modest boost (1.2–1.5) restores the visible colour the user
// captured without nuking the limb darkening.

struct SaturationParams {
    float saturation;
};

kernel void apply_saturation(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant SaturationParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 mixed = mix(float3(luma), c.rgb, p.saturation);
    output.write(float4(mixed, c.a), gid);
}

// MARK: - Sub-pixel shift (stabilization)

struct ShiftParams {
    float2 shiftPx;  // how much to shift so content aligns to reference
};

kernel void sub_pixel_shift(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant ShiftParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5 - params.shiftPx) / float2(output.get_width(), output.get_height());
    float4 c = input.sample(s, uv);
    output.write(c, gid);
}

// MARK: - À-trous wavelet layer extraction + reconstruction
//
// A layer of the à-trous / starlet transform is `coarse_n - coarse_{n+1}`.
// We compute it with a subtract kernel and then recombine the boosted layers
// with a weighted-add kernel. Keeping this on GPU as per-pixel kernels keeps
// 4-level solar sharpening well below one millisecond on Apple Silicon.

kernel void subtract_textures(
    texture2d<float, access::read>  a      [[texture(0)]],
    texture2d<float, access::read>  b      [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(a.read(gid) - b.read(gid), gid);
}

struct WaveletAddParams {
    float amount;
    float threshold;   // soft-shrink layer values whose magnitude is < threshold
};

// accum = accum + soft_shrink(layer, threshold) * amount.
//
// Soft-thresholding (Donoho 1995) at the per-band layer is the textbook
// noise-reduction-without-losing-sharpness trick that Registax / AS!4
// inherited from the multiresolution-analysis literature: noise is
// roughly Gaussian and concentrates in the smallest-magnitude wavelet
// coefficients, while real detail produces large coefficients. Shrinking
// every coefficient by `threshold` toward zero zeroes out noise but
// preserves edges (which exceed the threshold and survive shrinkage
// proportionally). Applied per-band so the user can knock down noise
// at the noisy fine scales (1–2 px) while still boosting real detail
// at the larger scales.
//
//   shrunk = sign(x) * max(|x| - threshold, 0)
//
// threshold = 0 reproduces the previous additive-only behaviour exactly,
// so old preset JSON without the new field keeps producing identical
// output. Alpha is passed through unchanged.
kernel void weighted_add(
    texture2d<float, access::read>        layer [[texture(0)]],
    texture2d<float, access::read_write>  accum [[texture(1)]],
    constant WaveletAddParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    float4 l = layer.read(gid);
    float3 absL = abs(l.rgb);
    float3 shrunk = max(absL - params.threshold, 0.0) * sign(l.rgb);
    float4 a = accum.read(gid);
    accum.write(a + float4(shrunk * params.amount, l.a * params.amount), gid);
}

// MARK: - 180° rotation (meridian flip)
//
// Out-of-place 180° rotation around the image centre. Used when a capture
// session crossed the meridian and the user flagged the file as flipped, so
// downstream stabilization / stacking sees consistent orientation across
// the whole session.

kernel void rotate_180(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint w = src.get_width();
    uint h = src.get_height();
    uint2 srcGid = uint2(w - 1 - gid.x, h - 1 - gid.y);
    dst.write(src.read(srcGid), gid);
}

// MARK: - SER raw → rgba16Float
//
// SER frames arrive as tightly-packed mono 8/16-bit. We unpack into our
// standard rgba16Float pipeline format. Dispatched one frame at a time from
// a shared staging texture.

struct SerUnpackParams {
    float scale;        // 1/255 for 8-bit, 1/65535 for 16-bit
    uint  flip;         // 0 = direct write, 1 = 180° rotate during unpack
};

// Mono 16-bit unsigned → rgba16Float, broadcasting to RGB. Optional 180°
// rotation during unpack (zero overhead vs. a second pass).
kernel void unpack_mono16_to_rgba(
    texture2d<uint, access::read>   src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant SerUnpackParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 srcGid = (p.flip != 0u)
        ? uint2(src.get_width() - 1 - gid.x, src.get_height() - 1 - gid.y)
        : gid;
    uint v = src.read(srcGid).r;
    float f = float(v) * p.scale;
    dst.write(float4(f, f, f, 1.0), gid);
}

kernel void unpack_mono8_to_rgba(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant SerUnpackParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 srcGid = (p.flip != 0u)
        ? uint2(src.get_width() - 1 - gid.x, src.get_height() - 1 - gid.y)
        : gid;
    float v = src.read(srcGid).r;
    dst.write(float4(v, v, v, 1.0), gid);
}

// MARK: - Bayer demosaic (OSC SER)
//
// Bilinear demosaic for the four classic 2×2 Bayer patterns (RGGB / GRBG /
// GBRG / BGGR). At each output pixel we know its native colour from the
// pattern offset; the missing two channels are bilinear averages of nearest
// neighbours of that colour. Quality is good enough for lucky-imaging where
// the stacked output is dominated by signal averaging anyway.
//
// Pattern encoding (matches AppModel side):
//   0 = RGGB → R at (0,0)
//   1 = GRBG → R at (1,0)
//   2 = GBRG → R at (0,1)
//   3 = BGGR → R at (1,1)

struct BayerUnpackParams {
    float scale;
    uint  flip;
    uint  pattern;
};

inline float bayer_read_u16(texture2d<uint, access::read> src, int2 p, float scale) {
    int W = int(src.get_width()), H = int(src.get_height());
    p.x = clamp(p.x, 0, W - 1);
    p.y = clamp(p.y, 0, H - 1);
    return float(src.read(uint2(p)).r) * scale;
}
inline float bayer_read_f(texture2d<float, access::read> src, int2 p) {
    int W = int(src.get_width()), H = int(src.get_height());
    p.x = clamp(p.x, 0, W - 1);
    p.y = clamp(p.y, 0, H - 1);
    return src.read(uint2(p)).r;
}

// Malvar-He-Cutler 2004 (MSR-TR-2004-92) high-quality linear demosaic.
// 5x5 stencil with hand-tuned coefficients that exploit cross-channel
// correlation — the missing-channel reconstruction uses BOTH same-channel
// neighbours AND nearby other-channel values, so edges aren't blurred
// across the 2-pixel Bayer mosaic the way bilinear blurs them. On
// planetary OSC stacks this preserves ~2x the high-frequency detail of
// bilinear, which is the difference between 'cloud band shape' and
// 'visible cloud micro-structure'.
//
// Four kernels, each summing to 8 (we divide by 8 at the end):
//
//   gAtNonG  — Green at R/B site (axial weights)
//   horizG   — R at Gr (or B at Gb) — horizontal-strong
//   vertG    — R at Gb (or B at Gr) — vertical-strong (= horizG.transposed)
//   diag     — R at B (or B at R)   — diagonal-strong
//
// Each helper takes the 13 read values it needs as arguments. Caller
// reads them in the format-specific path. Negative weights can push
// the output outside [0, 1] so we clamp after the divide.
//
// 13 sample positions used (relative to center c):
//   p[0]  = c                       (center)
//   p[1]  = c + ( 0,-2)
//   p[2]  = c + ( 0,-1)
//   p[3]  = c + ( 0, 1)
//   p[4]  = c + ( 0, 2)
//   p[5]  = c + (-2, 0)
//   p[6]  = c + (-1, 0)
//   p[7]  = c + ( 1, 0)
//   p[8]  = c + ( 2, 0)
//   p[9]  = c + (-1,-1)
//   p[10] = c + ( 1,-1)
//   p[11] = c + (-1, 1)
//   p[12] = c + ( 1, 1)

inline float malvar_g_at_nonG(thread float* p) {
    return ( -1.0 * p[1] +  2.0 * p[2] +  4.0 * p[0] +  2.0 * p[3] + -1.0 * p[4]
             -1.0 * p[5] +  2.0 * p[6] +  2.0 * p[7] + -1.0 * p[8]) / 8.0;
}
inline float malvar_horizG(thread float* p) {
    return (  0.5 * p[1]
             -1.0 * p[9] + -1.0 * p[10]
             -1.0 * p[5] +  4.0 * p[6] +  5.0 * p[0] +  4.0 * p[7] + -1.0 * p[8]
             -1.0 * p[11] + -1.0 * p[12]
             +0.5 * p[4]) / 8.0;
}
inline float malvar_vertG(thread float* p) {
    return ( -1.0 * p[1]
             -1.0 * p[9] +  4.0 * p[2] + -1.0 * p[10]
             +0.5 * p[5] +  5.0 * p[0] +  0.5 * p[8]
             -1.0 * p[11] +  4.0 * p[3] + -1.0 * p[12]
             -1.0 * p[4]) / 8.0;
}
inline float malvar_diag(thread float* p) {
    return ( -1.5 * p[1]
             +2.0 * p[9] +  2.0 * p[10]
             -1.5 * p[5] +  6.0 * p[0] + -1.5 * p[8]
             +2.0 * p[11] +  2.0 * p[12]
             -1.5 * p[4]) / 8.0;
}

inline float3 malvar_demosaic_u16(
    texture2d<uint, access::read> src,
    int2 c,
    uint pattern,
    float scale
) {
    uint2 rOff = uint2(pattern & 1u, (pattern >> 1) & 1u);
    uint pxX = uint(c.x) & 1u;
    uint pxY = uint(c.y) & 1u;
    bool isRed   = (pxX == rOff.x) && (pxY == rOff.y);
    bool isBlue  = (pxX != rOff.x) && (pxY != rOff.y);
    bool isGreenInRedRow  = !isRed && !isBlue && (pxY == rOff.y);  // Gr

    float p[13];
    p[ 0] = bayer_read_u16(src, c,                  scale);
    p[ 1] = bayer_read_u16(src, c + int2( 0, -2),   scale);
    p[ 2] = bayer_read_u16(src, c + int2( 0, -1),   scale);
    p[ 3] = bayer_read_u16(src, c + int2( 0,  1),   scale);
    p[ 4] = bayer_read_u16(src, c + int2( 0,  2),   scale);
    p[ 5] = bayer_read_u16(src, c + int2(-2,  0),   scale);
    p[ 6] = bayer_read_u16(src, c + int2(-1,  0),   scale);
    p[ 7] = bayer_read_u16(src, c + int2( 1,  0),   scale);
    p[ 8] = bayer_read_u16(src, c + int2( 2,  0),   scale);
    p[ 9] = bayer_read_u16(src, c + int2(-1, -1),   scale);
    p[10] = bayer_read_u16(src, c + int2( 1, -1),   scale);
    p[11] = bayer_read_u16(src, c + int2(-1,  1),   scale);
    p[12] = bayer_read_u16(src, c + int2( 1,  1),   scale);

    float r, g, b;
    if (isRed) {
        r = p[0];
        g = clamp(malvar_g_at_nonG(p), 0.0, 1.0);
        b = clamp(malvar_diag(p),       0.0, 1.0);
    } else if (isBlue) {
        b = p[0];
        g = clamp(malvar_g_at_nonG(p), 0.0, 1.0);
        r = clamp(malvar_diag(p),       0.0, 1.0);
    } else if (isGreenInRedRow) {
        g = p[0];
        r = clamp(malvar_horizG(p),    0.0, 1.0);
        b = clamp(malvar_vertG(p),     0.0, 1.0);
    } else {
        g = p[0];
        b = clamp(malvar_horizG(p),    0.0, 1.0);
        r = clamp(malvar_vertG(p),     0.0, 1.0);
    }
    return float3(r, g, b);
}

inline float3 malvar_demosaic_f(
    texture2d<float, access::read> src,
    int2 c,
    uint pattern
) {
    uint2 rOff = uint2(pattern & 1u, (pattern >> 1) & 1u);
    uint pxX = uint(c.x) & 1u;
    uint pxY = uint(c.y) & 1u;
    bool isRed   = (pxX == rOff.x) && (pxY == rOff.y);
    bool isBlue  = (pxX != rOff.x) && (pxY != rOff.y);
    bool isGreenInRedRow  = !isRed && !isBlue && (pxY == rOff.y);

    float p[13];
    p[ 0] = bayer_read_f(src, c);
    p[ 1] = bayer_read_f(src, c + int2( 0, -2));
    p[ 2] = bayer_read_f(src, c + int2( 0, -1));
    p[ 3] = bayer_read_f(src, c + int2( 0,  1));
    p[ 4] = bayer_read_f(src, c + int2( 0,  2));
    p[ 5] = bayer_read_f(src, c + int2(-2,  0));
    p[ 6] = bayer_read_f(src, c + int2(-1,  0));
    p[ 7] = bayer_read_f(src, c + int2( 1,  0));
    p[ 8] = bayer_read_f(src, c + int2( 2,  0));
    p[ 9] = bayer_read_f(src, c + int2(-1, -1));
    p[10] = bayer_read_f(src, c + int2( 1, -1));
    p[11] = bayer_read_f(src, c + int2(-1,  1));
    p[12] = bayer_read_f(src, c + int2( 1,  1));

    float r, g, b;
    if (isRed) {
        r = p[0];
        g = clamp(malvar_g_at_nonG(p), 0.0, 1.0);
        b = clamp(malvar_diag(p),       0.0, 1.0);
    } else if (isBlue) {
        b = p[0];
        g = clamp(malvar_g_at_nonG(p), 0.0, 1.0);
        r = clamp(malvar_diag(p),       0.0, 1.0);
    } else if (isGreenInRedRow) {
        g = p[0];
        r = clamp(malvar_horizG(p),    0.0, 1.0);
        b = clamp(malvar_vertG(p),     0.0, 1.0);
    } else {
        g = p[0];
        b = clamp(malvar_horizG(p),    0.0, 1.0);
        r = clamp(malvar_vertG(p),     0.0, 1.0);
    }
    return float3(r, g, b);
}

inline float3 bilinear_demosaic_f(
    texture2d<float, access::read> src,
    int2 c,
    uint pattern
) {
    uint2 rOff = uint2(pattern & 1u, (pattern >> 1) & 1u);
    uint pxX = uint(c.x) & 1u;
    uint pxY = uint(c.y) & 1u;
    bool isRed   = (pxX == rOff.x) && (pxY == rOff.y);
    bool isBlue  = (pxX != rOff.x) && (pxY != rOff.y);
    bool greenRedRow = !isRed && !isBlue && (pxY == rOff.y);

    float r, g, b;
    if (isRed) {
        r = bayer_read_f(src, c);
        g = 0.25 * (bayer_read_f(src, c + int2(-1, 0))
                  + bayer_read_f(src, c + int2( 1, 0))
                  + bayer_read_f(src, c + int2( 0,-1))
                  + bayer_read_f(src, c + int2( 0, 1)));
        b = 0.25 * (bayer_read_f(src, c + int2(-1,-1))
                  + bayer_read_f(src, c + int2( 1,-1))
                  + bayer_read_f(src, c + int2(-1, 1))
                  + bayer_read_f(src, c + int2( 1, 1)));
    } else if (isBlue) {
        b = bayer_read_f(src, c);
        g = 0.25 * (bayer_read_f(src, c + int2(-1, 0))
                  + bayer_read_f(src, c + int2( 1, 0))
                  + bayer_read_f(src, c + int2( 0,-1))
                  + bayer_read_f(src, c + int2( 0, 1)));
        r = 0.25 * (bayer_read_f(src, c + int2(-1,-1))
                  + bayer_read_f(src, c + int2( 1,-1))
                  + bayer_read_f(src, c + int2(-1, 1))
                  + bayer_read_f(src, c + int2( 1, 1)));
    } else {
        g = bayer_read_f(src, c);
        if (greenRedRow) {
            r = 0.5 * (bayer_read_f(src, c + int2(-1, 0))
                     + bayer_read_f(src, c + int2( 1, 0)));
            b = 0.5 * (bayer_read_f(src, c + int2( 0,-1))
                     + bayer_read_f(src, c + int2( 0, 1)));
        } else {
            r = 0.5 * (bayer_read_f(src, c + int2( 0,-1))
                     + bayer_read_f(src, c + int2( 0, 1)));
            b = 0.5 * (bayer_read_f(src, c + int2(-1, 0))
                     + bayer_read_f(src, c + int2( 1, 0)));
        }
    }
    return float3(r, g, b);
}

kernel void unpack_bayer16_to_rgba(
    texture2d<uint, access::read>   src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant BayerUnpackParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 srcGid = (p.flip != 0u)
        ? uint2(src.get_width() - 1 - gid.x, src.get_height() - 1 - gid.y)
        : gid;
    float3 rgb = malvar_demosaic_u16(src, int2(srcGid), p.pattern, p.scale);
    dst.write(float4(rgb, 1.0), gid);
}

kernel void unpack_bayer8_to_rgba(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant BayerUnpackParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 srcGid = (p.flip != 0u)
        ? uint2(src.get_width() - 1 - gid.x, src.get_height() - 1 - gid.y)
        : gid;
    float3 rgb = malvar_demosaic_f(src, int2(srcGid), p.pattern);
    dst.write(float4(rgb, 1.0), gid);
}

// MARK: - RGB / BGR packed (3 bytes per pixel) → rgba16Float
//
// Some capture tools write debayered RGB24 SER files (each pixel is 3
// tightly-packed bytes — R, G, B in row-major order). Metal has no
// `.rgb8Unorm` texture format, so the staging path uses an MTLBuffer
// and the kernel decodes 3 bytes per output pixel. Same `flip` and
// `scale` semantics as the mono / Bayer kernels above. `swapRB` flips
// channel order so the same kernel handles BGR with `swapRB = 1`.
//
// 16-bit RGB48 captures are out of scope for this kernel — they need a
// separate u16 buffer kernel; defer until the field shows up.

struct RgbUnpackParams {
    float scale;        // 1/255.0 (8-bit only — see kernel comment)
    uint  flip;         // 0 = direct, 1 = 180° rotate
    uint  swapRB;       // 0 = RGB, 1 = BGR (swap red/blue channels)
    uint  width;        // pixel width — needed because device buffers
                        // don't carry geometry like textures do.
};

kernel void unpack_rgb8_to_rgba(
    device const uchar*             src [[buffer(0)]],
    texture2d<float, access::write> dst [[texture(0)]],
    constant RgbUnpackParams&       p   [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = dst.get_width();
    uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    uint flippedX = (p.flip != 0u) ? (W - 1 - gid.x) : gid.x;
    uint flippedY = (p.flip != 0u) ? (H - 1 - gid.y) : gid.y;
    uint base = (flippedY * p.width + flippedX) * 3u;
    float c0 = float(src[base + 0u]) * p.scale;
    float c1 = float(src[base + 1u]) * p.scale;
    float c2 = float(src[base + 2u]) * p.scale;
    float r = (p.swapRB != 0u) ? c2 : c0;
    float g = c1;
    float b = (p.swapRB != 0u) ? c0 : c2;
    dst.write(float4(r, g, b, 1.0), gid);
}

// MARK: - Bayer single-channel extraction (Path B per-channel stacking)
//
// Each kernel emits a half-resolution (W/2 × H/2) plane containing TRUE
// MEASURED pixels for one of R / G / B — no demosaic interpolation. The
// extracted scalar is replicated into r/g/b/a so the existing rgba*Float
// pipeline (quality grader, phase correlator, accumulator) operates on
// these planes without modification: every kernel reads `.r` / `.rgb`
// and gets the same value.
//
// Pattern decoding (mirrors malvar_demosaic_*):
//   pattern bit 0 → R column offset within 2×2 cell
//   pattern bit 1 → R row    offset within 2×2 cell
// → R site coords: (rOff.x,        rOff.y)
//   B site coords: (1-rOff.x,      1-rOff.y)
//   G sites      : (1-rOff.x, rOff.y) and (rOff.x, 1-rOff.y)
//
// Per output (gid.x, gid.y) covering the half-res plane, we work inside
// the 2×2 source cell starting at (2·gid.x, 2·gid.y). Source addresses
// are clamped at the edge to avoid out-of-bounds reads on odd-sized
// captures. G output averages the two G sites of the 2×2 cell — the
// classic AS!4 / BiggSky convention so the signal stays balanced across
// frames without splitting Gr/Gb into separate channels.
//
// `channel` parameter: 0 = R, 1 = G, 2 = B.

struct BayerChannelParams {
    float scale;       // 1/65535 for u16, 1.0 for u8
    uint  flip;        // mirror raw frame 180° (meridian flip)
    uint  pattern;     // 0..3, RGGB/GRBG/GBRG/BGGR
    uint  channel;     // 0 = R, 1 = G, 2 = B
};

/// Map (cell-x, cell-y) → raw source coords for the requested channel.
/// `cellSize` is the W,H of the raw mosaic in 2×2 cells (= dst size).
inline int2 bayer_channel_site_u(
    int2 cell,
    uint pattern,
    uint channel,
    int cellSize_x,       // dst.width
    int cellSize_y,       // dst.height
    int srcW,
    int srcH,
    int gIdx              // 0 or 1 — which of the two G sites
) {
    int2 rOff = int2(int(pattern & 1u), int((pattern >> 1) & 1u));
    int2 cellOrigin = cell * 2;
    int2 site;
    if (channel == 0u) {
        site = cellOrigin + rOff;
    } else if (channel == 2u) {
        site = cellOrigin + int2(1 - rOff.x, 1 - rOff.y);
    } else {
        // G has two sites in each cell. gIdx = 0 → (1-rOff.x, rOff.y)
        // (the same row as R), gIdx = 1 → (rOff.x, 1-rOff.y).
        site = (gIdx == 0)
            ? cellOrigin + int2(1 - rOff.x, rOff.y)
            : cellOrigin + int2(rOff.x, 1 - rOff.y);
    }
    site.x = clamp(site.x, 0, srcW - 1);
    site.y = clamp(site.y, 0, srcH - 1);
    return site;
}

/// 16-bit Bayer source → half-res mono-replicated rgba32Float channel plane.
kernel void unpack_bayer16_channel_to_rgba(
    texture2d<uint,  access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant BayerChannelParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    int srcW = int(src.get_width());
    int srcH = int(src.get_height());
    int dstW = int(dst.get_width());
    int dstH = int(dst.get_height());

    // Meridian flip applies to the raw cell coordinate. Each half-res
    // output cell maps to a 2×2 source cell, so flipping (cellX, cellY)
    // → (dstW-1-cellX, dstH-1-cellY) preserves Bayer phase.
    int2 cell = int2(gid);
    if (p.flip != 0u) {
        cell = int2(dstW - 1 - cell.x, dstH - 1 - cell.y);
    }

    float v;
    if (p.channel == 1u) {
        int2 g0 = bayer_channel_site_u(cell, p.pattern, 1u, dstW, dstH, srcW, srcH, 0);
        int2 g1 = bayer_channel_site_u(cell, p.pattern, 1u, dstW, dstH, srcW, srcH, 1);
        float v0 = float(src.read(uint2(g0)).r) * p.scale;
        float v1 = float(src.read(uint2(g1)).r) * p.scale;
        v = 0.5 * (v0 + v1);
    } else {
        int2 site = bayer_channel_site_u(cell, p.pattern, p.channel, dstW, dstH, srcW, srcH, 0);
        v = float(src.read(uint2(site)).r) * p.scale;
    }

    dst.write(float4(v, v, v, 1.0), gid);
}

/// 8-bit Bayer source → half-res mono-replicated rgba32Float channel plane.
kernel void unpack_bayer8_channel_to_rgba(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant BayerChannelParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    int srcW = int(src.get_width());
    int srcH = int(src.get_height());
    int dstW = int(dst.get_width());
    int dstH = int(dst.get_height());

    int2 cell = int2(gid);
    if (p.flip != 0u) {
        cell = int2(dstW - 1 - cell.x, dstH - 1 - cell.y);
    }

    float v;
    if (p.channel == 1u) {
        int2 g0 = bayer_channel_site_u(cell, p.pattern, 1u, dstW, dstH, srcW, srcH, 0);
        int2 g1 = bayer_channel_site_u(cell, p.pattern, 1u, dstW, dstH, srcW, srcH, 1);
        float v0 = src.read(uint2(g0)).r;
        float v1 = src.read(uint2(g1)).r;
        v = 0.5 * (v0 + v1);
    } else {
        int2 site = bayer_channel_site_u(cell, p.pattern, p.channel, dstW, dstH, srcW, srcH, 0);
        v = src.read(uint2(site)).r;
    }

    dst.write(float4(v, v, v, 1.0), gid);
}

/// Combine three half-res mono-replicated stacks (R, G, B) into one
/// full-res rgba32Float output. Reads `.r` from each input plane (the
/// channel value was replicated into all four components by the
/// channel-extract kernel and preserved through quality-weighted
/// accumulation).
///
/// **Geometric correctness — per-channel sampling offsets:**
/// Within every 2×2 Bayer cell, R and B sit at diagonally opposite
/// corners (1 raw-pixel diagonal apart) and G is split between the
/// remaining two corners. The channel-extract kernel collapses each
/// 2×2 cell to ONE half-res pixel, so the half-res value for R at
/// half-cell (cx, cy) physically came from raw site
/// (2cx + rOff.x, 2cy + rOff.y) while B's half-res pixel (cx, cy)
/// physically came from raw site (2cx + 1 - rOff.x, 2cy + 1 - rOff.y),
/// and G's averaged centre sits at raw (2cx + 0.5, 2cy + 0.5).
///
/// If we sample all three channels at the same half-res coordinate
/// for a given full-res output pixel (the v0 bug), R from raw (0,0)
/// gets combined with B from raw (1,1) at output pixel (0,0) → a
/// 1-pixel diagonal mismatch between R and B that shows as visible
/// color fringing. Fix: each channel uses a different sub-pixel
/// sampling offset so that for every full-res output pixel (x, y),
/// the sampled R value comes from the same raw-coord neighbourhood
/// as the sampled B value.
///
/// For Bayer pattern with R offset `rOff` (0..1, 0..1), full-res
/// output (x, y) maps to half-res lookups at:
///   R   : (x - rOff.x,           y - rOff.y          ) / 2
///   B   : (x - (1 - rOff.x),     y - (1 - rOff.y)    ) / 2
///   G   : (x - 0.5,              y - 0.5             ) / 2
struct LuckyCombineParams {
    uint pattern;   // 0..3, RGGB/GRBG/GBRG/BGGR
};

inline float sample_bilinear_half(
    texture2d<float, access::read> tex,
    float2 fx,
    int halfW, int halfH
) {
    int x0 = clamp(int(floor(fx.x)), 0, halfW - 1);
    int y0 = clamp(int(floor(fx.y)), 0, halfH - 1);
    int x1 = clamp(x0 + 1,           0, halfW - 1);
    int y1 = clamp(y0 + 1,           0, halfH - 1);
    float wx = clamp(fx.x - float(x0), 0.0, 1.0);
    float wy = clamp(fx.y - float(y0), 0.0, 1.0);
    float v00 = tex.read(uint2(x0, y0)).r;
    float v10 = tex.read(uint2(x1, y0)).r;
    float v01 = tex.read(uint2(x0, y1)).r;
    float v11 = tex.read(uint2(x1, y1)).r;
    return mix(mix(v00, v10, wx), mix(v01, v11, wx), wy);
}

kernel void lucky_combine_channel_planes(
    texture2d<float, access::read>  redPlane   [[texture(0)]],
    texture2d<float, access::read>  greenPlane [[texture(1)]],
    texture2d<float, access::read>  bluePlane  [[texture(2)]],
    texture2d<float, access::write> dst        [[texture(3)]],
    constant LuckyCombineParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    int halfW = int(redPlane.get_width());
    int halfH = int(redPlane.get_height());

    float rOffX = float(p.pattern & 1u);
    float rOffY = float((p.pattern >> 1) & 1u);

    float fx = float(gid.x);
    float fy = float(gid.y);

    // R sampled where R's source sites live (rOffX, rOffY within each cell).
    float2 fxR = float2((fx - rOffX) * 0.5, (fy - rOffY) * 0.5);
    // B sampled at the diagonally-opposite corner.
    float2 fxB = float2((fx - (1.0 - rOffX)) * 0.5, (fy - (1.0 - rOffY)) * 0.5);
    // G sampled at the cell-centre (the average of the two G sites).
    float2 fxG = float2((fx - 0.5) * 0.5, (fy - 0.5) * 0.5);

    float r = sample_bilinear_half(redPlane,   fxR, halfW, halfH);
    float g = sample_bilinear_half(greenPlane, fxG, halfW, halfH);
    float b = sample_bilinear_half(bluePlane,  fxB, halfW, halfH);

    dst.write(float4(r, g, b, 1.0), gid);
}

// MARK: - Tiled-deconv mask blend (Block C.3 v0)
//
// Reads a (apGrid × apGrid) per-cell mask `m ∈ [0, 1]` and blends
// `base` (pre-deconv) with `deconv` (post-Wiener) per pixel:
//
//   output = mix(base, deconv, m_sampled_at_pixel)
//
// Cell coords are bilinear-sampled for smooth tile boundaries.
// `m = 0` → output is base (skip deconv on background tiles);
// `m = 1` → output is deconv (full deconv on bright surface tiles);
// `m = 0.5` → 50/50 blend (limb / featureless surface — gentle
// deconv to avoid ringing without losing all structure).
//
// Cell coordinates are computed as `(pixel + 0.5) / cellSize - 0.5`
// so the centre of each cell aligns with integer mask sample
// positions — exactly the same convention the per-channel combine
// kernel uses to align Bayer half-res samples.

struct LuckyMaskBlendParams {
    uint apGrid;        // edge length of the mask (apGrid × apGrid)
};

kernel void lucky_mask_blend(
    texture2d<float, access::read>  baseTex   [[texture(0)]],
    texture2d<float, access::read>  deconvTex [[texture(1)]],
    texture2d<float, access::read>  maskTex   [[texture(2)]],
    texture2d<float, access::write> output    [[texture(3)]],
    constant LuckyMaskBlendParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float W = float(output.get_width());
    float H = float(output.get_height());
    float cellW = W / float(p.apGrid);
    float cellH = H / float(p.apGrid);

    float fx = (float(gid.x) + 0.5) / cellW - 0.5;
    float fy = (float(gid.y) + 0.5) / cellH - 0.5;

    int gMax = int(p.apGrid) - 1;
    int x0 = clamp(int(floor(fx)), 0, gMax);
    int y0 = clamp(int(floor(fy)), 0, gMax);
    int x1 = clamp(x0 + 1,         0, gMax);
    int y1 = clamp(y0 + 1,         0, gMax);
    float wx = clamp(fx - float(x0), 0.0, 1.0);
    float wy = clamp(fy - float(y0), 0.0, 1.0);

    float m00 = maskTex.read(uint2(x0, y0)).r;
    float m10 = maskTex.read(uint2(x1, y0)).r;
    float m01 = maskTex.read(uint2(x0, y1)).r;
    float m11 = maskTex.read(uint2(x1, y1)).r;
    float m = mix(mix(m00, m10, wx), mix(m01, m11, wx), wy);

    float4 base   = baseTex  .read(gid);
    float4 deconv = deconvTex.read(gid);
    output.write(mix(base, deconv, m), gid);
}

// MARK: - Radial deconv-fade (Gibbs ringing fix near disc limb)
//
// Wiener deconvolution at high SNR amplifies high frequencies
// aggressively. Near a sharp limb (bright disc / dark sky) the
// inverse filter's neighbourhood spans both regions — it "creates"
// a dark ring just inside the limb as Gibbs overshoot, trying to
// compensate for what it thinks was blurred out into space. Most
// visible on small high-contrast subjects (Mars).
//
// Fix: AutoPSF already gives us the disc centre + radius. Build a
// radial mask that fades deconv strength to zero before reaching
// the limb. Inner disc gets full deconv (sharp), outer ring smoothly
// blends back to the pre-deconv (bare) input, beyond the disc is
// pure bare. The trade-off the user accepts: inner sharper than
// outer, but no ringing.
//
//   r < innerRadius                   → m = 1   (full deconv)
//   innerRadius ≤ r ≤ outerRadius      → m = smooth fade 1 → 0
//   r > outerRadius                   → m = 0   (pre / bare)
//
// Defaults from AutoPSF result: innerRadius = 0.65 × discRadius,
// outerRadius = 1.05 × discRadius. The slight extension past the
// disc covers the limb itself with a touch of deconv (bright detail
// right at the edge) without amplifying the discontinuity.

struct LuckyRadialMaskParams {
    float2 center;         // disc centroid (output pixel coords)
    float  innerRadius;    // m=1 inside this radius
    float  outerRadius;    // m=0 outside this radius
};

kernel void lucky_radial_deconv_blend(
    texture2d<float, access::read>  baseTex   [[texture(0)]],
    texture2d<float, access::read>  deconvTex [[texture(1)]],
    texture2d<float, access::write> output    [[texture(2)]],
    constant LuckyRadialMaskParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float dx = float(gid.x) - p.center.x;
    float dy = float(gid.y) - p.center.y;
    float r  = sqrt(dx * dx + dy * dy);

    // Smooth fade. Use smoothstep on a normalised parameter so we get
    // a Hermite cubic transition (zero derivative at both ends — no
    // sharp blend boundary that would itself produce a thin ring).
    float band = max(p.outerRadius - p.innerRadius, 1e-3);
    float t = clamp((r - p.innerRadius) / band, 0.0, 1.0);
    float m = 1.0 - smoothstep(0.0, 1.0, t);

    float4 base   = baseTex  .read(gid);
    float4 deconv = deconvTex.read(gid);
    output.write(mix(base, deconv, m), gid);
}

// MARK: - Quality grading
//
// Per-frame quality scoring via Diagonal Laplacian (LAPD) variance,
// reduced threadgroup-locally. Each group emits one (sum, sumSq, count)
// triple to a flat partials buffer indexed by frame; final variance
// resolves on CPU. Avoids cross-frame syncs entirely.
//
// LAPD vs the 4-neighbour cross Laplacian: LAPD samples both cardinal
// AND diagonal neighbours, weighted by 1/distance² (cardinal=1.0,
// diagonal=0.5). This makes the operator more rotation-invariant —
// 4-neighbour cross sees diagonal edges as "blurred" because the
// kernel doesn't sample along the edge direction. For planetary work
// this matters: Jupiter's NEB and SEB are roughly horizontal, but Mars
// surface features and lunar terminator gradients hit every angle.
// MDPI 2076-3417/13/4/2652 reports LAPD outperforms VL in seeing-
// limited regimes — exactly our domain.

struct QualityPartial {
    float sum;
    float sumSq;
    uint  count;
    uint  pad;
};

inline float luma_lq(float4 c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// LAPD (Diagonal Laplacian): isotropic 8-neighbour second-derivative
/// discretisation. Cardinal neighbours weight 1.0 (distance 1), diagonal
/// neighbours weight 0.5 (distance √2 → 1/d² = 0.5). Centre coefficient
/// is -(4·1 + 4·0.5) = -6 so the kernel sums to zero on a constant
/// field — uniform regions correctly score 0.
inline float laplacian_at(texture2d<float, access::read> tex, uint2 gid) {
    uint W = tex.get_width(), H = tex.get_height();
    if (gid.x == 0 || gid.y == 0 || gid.x + 1 >= W || gid.y + 1 >= H) return 0.0;
    float c  = luma_lq(tex.read(gid));
    float l  = luma_lq(tex.read(uint2(gid.x - 1, gid.y)));
    float r  = luma_lq(tex.read(uint2(gid.x + 1, gid.y)));
    float t  = luma_lq(tex.read(uint2(gid.x,     gid.y - 1)));
    float b  = luma_lq(tex.read(uint2(gid.x,     gid.y + 1)));
    float tl = luma_lq(tex.read(uint2(gid.x - 1, gid.y - 1)));
    float tr = luma_lq(tex.read(uint2(gid.x + 1, gid.y - 1)));
    float bl = luma_lq(tex.read(uint2(gid.x - 1, gid.y + 1)));
    float br = luma_lq(tex.read(uint2(gid.x + 1, gid.y + 1)));
    return (l + r + t + b) + 0.5 * (tl + tr + bl + br) - 6.0 * c;
}

/// Per-pixel LAPD field — used by SharpnessProbe to feed
/// MPSImageStatisticsMeanAndVariance. Mirrors `laplacian_at` exactly so
/// the HUD probe and the bulk lucky-stack grader produce comparable
/// numbers.
kernel void compute_lapd_field(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float v = laplacian_at(src, gid);
    dst.write(float4(v, v, v, 1.0), gid);
}

kernel void quality_partials(
    texture2d<float, access::read>   src      [[texture(0)]],
    device QualityPartial*           partials [[buffer(0)]],
    constant uint&                   frameIndex     [[buffer(1)]],
    constant uint&                   groupsPerFrame [[buffer(2)]],
    uint2 gid       [[thread_position_in_grid]],
    uint  tIndex    [[thread_index_in_threadgroup]],
    uint2 gIndex    [[threadgroup_position_in_grid]],
    uint2 gridDim   [[threadgroups_per_grid]]
) {
    threadgroup float sumStore[256];
    threadgroup float sumSqStore[256];
    threadgroup uint  countStore[256];

    bool inBounds = (gid.x < src.get_width() && gid.y < src.get_height());
    float v = inBounds ? laplacian_at(src, gid) : 0.0;
    sumStore[tIndex]   = v;
    sumSqStore[tIndex] = v * v;
    countStore[tIndex] = inBounds ? 1u : 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (tIndex < stride) {
            sumStore[tIndex]   += sumStore[tIndex + stride];
            sumSqStore[tIndex] += sumSqStore[tIndex + stride];
            countStore[tIndex] += countStore[tIndex + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tIndex == 0) {
        uint groupLinear = gIndex.y * gridDim.x + gIndex.x;
        uint outIdx = frameIndex * groupsPerFrame + groupLinear;
        QualityPartial r;
        r.sum   = sumStore[0];
        r.sumSq = sumSqStore[0];
        r.count = countStore[0];
        r.pad   = 0;
        partials[outIdx] = r;
    }
}

// MARK: - Phase-correlation luma extraction
//
// Lucky-stack alignment runs on a downsampled luminance buffer (256² typical)
// so the FFT cost stays bounded for 5000-frame sequences. This kernel does
// centre-fit downsample + grayscale-conversion in one pass.

kernel void extract_luma_downsample(
    texture2d<float, access::sample>  src     [[texture(0)]],
    device float*                     dst     [[buffer(0)]],
    constant uint2&                   dstSize [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dstSize.x || gid.y >= dstSize.y) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(dstSize);
    float4 c = src.sample(s, uv);
    dst[gid.y * dstSize.x + gid.x] = luma_lq(c);
}

// MARK: - Lucky-stack accumulators
//
// Quality-weighted: dst += frame * weight, with a parallel weight-sum buffer
// updated separately. After all frames have been added, a final normalize
// kernel divides by total weight.

struct LuckyAccumParams {
    float weight;
    float2 shift;        // sub-pixel shift to apply during sample
};

kernel void lucky_accumulate(
    texture2d<float, access::sample>     frame  [[texture(0)]],
    texture2d<float, access::read_write> accum  [[texture(1)]],
    constant LuckyAccumParams&           p      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5 - p.shift) / float2(accum.get_width(), accum.get_height());
    float4 v = frame.sample(s, uv);
    float4 a = accum.read(gid);
    accum.write(a + v * p.weight, gid);
}

struct LuckyNormalizeParams {
    float invTotalWeight;
};

kernel void lucky_normalize(
    texture2d<float, access::read_write> accum [[texture(0)]],
    constant LuckyNormalizeParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    float4 a = accum.read(gid);
    accum.write(float4(clamp(a.rgb * p.invTotalWeight, 0.0, 1.0), 1.0), gid);
}

// MARK: - Multi-AP local alignment (Scientific mode)
//
// Approach: 8×8 grid of alignment points across the frame. For each AP, we
// brute-force a small SAD (sum-of-absolute-differences) search over a ±8 px
// window against the reference, after a global pre-shift has already been
// applied. The result is an 8×8 RG32Float `shiftMap` that the local
// accumulator bilinearly samples for sub-grid pixel precision.
//
// One threadgroup per AP; each thread evaluates one search candidate and the
// group reduces to find the argmin.

struct APSearchParams {
    uint  patchHalf;       // patch radius (e.g. 8)
    int   searchRadius;    // candidate search radius (e.g. 8)
    uint2 gridSize;        // (8, 8)
    float2 globalShift;    // already-applied per-frame translation
};

kernel void compute_ap_shifts(
    texture2d<float, access::read>    ref      [[texture(0)]],
    texture2d<float, access::sample>  frame    [[texture(1)]],
    texture2d<float, access::write>   shiftMap [[texture(2)]],
    constant APSearchParams& p [[buffer(0)]],
    uint apIndex     [[threadgroup_position_in_grid]],
    uint candIndex   [[thread_index_in_threadgroup]],
    uint tgSize      [[threads_per_threadgroup]]
) {
    int range = 2 * p.searchRadius + 1;
    int total = range * range;

    threadgroup float bestSAD[1024];
    threadgroup int   bestIdx[1024];
    // Preserved copy of every candidate's SAD for the post-reduction sub-
    // pixel parabolic fit. The reduction overwrites bestSAD as it works,
    // so without this we'd lose the SAD values for the integer winner's
    // neighbours and couldn't refine below pixel precision.
    threadgroup float sadGrid[1024];

    // Initialize ALL 1024 slots so the reduction's stride=512 step reads
    // valid data even when the dispatched threadgroup is smaller than 1024
    // (e.g. 512 threads for searchRadius=8). Each thread is responsible for
    // a stride-of-tgSize slice of the array.
    for (uint i = candIndex; i < 1024; i += tgSize) {
        bestSAD[i] = 1e30;
        bestIdx[i] = int(i);
        sadGrid[i] = 1e30;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int candX = (int(candIndex) % range) - p.searchRadius;
    int candY = (int(candIndex) / range) - p.searchRadius;

    uint apX = apIndex % p.gridSize.x;
    uint apY = apIndex / p.gridSize.x;

    int W = int(ref.get_width()), H = int(ref.get_height());
    int cx = int(float(W) * (float(apX) + 0.5) / float(p.gridSize.x));
    int cy = int(float(H) * (float(apY) + 0.5) / float(p.gridSize.y));

    constexpr sampler smp_lin(address::clamp_to_edge, filter::linear);
    float sad = 1e30;
    if (int(candIndex) < total) {
        sad = 0.0;
        int hp = int(p.patchHalf);
        // Two corrections vs the previous SAD:
        //
        // 1. Use the FULL float globalShift instead of round(globalShift).
        //    The previous int-rounded version threw away the fractional
        //    pixel of phase-corr precision INSIDE the search, so the
        //    "winning" local shift encoded that lost fraction on top of
        //    any true atmospheric local shift.
        //
        // 2. Match lucky_accumulate_local's sign convention. That kernel
        //    samples frame at `gid - (global + local)`. The previous SAD
        //    sampled frame at `rx + cand + global` — opposite sign. The
        //    "best" cand from that SAD therefore minimised SAD against a
        //    DIFFERENT location than the accumulator later reads from, so
        //    the local shift was being applied with the wrong sign in
        //    every frame. With sub-pixel global shifts this misaligned
        //    every AP cell by ~2× the global shift, producing the visible
        //    smear that made `--mode scientific --multi-ap` worse than
        //    the standard single-shift accumulator.
        //
        // Both texture reads now use the linear sampler so sub-pixel
        // candidate positions don't bias the SAD.
        for (int py = -hp; py < hp; py += 2) {
            for (int px = -hp; px < hp; px += 2) {
                int rx = cx + px, ry = cy + py;
                if (rx < 0 || rx >= W || ry < 0 || ry >= H) continue;
                float fx_f = float(rx) - p.globalShift.x - float(candX);
                float fy_f = float(ry) - p.globalShift.y - float(candY);
                if (fx_f < 0.5 || fx_f >= float(W) - 0.5 ||
                    fy_f < 0.5 || fy_f >= float(H) - 0.5) continue;
                float r = ref.read(uint2(rx, ry)).r;
                float2 fuv = (float2(fx_f, fy_f) + 0.5) / float2(W, H);
                float f = frame.sample(smp_lin, fuv).r;
                sad += abs(r - f);
            }
        }
    }

    bestSAD[candIndex] = sad;
    bestIdx[candIndex] = int(candIndex);
    // sadGrid is the immutable SAD-per-candidate snapshot the parabolic
    // fit needs to look up. It mirrors bestSAD pre-reduction.
    if (int(candIndex) < total) {
        sadGrid[candIndex] = sad;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Reduction (assumes threadgroup size is a power of 2 ≥ total).
    for (uint stride = 512; stride > 0; stride >>= 1) {
        if (candIndex < stride && (candIndex + stride) < 1024) {
            if (bestSAD[candIndex + stride] < bestSAD[candIndex]) {
                bestSAD[candIndex] = bestSAD[candIndex + stride];
                bestIdx[candIndex] = bestIdx[candIndex + stride];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (candIndex == 0) {
        int winnerIdx = bestIdx[0];
        int wxi = winnerIdx % range;
        int wyi = winnerIdx / range;
        int wx = wxi - p.searchRadius;
        int wy = wyi - p.searchRadius;
        float winnerSAD = bestSAD[0];

        // AP-confidence gate. On smooth subjects (Jupiter cloud bands away
        // from the GRS, planetary disc interior) every SAD candidate has
        // a similar value because there's no high-frequency feature for
        // SAD to lock onto — the "winner" is just the offset that
        // happened to minimise pixel-difference noise. Trusting that
        // shift adds noise to the accumulator rather than refining the
        // alignment, which is exactly the v4_C-worse-than-v4_B regression
        // we saw on this Jupiter SER.
        //
        // Compute the mean SAD across all valid candidates; if the
        // winner isn't at least `minDepth` below the mean, write a zero
        // local shift (the AP cell has no usable signal — fall back to
        // the global phase-corr alignment). This is exactly PSS / AS!4's
        // AP rejection rule.
        float meanSAD = 0.0;
        int validCount = 0;
        for (int i = 0; i < total; i++) {
            float s = sadGrid[i];
            if (s < 1e29) { meanSAD += s; validCount++; }
        }
        meanSAD = (validCount > 0) ? (meanSAD / float(validCount)) : 1.0;
        // confidence = how much deeper the winner is vs mean SAD.
        // 0.10 = winner at least 10% below mean. Smooth Jupiter cells
        // typically score < 0.05 → rejected; lunar-surface cells with
        // craters score > 0.30 → kept. Threshold gentle enough that
        // strong-feature regions still benefit from local refinement.
        const float minDepth = 0.10;
        float depth = (meanSAD > 1e-6) ? (1.0 - winnerSAD / meanSAD) : 0.0;
        if (depth < minDepth) {
            shiftMap.write(float4(0, 0, 0, 0), uint2(apX, apY));
            return;
        }

        // Sub-pixel parabolic refinement of the integer SAD minimum. The
        // SAD surface in a small neighbourhood of the true offset is well-
        // approximated by a 2nd-order polynomial; fitting a 1D parabola
        // through the integer winner and its left/right (and up/down)
        // neighbours gives a fractional offset to ~0.1 px on smooth
        // subjects. Clamped to ±0.5 to reject ill-conditioned fits at the
        // search-window boundary.
        float subX = 0.0;
        float subY = 0.0;
        if (wxi > 0 && wxi < range - 1) {
            float c = sadGrid[wyi * range + wxi];
            float l = sadGrid[wyi * range + (wxi - 1)];
            float r = sadGrid[wyi * range + (wxi + 1)];
            float denom = (l - 2.0 * c + r);
            if (abs(denom) > 1e-8) {
                subX = clamp(0.5 * (l - r) / denom, -0.5, 0.5);
            }
        }
        if (wyi > 0 && wyi < range - 1) {
            float c = sadGrid[wyi * range + wxi];
            float u = sadGrid[(wyi - 1) * range + wxi];
            float d = sadGrid[(wyi + 1) * range + wxi];
            float denom = (u - 2.0 * c + d);
            if (abs(denom) > 1e-8) {
                subY = clamp(0.5 * (u - d) / denom, -0.5, 0.5);
            }
        }
        shiftMap.write(float4(float(wx) + subX, float(wy) + subY, 0, 0), uint2(apX, apY));
    }
}

// Variant of `lucky_accumulate` that adds a bilinearly-sampled local shift
// from an 8×8 shift map on top of the global shift in `LuckyAccumParams`.
struct LuckyAccumLocalParams {
    float weight;
    float2 globalShift;
};

kernel void lucky_accumulate_local(
    texture2d<float, access::sample>     frame    [[texture(0)]],
    texture2d<float, access::read_write> accum    [[texture(1)]],
    texture2d<float, access::sample>     shiftMap [[texture(2)]],
    constant LuckyAccumLocalParams&      p        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    constexpr sampler smp(address::clamp_to_edge, filter::linear);
    float2 imgUV = (float2(gid) + 0.5) / float2(accum.get_width(), accum.get_height());
    float4 mapVal = shiftMap.sample(smp, imgUV);
    float2 totalShift = p.globalShift + float2(mapVal.r, mapVal.g);
    float2 sampleUV = (float2(gid) + 0.5 - totalShift) / float2(accum.get_width(), accum.get_height());
    float4 v = frame.sample(smp, sampleUV);
    float4 a = accum.read(gid);
    accum.write(a + v * p.weight, gid);
}

// MARK: - Per-AP quality grading (A.2)
//
// Two-stage quality: pass 1 grades each frame's whole-image LAPD
// variance (existing `quality_partials` kernel), pass 2 grades each
// AP cell separately. Different cells pick different "best" frames
// — the limb-sharp / band-blurred / surface-detail-good frame each
// land in their respective AP keep sets. Output is one variance
// score per (frame, AP) pair, written into a flat buffer.
//
// Buffer layout (frame-major, AP-minor):
//   perAPVariance[frameIndex * apGridSize² + apY * apGridSize + apX]
//
// CPU then sorts per-AP, picks top-k frames per AP, and emits a
// keep-mask buffer the per-AP accumulator consumes.
//
// One threadgroup per AP cell. Each thread strides over a slice of
// the cell's pixels, computing LAPD per pixel and contributing to a
// threadgroup-local sum + sumSq for variance reduction. tgSize must
// be ≤ 256 (matches the threadgroup-local arrays).

struct PerAPQualityParams {
    uint frameIndex;
    uint apGridSize;
    uint pad0;
    uint pad1;
};

kernel void quality_partials_per_ap(
    texture2d<float, access::read> src [[texture(0)]],
    device float* perAPVariance        [[buffer(0)]],
    constant PerAPQualityParams& p     [[buffer(1)]],
    uint  apLinear [[threadgroup_position_in_grid]],
    uint  tIndex   [[thread_index_in_threadgroup]],
    uint  tgSize   [[threads_per_threadgroup]]
) {
    // 1D dispatch over linear AP index — Metal requires the
    // [[threadgroup_position_in_grid]] and [[thread_index_in_threadgroup]]
    // attributes to share dimensionality, and `compute_ap_shifts` in
    // this file already established the 1D convention. Decode (x, y)
    // from the linear index here.
    uint W = src.get_width(), H = src.get_height();
    uint apTotal = p.apGridSize * p.apGridSize;
    if (apLinear >= apTotal) return;
    uint apX = apLinear % p.apGridSize;
    uint apY = apLinear / p.apGridSize;
    uint cellW = W / p.apGridSize;
    uint cellH = H / p.apGridSize;
    uint x0 = apX * cellW;
    uint y0 = apY * cellH;

    threadgroup float sumStore[256];
    threadgroup float sumSqStore[256];
    threadgroup uint  countStore[256];

    float localSum = 0;
    float localSumSq = 0;
    uint  localCount = 0;

    uint cellPixels = cellW * cellH;
    for (uint i = tIndex; i < cellPixels; i += tgSize) {
        uint cx = i % cellW;
        uint cy = i / cellW;
        uint2 gid(x0 + cx, y0 + cy);
        // laplacian_at returns 0 on the 1-px border so we don't have
        // to pre-filter here.
        float v = laplacian_at(src, gid);
        localSum   += v;
        localSumSq += v * v;
        localCount += 1;
    }

    // Initialise every slot so the stride-128 reduction is well-
    // defined for tgSize values smaller than 256.
    for (uint i = tIndex; i < 256; i += tgSize) {
        sumStore[i]   = 0;
        sumSqStore[i] = 0;
        countStore[i] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tIndex < 256) {
        sumStore[tIndex]   = localSum;
        sumSqStore[tIndex] = localSumSq;
        countStore[tIndex] = localCount;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (tIndex < stride) {
            sumStore[tIndex]   += sumStore[tIndex + stride];
            sumSqStore[tIndex] += sumSqStore[tIndex + stride];
            countStore[tIndex] += countStore[tIndex + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tIndex == 0) {
        float n = float(countStore[0]);
        float variance = 0;
        if (n > 0) {
            float mean = sumStore[0] / n;
            variance = (sumSqStore[0] / n) - mean * mean;
            if (variance < 0) variance = 0;
        }
        uint outIdx = p.frameIndex * apTotal + apLinear;
        perAPVariance[outIdx] = variance;
    }
}

// Per-AP keep-mask accumulator with raised-cosine AP blending (A.2 + B.2).
//
// Each output pixel reads the keep flags from the FOUR nearest AP
// cells and blends them with a raised-cosine weight profile based on
// sub-cell position. AP centres land on integer coords of the
// (gridSize × gridSize) grid; pixels at AP centres get full
// contribution from one cell only, pixels at AP boundaries get a
// smooth blend across cells.
//
// B.2 feathering: per-axis weights use `0.5·(1+cos(π·d))` for d ∈ [0,1]
// instead of the original bilinear `1-d` / `d`. The raised-cosine
// profile has continuous derivatives both at the AP centre (d=0) and
// at the neighbour's centre (d=1), eliminating the tent-shape kinks
// that produced visible quilting on Jupiter zone boundaries with the
// bilinear blend. Sum-to-1 invariant preserved (cos(π·d) + cos(π·(1−d))
// = 0, so the four corner weights still tile cleanly).
//
// The implicit feather radius equals 0.5 × cellSpacing — wider than
// BiggSky's documented 0.25 × AP_size default, but BiggSky-compatible
// because their narrower feather is normalised against accumulated
// weight which we already do via wtTex. Wider feather = more frame
// overlap per pixel = better SNR averaging.
//
// CPU reference for the weight curve: `APFeather.cosineWeight`.
//
// effectiveKeep = Σᵢ keep[apᵢ, frame] × cosineWeight[apᵢ]
//                ∈ [0, 1]
//
// The per-pixel weight texture accumulates `effectiveKeep × weight`
// across frames so the final divide produces a clean mean even
// where neighbouring APs picked different frame counts.

struct LuckyPerAPParams {
    float  weight;
    uint   apGridSize;
    uint   frameIndex;
    uint   frameCount;
    float2 shift;
    float2 pad0;
};

kernel void lucky_accumulate_per_ap_keep(
    texture2d<float, access::sample>     frame    [[texture(0)]],
    texture2d<float, access::read_write> accum    [[texture(1)]],
    texture2d<float, access::read_write> wtTex    [[texture(2)]],
    device const float*                  keepMask [[buffer(0)]],
    constant LuckyPerAPParams&           p        [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = accum.get_width(), H = accum.get_height();
    if (gid.x >= W || gid.y >= H) return;
    if (p.apGridSize == 0) return;

    // Position in AP-grid space (sub-cell coords). The "-0.5" shift
    // lines AP centres up with integer coords of this space, so the
    // four nearest APs are at (floor(fx), floor(fy)) and its three
    // neighbours.
    float gridF = float(p.apGridSize);
    float fx = (float(gid.x) + 0.5) * gridF / float(W) - 0.5;
    float fy = (float(gid.y) + 0.5) * gridF / float(H) - 0.5;
    int apX0 = int(floor(fx));
    int apY0 = int(floor(fy));
    float dx = fx - float(apX0);
    float dy = fy - float(apY0);
    int gridMax = int(p.apGridSize) - 1;
    int x0c = clamp(apX0,     0, gridMax);
    int y0c = clamp(apY0,     0, gridMax);
    int x1c = clamp(apX0 + 1, 0, gridMax);
    int y1c = clamp(apY0 + 1, 0, gridMax);

    // Raised-cosine weights for the 4 surrounding APs (sum to 1). Per-axis
    // contribution: `0.5·(1+cos(π·d))` at the near corner, `0.5·(1-cos(π·d))`
    // at the far corner. Identity `cos(π·(1-d)) = -cos(π·d)` keeps the
    // partition-of-unity property the bilinear blend relied on.
    float cx = cos(M_PI_F * dx);
    float cy = cos(M_PI_F * dy);
    float fx0 = 0.5 * (1.0 + cx);    // weight toward AP at apX0  (near in x)
    float fx1 = 0.5 * (1.0 - cx);    // weight toward AP at apX0+1 (far in x)
    float fy0 = 0.5 * (1.0 + cy);    // weight toward AP at apY0  (near in y)
    float fy1 = 0.5 * (1.0 - cy);    // weight toward AP at apY0+1 (far in y)
    float w00 = fx0 * fy0;
    float w10 = fx1 * fy0;
    float w01 = fx0 * fy1;
    float w11 = fx1 * fy1;

    // Look up keep flags. Buffer layout: [apLinear × frameCount + frameIndex].
    uint frameC = p.frameCount;
    float k00 = keepMask[(uint(y0c) * p.apGridSize + uint(x0c)) * frameC + p.frameIndex];
    float k10 = keepMask[(uint(y0c) * p.apGridSize + uint(x1c)) * frameC + p.frameIndex];
    float k01 = keepMask[(uint(y1c) * p.apGridSize + uint(x0c)) * frameC + p.frameIndex];
    float k11 = keepMask[(uint(y1c) * p.apGridSize + uint(x1c)) * frameC + p.frameIndex];

    float effectiveKeep = k00 * w00 + k10 * w10 + k01 * w01 + k11 * w11;
    if (effectiveKeep <= 0.0) return;

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5 - p.shift) / float2(W, H);
    float4 v = frame.sample(s, uv);
    float blended = p.weight * effectiveKeep;
    accum.write(accum.read(gid) + v * blended, gid);
    wtTex.write(wtTex.read(gid) + float4(blended), gid);
}

// MARK: - Sigma-clipped stacking (B.1)
//
// Two-pass robust outlier rejection. Cosmic rays, hot pixels, the
// occasional satellite trail or wind-jolted frame all produce per-
// pixel outliers that contaminate a plain weighted mean. Sigma-
// clipping rejects them.
//
//   Pass 1 (Welford): for each kept frame, update a per-pixel
//     running mean μ and sum-of-squared-deviations M2 in two rgba32-
//     Float scratch textures. After N frames, the per-pixel
//     population variance σ² = M2 / N.
//
//   Pass 2 (clipped accumulate): for each frame, sample v at the
//     same shift used in pass 1; per channel, include v in the
//     output only when (v - μ)² ≤ k²·σ². Quality-weighted just like
//     the existing accumulator, but a per-pixel weight texture
//     tracks how many frames actually contributed.
//
// Final normalize: out = clippedAccum / clippedWeight per pixel,
// clamped to [0, 1] for display. Pixels never written to (extreme
// edge case where every frame's contribution clipped) fall back to
// 0 via the tiny weightFloor epsilon.
//
// CPU reference: Engine/Pipeline/SigmaClip.swift::clippedMean.

struct LuckyWelfordParams {
    uint   frameNumber;   // 1-based count of this Welford step
    float  pad0;
    float2 shift;
};

kernel void lucky_welford_step(
    texture2d<float, access::sample>     frame   [[texture(0)]],
    texture2d<float, access::read_write> meanTex [[texture(1)]],
    texture2d<float, access::read_write> m2Tex   [[texture(2)]],
    constant LuckyWelfordParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = meanTex.get_width(), H = meanTex.get_height();
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5 - p.shift) / float2(W, H);
    float4 v = frame.sample(s, uv);

    float4 mOld  = meanTex.read(gid);
    float4 m2Old = m2Tex.read(gid);
    float n = float(p.frameNumber);
    float4 delta = v - mOld;
    float4 mNew  = mOld + delta / n;
    float4 dn    = v - mNew;
    float4 m2New = m2Old + delta * dn;
    meanTex.write(mNew, gid);
    m2Tex.write(m2New, gid);
}

struct LuckyClipParams {
    float  weight;
    float  sigmaThreshold;
    uint   frameCount;       // total frames in pass 1 — σ² = M2 / N
    float  pad0;
    float2 shift;
    float2 pad1;
};

kernel void lucky_accumulate_clipped(
    texture2d<float, access::sample>     frame   [[texture(0)]],
    texture2d<float, access::read>       meanTex [[texture(1)]],
    texture2d<float, access::read>       m2Tex   [[texture(2)]],
    texture2d<float, access::read_write> accum   [[texture(3)]],
    texture2d<float, access::read_write> wtTex   [[texture(4)]],
    constant LuckyClipParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = accum.get_width(), H = accum.get_height();
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5 - p.shift) / float2(W, H);
    float4 v = frame.sample(s, uv);

    float4 m  = meanTex.read(gid);
    float4 m2 = m2Tex.read(gid);
    float n = max(1.0, float(p.frameCount));
    float4 var = m2 / n;
    // Per-channel cutoff: (v - m)² ≤ k²·σ²
    float kSq = p.sigmaThreshold * p.sigmaThreshold;
    float4 cutoffSq = kSq * var;
    float4 dev = v - m;
    float4 devSq = dev * dev;
    // mask = 1 where keep (devSq ≤ cutoffSq), 0 where clip. step()
    // returns 1 at the boundary, so a sample exactly k·σ away is kept.
    // When σ² = 0 (all samples identical), cutoffSq = 0; only samples
    // exactly equal to m pass — that's the right behaviour for a
    // degenerate-variance pixel.
    float4 mask = step(devSq, cutoffSq);

    float4 contribution = mask * v * p.weight;
    float4 weightAdd    = mask * p.weight;
    accum.write(accum.read(gid) + contribution, gid);
    wtTex.write(wtTex.read(gid) + weightAdd, gid);
}

struct LuckyDivideParams {
    float weightFloor;   // tiny epsilon to avoid /0 on never-written pixels
};

kernel void lucky_normalize_per_pixel(
    texture2d<float, access::read_write> accum [[texture(0)]],
    texture2d<float, access::read>       wtTex [[texture(1)]],
    constant LuckyDivideParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = accum.get_width(), H = accum.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float4 a = accum.read(gid);
    float4 w = wtTex.read(gid);
    float4 wSafe = max(w, float4(p.weightFloor));
    float4 norm = a / wSafe;
    accum.write(float4(clamp(norm.rgb, 0.0, 1.0), 1.0), gid);
}

// MARK: - Drizzle (Fruchter & Hook 2002, GPU splat) (B.6)
//
// Per-output reverse-mapped splatter. Each output thread (in upsampled
// coords) finds the single input pixel whose drop covers it and adds
// the value × overlap-area into the accumulator + weight textures.
//
// Algorithm reverse-maps the drop centre:
//   centre_out = (xi + 0.5 + shift) * scale
//   so xi = round((output_centre / scale) - 0.5 - shift)
// Then computes the overlap rectangle of the [output_pixel] cell and
// the drop box [centre_out ± halfDrop]. Output pixels not covered by
// any drop stay at 0 weight; the finalize pass treats them as 0.
//
// Constraints (v0):
//   * `scale` must be a positive integer (1, 2, 3 typical). Fractional
//     scales (1.5×) require the per-output approach to consider up to
//     four input drops per output pixel — folded into v1.
//   * `pixfrac` ∈ (0, 1]; the kernel skips at 0 to make pixfrac=0 a
//     no-op for tests.
//   * Sub-pixel shifts are honoured.
//
// CPU reference: Engine/Pipeline/Drizzle.swift::splat / finalize.

struct LuckyDrizzleParams {
    float  weight;
    float  pixfrac;
    uint   scale;
    float  pad0;
    float2 shift;          // sub-pixel shift in INPUT pixels
    uint2  inputSize;      // (W, H) of `frame`
};

kernel void lucky_drizzle_splat(
    texture2d<float, access::read>       frame  [[texture(0)]],
    texture2d<float, access::read_write> accum  [[texture(1)]],
    texture2d<float, access::read_write> wtTex  [[texture(2)]],
    constant LuckyDrizzleParams&         p      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    if (p.pixfrac <= 0.0 || p.scale == 0) return;

    float scale = float(p.scale);
    float halfDrop = 0.5 * p.pixfrac * scale;

    // Output pixel centre in output coords.
    float outCx = float(gid.x) + 0.5;
    float outCy = float(gid.y) + 0.5;

    // Reverse-map to find the input pixel whose drop centre is closest
    // to this output centre. With pixfrac ≤ 1 and integer scale, at
    // most one input drop covers any given output pixel.
    float fxi = (outCx / scale) - 0.5 - p.shift.x;
    float fyi = (outCy / scale) - 0.5 - p.shift.y;
    int xi = int(round(fxi));
    int yi = int(round(fyi));
    if (xi < 0 || xi >= int(p.inputSize.x)) return;
    if (yi < 0 || yi >= int(p.inputSize.y)) return;

    float4 v = frame.read(uint2(uint(xi), uint(yi)));

    // Drop box for this input pixel.
    float cx = (float(xi) + 0.5 + p.shift.x) * scale;
    float cy = (float(yi) + 0.5 + p.shift.y) * scale;
    float dropMinX = cx - halfDrop;
    float dropMaxX = cx + halfDrop;
    float dropMinY = cy - halfDrop;
    float dropMaxY = cy + halfDrop;

    // Overlap of the unit-cell at (gid) with the drop box.
    float pixelMinX = float(gid.x);
    float pixelMaxX = float(gid.x) + 1.0;
    float pixelMinY = float(gid.y);
    float pixelMaxY = float(gid.y) + 1.0;
    float xOverlap = max(0.0, min(dropMaxX, pixelMaxX) - max(dropMinX, pixelMinX));
    float yOverlap = max(0.0, min(dropMaxY, pixelMaxY) - max(dropMinY, pixelMinY));
    float area = xOverlap * yOverlap;
    if (area <= 0.0) return;

    accum.write(accum.read(gid) + v * (p.weight * area), gid);
    wtTex.write(wtTex.read(gid) + float4(p.weight * area), gid);
}

// MARK: - Stack accumulation (running average)

struct StackParams {
    float weight;  // 1/N for frame N
};

kernel void stack_accumulate(
    texture2d<float, access::read>        frame [[texture(0)]],
    texture2d<float, access::read_write>  accum [[texture(1)]],
    constant StackParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    float4 a = accum.read(gid);
    float4 f = frame.read(gid);
    // Welford-style running mean: a += (f - a) * weight
    float4 r = a + (f - a) * params.weight;
    accum.write(r, gid);
}
