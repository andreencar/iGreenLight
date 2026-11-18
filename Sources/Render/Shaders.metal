#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

// Full-screen triangle.
vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct YUVParams {
    float3x3 matrix;   // YCbCr -> RGB
    float3 offset;     // subtracted before the matrix
    float3 scale;      // range expansion
    float4 chroma;     // xy: added to the uv of the chroma sample (siting correction), z: 1 = luma-guided
                       // upsampling, w: 1 / luma difference at which a neighbour stops counting
};

// One of the four chroma texels around the pixel, for the luma-guided upsample: its chroma times its weight in
// xy, the weight in z. `texel` is its index, `bilinear` its bilinear weight, `y` the pixel's own luma.
static float3 guided_chroma(texture2d<float> yTex, texture2d<float> uvTex, float2 texel, float2 size,
                            float bilinear, float y, float4 chroma) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    // Past the border the texel is the border one, as clamp-to-edge filtering has it.
    float2 centre = (clamp(texel, float2(0.0), size - 1.0) + 0.5) / size;
    // The luma where this chroma sample was taken: its own position with the siting correction undone. For
    // Left siting that is the middle of luma column 2j, halfway between rows 2j and 2j+1, so the bilinear
    // fetch gives the mean of the two luma pixels the sample sits between.
    float d = (yTex.sample(linear, centre - chroma.xy).r - y) * chroma.w;
    // The small constant keeps the sum from vanishing where no neighbour's luma is close (a line one pixel
    // wide): there the weights are all equally tiny and the result is the bilinear one again.
    float w = bilinear * (exp(-d * d) + 1e-3);
    return float3(uvTex.sample(nearest, centre).rg * w, w);
}

// NV12 / 420f / 420v / x420 -> RGB at source resolution.
// Chroma siting: a bilinear fetch assumes chroma texel j sits in the middle of luma columns 2j and 2j+1
// (x = 2j+1 in luma pixels, where luma column i has its centre at i+0.5). H.264's default "Left" siting
// puts it on luma column 2j instead (x = 2j+0.5), so the texture holds the chroma of a point half a luma
// pixel to the left of where the sampler thinks it is. Reading the chroma for position x therefore means
// sampling half a luma pixel (a quarter of a chroma texel) further right: p.chroma.x = +0.25 / chroma width.
// Without it the colour sits half a luma pixel right of its luma. Vertically Left is centred: no offset.
//
// Luma-guided upsampling (p.chroma.z): chroma has half the resolution of luma, and bilinear filtering
// spreads the colour of one side of an edge half a chroma texel into the other: a red letter gets a red
// fringe, a white one a tint of the background. The luma has the edge at full resolution, so each of the
// four chroma texels the bilinear fetch would blend gets its bilinear weight times how close the luma at its
// own position is to this pixel's luma (a joint bilateral filter). Texels from the far side of an edge drop
// out; where the luma is flat the factors are equal and the result is the bilinear one. Same four texels and
// the same siting correction as the plain fetch; four more luma taps and an exp each.
fragment float4 nv12_fragment(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> uvTex [[texture(1)]],
                              constant YUVParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yTex.sample(s, in.uv).r;
    float2 uv;
    if (p.chroma.z < 0.5) {
        uv = uvTex.sample(s, in.uv + p.chroma.xy).rg;
    } else {
        float2 size = float2(uvTex.get_width(), uvTex.get_height());
        float2 st = (in.uv + p.chroma.xy) * size - 0.5;
        float2 i = floor(st), f = st - i;
        float3 sum = guided_chroma(yTex, uvTex, i, size, (1.0 - f.x) * (1.0 - f.y), y, p.chroma)
                   + guided_chroma(yTex, uvTex, i + float2(1, 0), size, f.x * (1.0 - f.y), y, p.chroma)
                   + guided_chroma(yTex, uvTex, i + float2(0, 1), size, (1.0 - f.x) * f.y, y, p.chroma)
                   + guided_chroma(yTex, uvTex, i + float2(1, 1), size, f.x * f.y, y, p.chroma);
        uv = sum.xy / sum.z;
    }
    float3 ycc = (float3(y, uv) - p.offset) * p.scale;
    return float4(saturate(p.matrix * ycc), 1.0);
}

// I420 (three planes) fallback.
fragment float4 i420_fragment(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> uTex [[texture(1)]],
                              texture2d<float> vTex [[texture(2)]],
                              constant YUVParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ycc = (float3(yTex.sample(s, in.uv).r, uTex.sample(s, in.uv).r, vTex.sample(s, in.uv).r) - p.offset) * p.scale;
    return float4(saturate(p.matrix * ycc), 1.0);
}

// Quarter-size box downsample (four bilinear taps cover a 4×4 block). First step of the ambient chain.
fragment float4 downsample_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 t = 1.0 / float2(tex.get_width(), tex.get_height());
    return (tex.sample(s, in.uv + t * float2(-1, -1)) + tex.sample(s, in.uv + t * float2(1, -1)) +
            tex.sample(s, in.uv + t * float2(-1, 1)) + tex.sample(s, in.uv + t * float2(1, 1))) * 0.25;
}

struct AmbientParams {
    float4 blend;      // x: weight of the new frame (1 = replace)
};

// Tiny copy of the frame (trilinear from the mip chain), alpha-blended over the previous one so the
// glow in the bars follows the picture smoothly instead of flickering with it.
fragment float4 ambient_fragment(VOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant AmbientParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return float4(tex.sample(s, in.uv).rgb, p.blend.x);
}

struct PresentParams {
    float4 uv;         // xy: scale, zw: offset — maps drawable uv -> content uv
    float4 deband;     // xy: sampling radius in content uv, z: threshold (0 = off), w: grain amplitude
    float4 edr;        // x: peak (1 = no expansion), y: knee (linear), z: frame seed, w: 1 = linear extended-sRGB output
    float4 ambient;    // x: 1 = fill the bars, y: brightness at the picture edge, z: falloff length in picture heights, w: saturation
    float4 sharpen;    // x: strongest negative lobe (0 = off, 0.2 = maximum), yzw: unused
};

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Bicubic B-spline read of one mip level of the ambient texture (four bilinear taps cover the 4×4 texels).
// Plain bilinear magnification of a texture this small shows its texel grid as diamonds; the B-spline is
// smooth everywhere and is itself a blur about one texel wide.
static float3 ambient_sample(texture2d<float> t, float2 uv, float lod) {
    constexpr sampler s(filter::linear, mip_filter::nearest, address::clamp_to_edge);
    float2 size = float2(t.get_width(uint(lod)), t.get_height(uint(lod)));
    float2 st = uv * size - 0.5;
    float2 i = floor(st), f = st - i;
    float2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0, w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f * f - 3.0 * f * f * f) / 6.0, w3 = f * f * f / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 p0 = (i - 0.5 + w1 / g0) / size, p1 = (i + 1.5 + w3 / g1) / size;
    return (t.sample(s, float2(p0.x, p0.y), level(lod)).rgb * g0.x + t.sample(s, float2(p1.x, p0.y), level(lod)).rgb * g1.x) * g0.y +
           (t.sample(s, float2(p0.x, p1.y), level(lod)).rgb * g0.x + t.sample(s, float2(p1.x, p1.y), level(lod)).rgb * g1.x) * g1.y;
}

static float3 srgb_to_linear(float3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c));
}

// Draw the (upscaled) frame into the drawable with letterbox / zoom / stretch.
// The frame comes in with 10 bits a channel; the SDR drawable has 8, and this is the one place it is rounded.
// Optional steps, in order: contrast-adaptive sharpening, debanding (smooths 8-bit steps in flat gradients
// and dithers the result), then SDR→EDR expansion (highlights above the knee are stretched into the display's
// HDR headroom). Sharpening and debanding both read the untouched texture, so neither sees the other's output:
// the deband test compares the unsharpened centre, and where it calls the area a flat gradient the smoothed
// value replaces the sharpened one (a sharpened band edge would be a more visible band, and could push the
// pixel over the threshold). The grain is added last, so it is never sharpened. All of it happens on the
// gamma-encoded picture, before the EDR path converts to linear.
fragment float4 present_fragment(VOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 texture2d<float> ambientTex [[texture(1)]],
                                 constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float2 uv = in.uv * p.uv.xy + p.uv.zw;
    bool bar = any(uv < 0.0) || any(uv > 1.0);
    if (bar && p.ambient.x < 0.5) return float4(0, 0, 0, 1);
    float3 c;

    if (bar) {
        // Edge glow: the bar takes the colour of the picture edge next to it, blurred until no shape survives
        // (a HUD at the edge becomes a patch of colour, not a reflection), and fades to black with the distance
        // from the picture, like light spilling from it. The distance is in picture heights, not a share of the
        // bar, so a thin bar, a pillar and one tall bar below a top-anchored picture all fall off the same way.
        float2 d = max(max(-uv, uv - 1.0), 0.0);                   // distance past the edge, content uv
        float dist = length(d * float2(float(tex.get_width()) / float(tex.get_height()), 1.0));
        float2 m = clamp(uv, 0.02, 0.98);                          // nearest point of the picture, just inside it
        // Further out the colour comes from a coarser level, so it spreads along the edge as it travels.
        float coarse = float(min(2u, ambientTex.get_num_mip_levels() - 1u));
        c = mix(ambient_sample(ambientTex, m, 0.0), ambient_sample(ambientTex, m, coarse), saturate(dist / p.ambient.z));
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(luma), c, p.ambient.w) * p.ambient.y * exp(-dist / p.ambient.z);
        // Dither: a dim blurred gradient bands badly in an 8-bit drawable.
        c = saturate(c + (hash12(in.pos.xy + p.edr.z + 71.0) - 0.5) * p.deband.w);
    } else {
        c = tex.sample(s, uv).rgb;
    }
    float3 raw = c;

    if (!bar && p.sharpen.x > 0.0) {
        // Cross of neighbours one texel of the sampled texture away (the upscaled one when MetalFX ran).
        // The negative lobe is scaled by how much room the local min/max leave before clipping, relative to
        // the local max: strong edges, which are sharp already and would ring, get little; soft detail gets
        // the most. Outside the picture the sampler returns black, so the outermost pixels are left alone.
        float2 t = 1.0 / float2(tex.get_width(), tex.get_height());
        float3 n = tex.sample(s, uv - float2(0, t.y)).rgb, d = tex.sample(s, uv + float2(0, t.y)).rgb;
        float3 l = tex.sample(s, uv - float2(t.x, 0)).rgb, r = tex.sample(s, uv + float2(t.x, 0)).rgb;
        float3 mn = min(c, min(min(n, d), min(l, r)));
        float3 mx = max(c, max(max(n, d), max(l, r)));
        float3 w = -p.sharpen.x * sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
        c = saturate((c + (n + d + l + r) * w) / (1.0 + 4.0 * w));
    }

    if (!bar && p.deband.z > 0.0) {
        // Four taps on a randomly rotated cross; where they agree with the centre to within the threshold the
        // area is a flat gradient, so use their average. Real edges and texture exceed the threshold and are kept.
        float2 seed = in.pos.xy + p.edr.z;
        float dist = hash12(seed) * 0.75 + 0.25;
        float ang = hash12(seed + 17.0) * 6.2831853;
        float2 o = float2(cos(ang), sin(ang)) * dist * p.deband.xy;
        float2 q = float2(-sin(ang), cos(ang)) * dist * p.deband.xy;
        float3 avg = (tex.sample(s, uv + o).rgb + tex.sample(s, uv - o).rgb +
                      tex.sample(s, uv + q).rgb + tex.sample(s, uv - q).rgb) * 0.25;
        float3 keep = step(float3(p.deband.z), abs(raw - avg));
        c = mix(avg, c, keep);
        c = saturate(c + (hash12(seed + 71.0) - 0.5) * p.deband.w);
    }

    if (p.edr.w > 0.5) {
        float3 lin = srgb_to_linear(c);
        if (p.edr.x > 1.0) {
            // Driven by the brightest channel so saturated highlights expand too; t² keeps the onset smooth.
            float m = max(lin.r, max(lin.g, lin.b));
            float t = saturate((m - p.edr.y) / (1.0 - p.edr.y));
            lin *= 1.0 + (p.edr.x - 1.0) * t * t;
        }
        return float4(lin, 1.0);
    }
    return float4(c, 1.0);
}
