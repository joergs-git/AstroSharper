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
    if (u.hasAfter == 0u) return colBefore;

    float4 colAfter = after.sample(s, uv);
    // Split by screen-space X.
    bool showAfter = in.uv.x < u.splitX;
    float4 col = showAfter ? colAfter : colBefore;

    // Thin split line.
    float edge = abs(in.uv.x - u.splitX);
    if (edge < 0.001) {
        col = float4(1, 1, 1, 1);
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
};

// accum = accum + layer * amount.
kernel void weighted_add(
    texture2d<float, access::read>        layer [[texture(0)]],
    texture2d<float, access::read_write>  accum [[texture(1)]],
    constant WaveletAddParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    float4 l = layer.read(gid);
    float4 a = accum.read(gid);
    accum.write(a + l * params.amount, gid);
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

inline float3 bilinear_demosaic_u16(
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
    bool greenRedRow = !isRed && !isBlue && (pxY == rOff.y);

    float r, g, b;
    if (isRed) {
        r = bayer_read_u16(src, c, scale);
        g = 0.25 * (bayer_read_u16(src, c + int2(-1, 0), scale)
                  + bayer_read_u16(src, c + int2( 1, 0), scale)
                  + bayer_read_u16(src, c + int2( 0,-1), scale)
                  + bayer_read_u16(src, c + int2( 0, 1), scale));
        b = 0.25 * (bayer_read_u16(src, c + int2(-1,-1), scale)
                  + bayer_read_u16(src, c + int2( 1,-1), scale)
                  + bayer_read_u16(src, c + int2(-1, 1), scale)
                  + bayer_read_u16(src, c + int2( 1, 1), scale));
    } else if (isBlue) {
        b = bayer_read_u16(src, c, scale);
        g = 0.25 * (bayer_read_u16(src, c + int2(-1, 0), scale)
                  + bayer_read_u16(src, c + int2( 1, 0), scale)
                  + bayer_read_u16(src, c + int2( 0,-1), scale)
                  + bayer_read_u16(src, c + int2( 0, 1), scale));
        r = 0.25 * (bayer_read_u16(src, c + int2(-1,-1), scale)
                  + bayer_read_u16(src, c + int2( 1,-1), scale)
                  + bayer_read_u16(src, c + int2(-1, 1), scale)
                  + bayer_read_u16(src, c + int2( 1, 1), scale));
    } else {
        g = bayer_read_u16(src, c, scale);
        if (greenRedRow) {
            r = 0.5 * (bayer_read_u16(src, c + int2(-1, 0), scale)
                     + bayer_read_u16(src, c + int2( 1, 0), scale));
            b = 0.5 * (bayer_read_u16(src, c + int2( 0,-1), scale)
                     + bayer_read_u16(src, c + int2( 0, 1), scale));
        } else {
            r = 0.5 * (bayer_read_u16(src, c + int2( 0,-1), scale)
                     + bayer_read_u16(src, c + int2( 0, 1), scale));
            b = 0.5 * (bayer_read_u16(src, c + int2(-1, 0), scale)
                     + bayer_read_u16(src, c + int2( 1, 0), scale));
        }
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
    float3 rgb = bilinear_demosaic_u16(src, int2(srcGid), p.pattern, p.scale);
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
    float3 rgb = bilinear_demosaic_f(src, int2(srcGid), p.pattern);
    dst.write(float4(rgb, 1.0), gid);
}

// MARK: - Quality grading
//
// Per-frame Laplacian variance via threadgroup-local reduction. Each group
// emits one (sum, sumSq, count) triple to a flat partials buffer indexed by
// frame; final variance resolves on CPU. Avoids cross-frame syncs entirely.

struct QualityPartial {
    float sum;
    float sumSq;
    uint  count;
    uint  pad;
};

inline float luma_lq(float4 c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

inline float laplacian_at(texture2d<float, access::read> tex, uint2 gid) {
    uint W = tex.get_width(), H = tex.get_height();
    if (gid.x == 0 || gid.y == 0 || gid.x + 1 >= W || gid.y + 1 >= H) return 0.0;
    float c = luma_lq(tex.read(gid));
    float l = luma_lq(tex.read(uint2(gid.x - 1, gid.y)));
    float r = luma_lq(tex.read(uint2(gid.x + 1, gid.y)));
    float t = luma_lq(tex.read(uint2(gid.x,     gid.y - 1)));
    float b = luma_lq(tex.read(uint2(gid.x,     gid.y + 1)));
    return (l + r + t + b) - 4.0 * c;
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
    texture2d<float, access::read>  ref      [[texture(0)]],
    texture2d<float, access::read>  frame    [[texture(1)]],
    texture2d<float, access::write> shiftMap [[texture(2)]],
    constant APSearchParams& p [[buffer(0)]],
    uint apIndex     [[threadgroup_position_in_grid]],
    uint candIndex   [[thread_index_in_threadgroup]],
    uint tgSize      [[threads_per_threadgroup]]
) {
    int range = 2 * p.searchRadius + 1;
    int total = range * range;

    threadgroup float bestSAD[1024];
    threadgroup int   bestIdx[1024];

    // Initialize ALL 1024 slots so the reduction's stride=512 step reads
    // valid data even when the dispatched threadgroup is smaller than 1024
    // (e.g. 512 threads for searchRadius=8). Each thread is responsible for
    // a stride-of-tgSize slice of the array.
    for (uint i = candIndex; i < 1024; i += tgSize) {
        bestSAD[i] = 1e30;
        bestIdx[i] = int(i);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int candX = (int(candIndex) % range) - p.searchRadius;
    int candY = (int(candIndex) / range) - p.searchRadius;

    uint apX = apIndex % p.gridSize.x;
    uint apY = apIndex / p.gridSize.x;

    int W = int(ref.get_width()), H = int(ref.get_height());
    int cx = int(float(W) * (float(apX) + 0.5) / float(p.gridSize.x));
    int cy = int(float(H) * (float(apY) + 0.5) / float(p.gridSize.y));

    float sad = 1e30;
    if (int(candIndex) < total) {
        sad = 0.0;
        int hp = int(p.patchHalf);  // patch half size
        // Subsample by 2 for speed — patchHalf=8 → 8×8=64 samples per SAD.
        int gx = int(round(p.globalShift.x));
        int gy = int(round(p.globalShift.y));
        for (int py = -hp; py < hp; py += 2) {
            for (int px = -hp; px < hp; px += 2) {
                int rx = cx + px, ry = cy + py;
                int fx = rx + candX + gx, fy = ry + candY + gy;
                if (rx < 0 || rx >= W || ry < 0 || ry >= H) continue;
                if (fx < 0 || fx >= W || fy < 0 || fy >= H) continue;
                float r = ref.read(uint2(rx, ry)).r;
                float f = frame.read(uint2(fx, fy)).r;
                sad += abs(r - f);
            }
        }
    }

    bestSAD[candIndex] = sad;
    bestIdx[candIndex] = int(candIndex);
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
        int wx = (winnerIdx % range) - p.searchRadius;
        int wy = (winnerIdx / range) - p.searchRadius;
        shiftMap.write(float4(float(wx), float(wy), 0, 0), uint2(apX, apY));
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
