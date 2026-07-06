#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Stitchable render effects for the Wave Lab, used from SwiftUI via
// `colorEffect` / `layerEffect`. Compiled into `default.metallib` by
// script/build_and_run.sh and loaded with `ShaderLibrary.default`. The pure
// SwiftUI implementations in WaveLabEffects.swift are the fallback when this
// library is absent (e.g. a plain `swift build`).

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
