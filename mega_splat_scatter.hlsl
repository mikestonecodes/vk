// Mega Splat - Scatter Pass: Each particle adds density at one pixel location

struct PushConstants {
    float time;
    float delta_time;
    uint  particle_count;
    uint  _pad0;
    uint  screen_width;
    uint  screen_height;
    float brightness;
    uint  blur_radius;
    float blur_sigma;
    uint  _pad1;
    uint  _pad2;
    uint  _pad3;
};
[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(0, 0)]] RWTexture2D<float> density_texture;

// Hash function for particle decorrelation
float hash11(uint n) {
    n ^= n * 0x27d4eb2d;
    n ^= n >> 15;
    n *= 0x85ebca6b;
    n ^= n >> 13;
    return (n & 0x00FFFFFF) / 16777215.0;
}

[numthreads(128,1,1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint id = tid.x;
    if (id >= push_constants.particle_count) return;

    uint W = push_constants.screen_width;
    uint H = push_constants.screen_height;

    // Generate particle position (same logic as original)
    float base  = (float)id * 0.61803398875;
    float speed = 0.002;
    float ang   = base * 6.28318 + push_constants.time * speed;

    float rFrac = lerp(0.15, 0.45, hash11(id * 131));
    float2 normCenter = float2(0.5, 0.5) + rFrac * float2(cos(ang), sin(ang));
    float2 center = normCenter * float2(W, H);

    // Clamp to texture bounds
    uint2 pix = uint2(clamp(center, float2(0, 0), float2(W-1, H-1)));

    // Add density contribution - no loops, no texture sampling
    // The brightness here determines the "mass" of each particle
    density_texture[pix] = density_texture[pix] + push_constants.brightness;
}