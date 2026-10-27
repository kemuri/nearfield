#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Stitchable render effects for the Wave Lab, used from SwiftUI via
// `colorEffect` / `layerEffect`, and the full-frame header animation shader
// (at the end). Compiled into `default.metallib` by script/build_and_run.sh and
// loaded with `ShaderLibrary.default` and HeaderAnimationRenderer. The pure
// SwiftUI implementations are the fallback when this library is absent (e.g. a
// plain `swift build`).

// MARK: - Pixelate (layerEffect)

[[ stitchable ]] half4 wl_pixelate(float2 position, SwiftUI::Layer layer, float blockSize) {
    float block = max(blockSize, 1.0);
    float2 snapped = (floor(position / block) + 0.5) * block;
    return layer.sample(snapped);
}

// MARK: - Dither (colorEffect, ordered Bayer per channel)

[[ stitchable ]] half4 wl_dither(float2 position, half4 color,
                                 float cellSize, float contrast, float levels) {
    const float bayer[16] = {
        0.0,  8.0,  2.0,  10.0,
        12.0, 4.0,  14.0, 6.0,
        3.0,  11.0, 1.0,  9.0,
        15.0, 7.0,  13.0, 5.0
    };

    float cell = max(cellSize, 1.0);
    int bx = int(floor(position.x / cell)) & 3;
    int by = int(floor(position.y / cell)) & 3;
    float threshold = (bayer[by * 4 + bx] + 0.5) / 16.0 - 0.5;

    half alpha = color.a;
    if (alpha <= 0.0h) {
        return color;
    }

    half3 rgb = color.rgb / alpha; // unpremultiply
    half k = half(max(contrast, 0.0));
    rgb = clamp((rgb - 0.5h) * k + 0.5h, 0.0h, 1.0h);

    half steps = half(max(levels, 2.0)) - 1.0h;
    half3 quantized = clamp(floor(rgb * steps + half(threshold) + 0.5h) / steps, 0.0h, 1.0h);
    return half4(quantized * alpha, alpha);
}

// MARK: - Glitch (layerEffect)

static inline float wl_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

[[ stitchable ]] half4 wl_glitch(float2 position, SwiftUI::Layer layer,
                                 float2 size, float time, float amount,
                                 float sliceCount, float sliceShift) {
    float2 bounds = max(size, float2(1.0));
    float2 uv = position / bounds;

    // Horizontally displace random scanline slices.
    float slices = max(sliceCount, 1.0);
    float row = floor(uv.y * slices);
    float noise = wl_hash(float2(row, floor(time * 12.0)));
    float displacement = (noise > 0.6) ? (noise - 0.6) * 2.5 * sliceShift : 0.0;

    float2 base = position + float2(displacement, 0.0);

    // Chromatic aberration: sample R/G/B at diverging offsets.
    half red = layer.sample(base + float2(-amount, 0.0)).r;
    half4 green = layer.sample(base);
    half blue = layer.sample(base + float2(amount, 0.0)).b;

    half3 rgb = half3(red, green.g, blue);
    half scan = 0.92h + 0.08h * half(sin(position.y * 1.5 + time * 24.0));
    rgb *= scan;
    return half4(rgb, green.a);
}

// MARK: - Progressive blur (separable, variable radius)

// Blur radius for a pixel, ramped across the width. `strongOnLeft` (0/1) flips
// the direction; `exponent` shapes the falloff curve. Matches the parameters of
// the SwiftUI fallback (ProgressiveSineWaveLayer).
static inline float wl_pb_radius(float2 position, float2 size,
                                 float maxRadius, float exponent, float strongOnLeft) {
    float t = clamp(position.x / max(size.x, 1.0), 0.0, 1.0);
    float amount = (strongOnLeft > 0.5) ? (1.0 - t) : t;
    return maxRadius * pow(amount, exponent);
}

// One separable Gaussian pass along `direction` with a per-pixel radius.
static inline half4 wl_pb_pass(float2 position, SwiftUI::Layer layer, float2 direction,
                               float2 size, float maxRadius, float exponent, float strongOnLeft) {
    float radius = wl_pb_radius(position, size, maxRadius, exponent, strongOnLeft);
    if (radius < 0.5) {
        return layer.sample(position);
    }

    float sigma = max(radius * 0.5, 0.5);
    int taps = min(int(ceil(radius * 1.5)), 30);
    half4 sum = half4(0.0h);
    float weightSum = 0.0;
    for (int i = -taps; i <= taps; i++) {
        float weight = exp(-float(i * i) / (2.0 * sigma * sigma));
        sum += layer.sample(position + direction * float(i)) * half(weight);
        weightSum += weight;
    }
    return sum / half(max(weightSum, 1e-4));
}

[[ stitchable ]] half4 wl_progressive_blur_h(float2 position, SwiftUI::Layer layer,
                                             float2 size, float maxRadius,
                                             float exponent, float strongOnLeft) {
    return wl_pb_pass(position, layer, float2(1.0, 0.0), size, maxRadius, exponent, strongOnLeft);
}

[[ stitchable ]] half4 wl_progressive_blur_v(float2 position, SwiftUI::Layer layer,
                                             float2 size, float maxRadius,
                                             float exponent, float strongOnLeft) {
    return wl_pb_pass(position, layer, float2(0.0, 1.0), size, maxRadius, exponent, strongOnLeft);
}

// MARK: - Header animation (whole frame, one pass)

// Renders the complete header animation per pixel: base color, the two
// crossing waves with their progressive blur, the grain and the post effect.
// Driven by HeaderAnimationRenderer.swift, which only advances the phase and
// issues one draw per frame. Mirrors CoreHeaderAnimation and
// AnimationEffectsView (the SwiftUI fallback); keep the two in step.
//
// Coordinates are in points with the origin top left, like SwiftUI's. Colors
// are blended gamma-encoded, as SwiftUI's drawing group does.

struct NFHeaderWave {
    float4 color;     // rgb, opacity
    float4 shape;     // line width, frequency, amplitude, amplitude falloff
    float4 placement; // vertical position, phase shift, horizontal overscan, blur radius
};

struct NFHeaderUniforms {
    float4 view;      // width, height, pixels per point, effect time
    float4 base;      // rgb
    float4 modes;     // wave blend, grain blend, effect, blur strong on left
    float4 blur;      // maximum progressive radius, exponent
    NFHeaderWave waves[2];
    float4 noise;     // opacity, density, minimum dot size, maximum dot size
    float4 grain;     // seed, monochrome, monochrome is white
    float4 effectA;   // greyscale amount, pixel block size, dither contrast, dither cell size
    float4 effectB;   // dither levels, glitch amount, glitch slice count, glitch slice displacement
};

struct NFHeaderVertex {
    float4 position [[position]];
};

vertex NFHeaderVertex nf_header_vertex(uint vertexID [[vertex_id]]) {
    // One triangle that covers the whole target.
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    NFHeaderVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// Abramowitz and Stegun 7.1.26 (error below 1.5e-7); Metal has no erf.
static inline float nf_erf(float x) {
    float t = 1.0 / (1.0 + 0.3275911 * fabs(x));
    float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
                        t * exp(-x * x);
    return copysign(y, x);
}

static inline float nf_random(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return float(v.x & 0xffffu) / 65535.0;
}

// The Gaussian the two progressive blur passes (wl_pb_pass) apply at x:
// sigma is half the radius, and the kernel stops at 1.5 x the radius or 30
// taps, which narrows the widest blurs.
static inline float nf_progressive_sigma(float x, constant NFHeaderUniforms &u) {
    float radius = wl_pb_radius(float2(x, 0.0), u.view.xy, u.blur.x, u.blur.y, u.modes.w);
    if (radius < 0.5) {
        return 0.0;
    }
    float sigma = max(radius * 0.5, 0.5);
    float cutoff = min(ceil(radius * 1.5), 30.0) / sigma;
    float variance = 1.0 - 2.0 * cutoff * 0.3989422804 * exp(-0.5 * cutoff * cutoff) /
                               max(nf_erf(cutoff * 0.7071067812), 1e-4);
    return sigma * sqrt(max(variance, 0.05));
}

// The wave's height at x and its slope (SineWaveShape).
static inline float2 nf_wave_curve(float x, NFHeaderWave wave, float2 size) {
    float overscan = wave.placement.z;
    float k = wave.shape.y * 2.0 * M_PI_F / max(size.x + overscan * 2.0, 1.0);
    float angle = k * (x + overscan) - wave.placement.y;
    float amplitude = size.y * wave.shape.z;
    float envelope = max(1.0 - wave.shape.w * clamp(x / size.x, 0.0, 1.0), 0.0);
    float envelopeSlope = (x > 0.0 && x < size.x && envelope > 0.0) ? -wave.shape.w / size.x : 0.0;
    float s = sin(angle);
    float c = cos(angle);
    return float2(size.y * wave.placement.x + s * amplitude * envelope,
                  amplitude * (k * c * envelope + s * envelopeSlope));
}

// How much of the stroke, blurred by a Gaussian of `sigma`, covers p: the
// distance to the curve (found with a few Gauss-Newton steps from the point
// straight above or below p) through the blurred profile of a band.
static inline float nf_wave_coverage(float2 p, NFHeaderWave wave, float2 size, float sigma) {
    float t = p.x;
    for (int step = 0; step < 5; step++) {
        float2 f = nf_wave_curve(t, wave, size);
        float gradient = (t - p.x) + (f.x - p.y) * f.y;
        t -= clamp(gradient / (1.0 + f.y * f.y), -48.0, 48.0);
    }
    float distance = length(float2(t - p.x, nf_wave_curve(t, wave, size).x - p.y));
    float halfWidth = wave.shape.x * 0.5;
    float spread = max(sigma, 1e-3) * 1.4142135624;
    return 0.5 * (nf_erf((halfWidth - distance) / spread) + nf_erf((halfWidth + distance) / spread));
}

// Composites a premultiplied source over an opaque backdrop. Modes:
// 0 normal, 1 soft light, 2 screen, 3 overlay, 4 hard light, 5 color dodge,
// 6 plus lighter (WaveLabBlendMode.choices).
static inline float3 nf_blend(float3 backdrop, float3 premultiplied, float alpha, int mode) {
    if (alpha <= 0.0) {
        return backdrop;
    }
    float3 b = backdrop;
    float3 s = clamp(premultiplied / alpha, 0.0, 1.0);
    float3 blended;
    switch (mode) {
        case 1:
            // SwiftUI's soft light is this smooth curve, not the W3C one
            // (measured against its renders).
            blended = (1.0 - 2.0 * s) * b * b + 2.0 * s * b;
            break;
        case 2:
            blended = b + s - b * s;
            break;
        case 3: {
            float3 lifted = 2.0 * b - 1.0;
            blended = select(s + lifted - s * lifted, s * 2.0 * b, b <= 0.5);
            break;
        }
        case 4: {
            float3 lifted = 2.0 * s - 1.0;
            blended = select(b + lifted - b * lifted, b * 2.0 * s, s <= 0.5);
            break;
        }
        case 5:
            blended = select(select(min(1.0, b / max(1.0 - s, 1e-4)), float3(1.0), s >= 1.0), float3(0.0), b <= 0.0);
            break;
        case 6:
            return min(backdrop + premultiplied, 1.0);
        default:
            blended = s;
            break;
    }
    return mix(backdrop, blended, alpha);
}

// The grain (HeaderNoiseLayer): `density` specks, one in each cell of a grid
// with that many cells, at a random place, size and tone.
static inline float3 nf_grain(float2 p, float3 backdrop, constant NFHeaderUniforms &u, float2 size) {
    float opacity = u.noise.x;
    float density = u.noise.y;
    if (opacity <= 0.0 || density < 1.0) {
        return backdrop;
    }
    float cellSize = sqrt(size.x * size.y / density);
    int2 cell = int2(floor(p / cellSize));
    uint2 key = as_type<uint2>(cell);
    uint seed = uint(u.grain.x) * 4u;
    float dotSize = mix(u.noise.z, u.noise.w, nf_random(uint3(key, seed)));
    float tone = nf_random(uint3(key, seed + 1u));
    float2 jitter = float2(nf_random(uint3(key, seed + 2u)), nf_random(uint3(key, seed + 3u)));
    float2 origin = (float2(cell) + jitter * max(1.0 - dotSize / cellSize, 0.0)) * cellSize;

    // The share of this pixel the speck covers.
    float pixel = 1.0 / max(u.view.z, 1.0);
    float2 overlap = clamp(min(p + pixel * 0.5, origin + dotSize) - max(p - pixel * 0.5, origin), 0.0, pixel) / pixel;
    float coverage = overlap.x * overlap.y;
    if (coverage <= 0.0) {
        return backdrop;
    }
    float alpha = opacity * (0.34 + tone * 0.66);
    float3 speck;
    if (u.grain.y > 0.5) {
        speck = float3(u.grain.z > 0.5 ? 1.0 : 0.0);
    } else {
        speck = float3(tone > 0.5 ? 1.0 : 0.0);
        alpha *= tone > 0.5 ? 1.0 : 0.7;
    }
    alpha *= coverage;
    return nf_blend(backdrop, speck * alpha, alpha, int(u.modes.y));
}

static inline float3 nf_header_scene(float2 p, constant NFHeaderUniforms &u) {
    float2 size = max(u.view.xy, float2(1.0));
    float progressive = nf_progressive_sigma(p.x, u);
    float antialias = 0.35 / max(u.view.z, 1.0);

    // The second wave is painted over the first, and the two are blurred and
    // blended as one layer.
    float3 premultiplied = float3(0.0);
    float alpha = 0.0;
    for (int index = 0; index < 2; index++) {
        NFHeaderWave wave = u.waves[index];
        float sigma = sqrt(progressive * progressive + wave.placement.w * wave.placement.w + antialias * antialias);
        float a = wave.color.a * nf_wave_coverage(p, wave, size, sigma);
        premultiplied = wave.color.rgb * a + premultiplied * (1.0 - a);
        alpha = a + alpha * (1.0 - a);
    }
    float3 color = nf_blend(u.base.rgb, premultiplied, alpha, int(u.modes.x));
    return nf_grain(p, color, u, size);
}

fragment half4 nf_header_fragment(NFHeaderVertex in [[stage_in]], constant NFHeaderUniforms &u [[buffer(0)]]) {
    float2 p = in.position.xy / max(u.view.z, 1.0);
    float3 color;
    switch (int(u.modes.z)) {
        case 1: { // Greyscale
            float3 scene = nf_header_scene(p, u);
            color = mix(scene, float3(dot(scene, float3(0.2126, 0.7152, 0.0722))), u.effectA.x);
            break;
        }
        case 2: { // Pixelated (wl_pixelate)
            float block = max(u.effectA.y, 1.0);
            color = nf_header_scene((floor(p / block) + 0.5) * block, u);
            break;
        }
        case 3: { // Dither (wl_dither)
            const float bayer[16] = {0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
                                     3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0};
            float cell = max(u.effectA.w, 1.0);
            int bx = int(floor(p.x / cell)) & 3;
            int by = int(floor(p.y / cell)) & 3;
            float threshold = (bayer[by * 4 + bx] + 0.5) / 16.0 - 0.5;
            float3 rgb = clamp((nf_header_scene(p, u) - 0.5) * max(u.effectA.z, 0.0) + 0.5, 0.0, 1.0);
            float steps = max(u.effectB.x, 2.0) - 1.0;
            color = clamp(floor(rgb * steps + threshold + 0.5) / steps, 0.0, 1.0);
            break;
        }
        case 4: { // Glitch (wl_glitch)
            float time = u.view.w;
            float slices = max(u.effectB.z, 1.0);
            float row = floor(p.y / max(u.view.y, 1.0) * slices);
            float noise = wl_hash(float2(row, floor(time * 12.0)));
            float displacement = noise > 0.6 ? (noise - 0.6) * 2.5 * u.effectB.w : 0.0;
            float2 base = p + float2(displacement, 0.0);
            float amount = u.effectB.y;
            color = float3(nf_header_scene(base - float2(amount, 0.0), u).r,
                           nf_header_scene(base, u).g,
                           nf_header_scene(base + float2(amount, 0.0), u).b);
            color *= 0.92 + 0.08 * sin(p.y * 1.5 + time * 24.0);
            break;
        }
        default:
            color = nf_header_scene(p, u);
            break;
    }
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
}
