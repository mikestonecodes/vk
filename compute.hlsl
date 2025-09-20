// --- Push constants: match this layout on the host exactly ---
struct PushConstants {
    float time;
    float delta_time;
    uint  particle_count;
    uint  _pad0;
    uint  screen_width;
    uint  screen_height;
    float spread;       // e.g. particle radius in pixels (use 1..8)
    float brightness;   // scalar multiplier for color
};
[[vk::push_constant]] PushConstants push_constants;

// Screen-sized RGBA32U buffer: 4x uint per pixel
[[vk::binding(0, 0)]] RWStructuredBuffer<uint> accum_buffer;

static const float COLOR_SCALE = 4096.0f;

// Simple hash to decorrelate particle params
float hash11(uint n) {
    n ^= n * 0x27d4eb2d;
    n ^= n >> 15;
    n *= 0x85ebca6b;
    n ^= n >> 13;
    return (n & 0x00FFFFFF) / 16777215.0; // 0..1
}

// Soft circular falloff 0..1
float soft_disk(float2 p, float r) {
    float d = length(p);
    float t = 1.0 - saturate(d / r);
    return t * t; // quadratic falloff
}

[numthreads(128,1,1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint id = tid.x;
    if (id >= push_constants.particle_count) return;

    uint W = push_constants.screen_width;
    uint H = push_constants.screen_height;

    // --- Fake particle state (replace with your state buffers later) ---
    // Unique angle & angular speed per particle
    float base  = (float)id * 0.61803398875;        // golden ratio step
    float speed = lerp(0.2, 1.2, hash11(id * 911)); // 0.2..1.2 rad/s
    float ang   = base * 6.28318 + push_constants.time * speed;

    // Radius as fraction of min dimension
    float rFrac = lerp(0.15, 0.45, hash11(id * 131)); // ring radius
    float2 normCenter = float2(0.5, 0.5) + rFrac * float2(cos(ang), sin(ang));

    // Screen-space center
    float2 center = normCenter * float2(W, H);

    // Particle footprint (radius in pixels)
    float R = max(1.0, push_constants.spread); // safety clamp

    // Bounding box of the disk (clamped to screen)
    int x0 = max(0, int(center.x - R));
    int x1 = min(int(W) - 1, int(center.x + R));
    int y0 = max(0, int(center.y - R));
    int y1 = min(int(H) - 1, int(center.y + R));

    // Color per particle (simple hash palette)
    float3 baseCol = float3(
        0.6 + 0.4 * sin(base * 17.0),
        0.6 + 0.4 * sin(base * 29.0 + 2.0),
        0.6 + 0.4 * sin(base * 41.0 + 4.0)
    ) * push_constants.brightness;

    // Write into the screen-sized accumulation buffer with additive blending
    for (int y = y0; y <= y1; ++y) {
        for (int x = x0; x <= x1; ++x) {
            float2 p = float2(x + 0.5, y + 0.5) - center;
            float w = soft_disk(p, R); // 0..1

            if (w > 0.0) {
                uint baseIdx = (uint(y) * W + uint(x)) * 4u;

                // Scale to integer domain
                uint addR = (uint)(saturate(baseCol.r * w) * COLOR_SCALE);
                uint addG = (uint)(saturate(baseCol.g * w) * COLOR_SCALE);
                uint addB = (uint)(saturate(baseCol.b * w) * COLOR_SCALE);
                uint addA = (uint)(COLOR_SCALE); // treat alpha as weight, optional

                InterlockedAdd(accum_buffer[baseIdx + 0], addR);
                InterlockedAdd(accum_buffer[baseIdx + 1], addG);
                InterlockedAdd(accum_buffer[baseIdx + 2], addB);
                InterlockedAdd(accum_buffer[baseIdx + 3], addA);
            }
        }
    }
}
