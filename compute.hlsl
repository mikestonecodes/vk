// --- Push constants: match this layout on the host exactly ---
struct PushConstants {
    float time;
    float delta_time;
    uint  particle_count;
    uint  _pad0;
    uint  screen_width;
    uint  screen_height;
    float spread;       // unused here (for future)
    float brightness;   // scalar multiplier for color
};
[[vk::push_constant]] PushConstants push_constants;

// Screen-sized RGBA32U buffer: 4x uint per pixel (linear)
[[vk::binding(0, 0)]] RWStructuredBuffer<uint> accum_buffer;

static const float COLOR_SCALE = 4096.0f;
static const float TWO_PI      = 6.28318530718f;

// Hash helpers
float hash11(uint n) {
    n ^= n * 0x27d4eb2d;
    n ^= n >> 15;
    n *= 0x85ebca6b;
    n ^= n >> 13;
    return (n & 0x00FFFFFF) / 16777215.0; // 0..1
}

float2 rand2(uint n) {
    n ^= n * 0x27d4eb2d;
    n ^= n >> 15;
    n *= 0x85ebca6b;
    n ^= n >> 13;
    return float2(
        (n & 0xFFFF) * (1.0f/65535.0f),
        ((n >> 16) & 0xFFFF) * (1.0f/65535.0f)
    );
}

[numthreads(128,1,1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    uint id = tid.x;
    if (id >= push_constants.particle_count) return;

    const uint W = push_constants.screen_width;
    const uint H = push_constants.screen_height;

    // ---- Swirling cluster logic ----
    // Cluster center (same for ~256 particles)
    float2 clusterSeed = rand2((id / 256u) + 999u);
    float2 basePos     = clusterSeed * float2(W, H);

    // Particle-specific orbit
    float phase  = hash11(id) * TWO_PI;
    float radius = 10.0 + 40.0 * hash11(id * 77u);
    float speed  = 0.5  +  0.2 * hash11(id * 31337u);

    float2 offset = float2(
        cos(push_constants.time * speed + phase),
        sin(push_constants.time * speed + phase)
    ) * radius;

    float2 center = basePos + offset;

    // ---- Robust pixel address: check range BEFORE casting to uint ----
    // (Casting a negative float to uint would wrap to a huge value)
    int2 ip = int2(floor(center + 0.5)); // round-to-nearest pixel
    if (ip.x < 0 || ip.x >= int(W) || ip.y < 0 || ip.y >= int(H)) return;

    uint2 pix = uint2(ip);
    uint  baseIdx = (pix.y * W + pix.x) * 4u;

    // ---- Dirt color (brownish), premultiplied by brightness ----
    float dirtHue  = 0.1 + 0.1 * sin(id * 0.37);
    float3 baseCol = float3(0.35 + dirtHue, 0.25 + dirtHue*0.5, 0.15);
    baseCol *= (0.7 + 0.6 * hash11(id * 771u)) * max(push_constants.brightness, 0.0);

    // Clamp & scale to integer domain
    uint addR = (uint)(saturate(baseCol.r) * COLOR_SCALE);
    uint addG = (uint)(saturate(baseCol.g) * COLOR_SCALE);
    uint addB = (uint)(saturate(baseCol.b) * COLOR_SCALE);
    uint addA = (uint)(COLOR_SCALE); // treat alpha as weight/count

    // ---- Atomic adds ----
    InterlockedAdd(accum_buffer[baseIdx + 0], addR);
    InterlockedAdd(accum_buffer[baseIdx + 1], addG);
    InterlockedAdd(accum_buffer[baseIdx + 2], addB);
    InterlockedAdd(accum_buffer[baseIdx + 3], addA);
}
