//
//  WeatherShaders.metal
//  WalkWorthy
//
//  Procedural cloud rendering for the mood weather background.
//  Domain-warped FBM value noise in the style of Apple Weather's
//  procedural skies, exposed to SwiftUI via `colorEffect`.
//

#include <metal_stdlib>
using namespace metal;

// Deterministic 2D hash → [0, 1)
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Bilinear value noise with smoothstep interpolation
static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 5-octave fractal Brownian motion, rotated per octave to hide grid artifacts
static inline float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    const float2x2 rotate = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) {
        value += amplitude * valueNoise(p);
        p = rotate * p * 2.02;
        amplitude *= 0.5;
    }
    return value;  // ≈ [0, 1]
}

/// One cloud deck. Returns premultiplied RGBA so clear sky stays transparent.
///
///  - coverage:     0 = clear sky, 1 = full cover
///  - darkness:     0 = sunlit white cumulus, 1 = near-black storm cell
///  - scale:        noise domain scale (larger = smaller, busier clouds)
///  - windOffset:   horizontal drift in noise-domain units (time × speed, computed on CPU)
///  - verticalFade: fraction of view height at which the deck has fully faded out
[[ stitchable ]] half4 cloudLayer(float2 position, half4 color, float2 size,
                                  float coverage, float darkness, float scale,
                                  float windOffset, float verticalFade) {
    float2 uv = position / size.x;
    float2 p = uv * scale + float2(windOffset, 0.0);

    // Domain warp: sampling fbm through a second fbm gives billowy,
    // organic cloud edges instead of uniform noise blobs.
    float warp = fbm(p + float2(windOffset * 0.35, 0.0));
    float n = fbm(p + float2(warp * 0.9, warp * 0.4));

    // Coverage slides the density threshold through the noise field.
    float threshold = mix(0.78, 0.18, clamp(coverage, 0.0, 1.0));
    float density = smoothstep(threshold, threshold + 0.32, n);

    // Fade toward the horizon so the deck reads as overhead sky.
    float yFrac = position.y / size.y;
    density *= 1.0 - smoothstep(verticalFade * 0.55, verticalFade, yFrac);

    // Dense cores shade darker while edges stay lit — fakes top-lit volume.
    // The lit tone falls off steeply with darkness: storm-cloud highlights
    // are slate-gray with a cold blue cast, not light gray.
    float core = smoothstep(threshold + 0.05, threshold + 0.55, n);
    float3 litColor  = mix(float3(1.0, 1.0, 1.0), float3(0.36, 0.38, 0.47), darkness * darkness * 0.4 + darkness * 0.6);
    float3 coreColor = mix(float3(0.82, 0.84, 0.88), float3(0.09, 0.09, 0.14), darkness);
    float3 cloud = mix(litColor, coreColor, core * (0.45 + 0.55 * darkness));

    float alpha = density * (0.85 + 0.15 * darkness);
    return half4(half3(float3(cloud * alpha)), half(alpha));
}
