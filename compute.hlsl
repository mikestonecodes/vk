// --- Push constants: match host layout ---
struct PushConstants {
    float time;
    float delta_time;
    uint  particle_count;
    uint  _pad0;
    uint  screen_width;
    uint  screen_height;
    float brightness;
	    float mouse_x;
	    float mouse_y;
	    uint  mouse_left;
	    uint  mouse_right;
	    uint  key_h;
	    uint  key_j;
	    uint  key_k;
	    uint  key_l;
	    uint  key_w;
	    uint  key_a;
	    uint  key_s;
	    uint  key_d;
	    uint  key_q;
	    uint  key_e;

};
[[vk::push_constant]] PushConstants push_constants;

// Global array of storage buffers
[[vk::binding(0, 0)]] RWStructuredBuffer<uint> buffers[];

struct GlobalData {
	float2 camPos;
	float zoom;
	float pad;
};

[[vk::binding(3, 0)]] RWStructuredBuffer<GlobalData> globalData;


static const float COLOR_SCALE = 4096.0f;
static const float TWO_PI      = 6.28318530718f;

// --- Hash helpers ---
float hash11(uint n) {
    n ^= n * 0x27d4eb2d;
    n ^= n >> 15;
    n *= 0x85ebca6b;
    n ^= n >> 13;
    return (n & 0x00FFFFFF) / 16777215.0;
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
    const uint W = push_constants.screen_width;
    const uint H = push_constants.screen_height;

    RWStructuredBuffer<uint> accum_buffer = buffers[0];

    // --- Load persisted camera state as floats ---
    float2 camPos = float2(globalData[0].camPos);
    float current_zoom = globalData[0].zoom;

    // Initialize zoom to 1.0 if it's 0 or invalid
    if (current_zoom <= 0.0) current_zoom = 1.0;

    // --- Input delta (normalize so diagonals aren't faster) ---
    float2 delta = float2(
        (push_constants.key_d ? 1.0 : 0.0) - (push_constants.key_a ? 1.0 : 0.0),
        (push_constants.key_s ? 1.0 : 0.0) - (push_constants.key_w ? 1.0 : 0.0)
    );
    float len2 = dot(delta, delta);
    if (len2 > 0.0) delta /= sqrt(len2);

    // --- Zoom input (E = zoom in, Q = zoom out) ---
    float zoom_delta = (push_constants.key_e ? 1.0 : 0.0) - (push_constants.key_q ? 1.0 : 0.0);
    float zoom_speed = 1.5;
    float zoom_factor = current_zoom * exp(zoom_delta * zoom_speed * push_constants.delta_time);

    // Remove zoom limits for infinite zoom
    zoom_factor = max(zoom_factor, 1e-10);

    float camera_speed = 400.0 / zoom_factor;
    camPos += delta * camera_speed * push_constants.delta_time;

    // Convert screen coordinates to world coordinates based on camera
    float2 screen_center = float2(W, H) * 0.5;
    uint pixel_id = id % (W * H);
    uint2 screen_pos = uint2(pixel_id % W, pixel_id / W);
    float2 world_pos = (float2(screen_pos) - screen_center) / zoom_factor + camPos;

    // Generate particles based on world position for infinite detail
    uint world_hash = asuint(world_pos.x * 1000.0) ^ asuint(world_pos.y * 1000.0);
    float particle_density = 0.8 * zoom_factor;

    if (hash11(world_hash)) { // Always generate particles for debugging
        // ---- Swirling cluster ----
        float2 clusterSeed = rand2(world_hash + 999u);
        float2 basePos = world_pos + clusterSeed * 10.0;

        float phase = hash11(world_hash) * TWO_PI;
        float radius = 10.0 + 40.0 * hash11(world_hash * 77u);
        float speed = 0.5 + 0.3 * hash11(world_hash * 123u);

        float2 offset = float2(
            cos(push_constants.time * speed + phase),
            sin(push_constants.time * speed + phase)
        ) * radius;

        // Transform particle world position back to screen space
        float2 particle_world_pos = basePos + offset;
        float2 screen_particle_pos = (particle_world_pos - camPos) * zoom_factor + screen_center;
        int2 ip = int2(floor(screen_particle_pos + 0.5));

        // Check if particle is visible on screen
        if (ip.x >= 0 && ip.x < int(W) && ip.y >= 0 && ip.y < int(H)) {
            uint2 pix = uint2(ip);
            uint baseIdx = (pix.y * W + pix.x) * 4u;

            // --- Color ---
            float dirtHue = 0.1 + 0.1 * sin(world_hash * 0.37);
            float3 baseCol = float3(0.35 + dirtHue, 0.25 + dirtHue*0.5, 0.15);
            baseCol *= (0.7 + 0.6 * hash11(world_hash * 771u)) * max(push_constants.brightness, 0.0);
            uint addR = (uint)(saturate(baseCol.r) * COLOR_SCALE);
            uint addG = (uint)(saturate(baseCol.g) * COLOR_SCALE);
            uint addB = (uint)(saturate(baseCol.b) * COLOR_SCALE);
            uint addA = (uint)(COLOR_SCALE);

            InterlockedAdd(accum_buffer[baseIdx+0], addR);
            InterlockedAdd(accum_buffer[baseIdx+1], addG);
            InterlockedAdd(accum_buffer[baseIdx+2], addB);
            InterlockedAdd(accum_buffer[baseIdx+3], addA);
        }
    }

    // Persist exactly once per dispatch
    if (id == 0) {
        globalData[0].camPos = camPos;
        globalData[0].zoom = zoom_factor;
    }
}
