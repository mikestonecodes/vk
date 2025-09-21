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

    // Clamp zoom to reasonable bounds
    zoom_factor = clamp(zoom_factor, 0.1, 10.0);




    float camera_speed = 400.0;
    camPos += delta * camera_speed * push_constants.delta_time;

    // ---- Swirling cluster ----
    float2 clusterSeed = rand2((id / 256u) + 999u);
    float2 basePos     = clusterSeed * float2(W, H);

    float phase  = hash11(id) * TWO_PI;
    float radius = 10.0 + 40.0 * hash11(id * 77u);
    //float speed  = 0.5  + 0.2 * hash11(id * 31337u);

    float speed  = 0.0;

    float2 offset = float2(
        cos(push_constants.time * speed + phase),
        sin(push_constants.time * speed + phase)
    ) * radius;

    // Integer pixel coord after applying persistent camera and zoom
    float2 screen_center = float2(W, H) * 0.5;
    float2 p = basePos + offset + camPos;
    // Invert zoom so higher values = zoom in (make things bigger)
    p = (p - screen_center) / zoom_factor + screen_center;
    int2 ip  = int2(floor(p + 0.5));

    // Proper wrapping for negative coordinates
    if (ip.x < 0) ip.x = int(W) - 1 - ((-ip.x - 1) % int(W));
    else ip.x = ip.x % int(W);

    if (ip.y < 0) ip.y = int(H) - 1 - ((-ip.y - 1) % int(H));
    else ip.y = ip.y % int(H);

    uint2 pix = uint2(ip);
    uint baseIdx = (pix.y * W + pix.x) * 4u;

    // --- Color ---
    float dirtHue  = 0.1 + 0.1 * sin(id * 0.37);
    float3 baseCol = float3(0.35 + dirtHue, 0.25 + dirtHue*0.5, 0.15);
    baseCol *= (0.7 + 0.6 * hash11(id * 771u)) * max(push_constants.brightness, 0.0);
    uint addR = (uint)(saturate(baseCol.r) * COLOR_SCALE);
    uint addG = (uint)(saturate(baseCol.g) * COLOR_SCALE);
    uint addB = (uint)(saturate(baseCol.b) * COLOR_SCALE);
    uint addA = (uint)(COLOR_SCALE);

    InterlockedAdd(accum_buffer[baseIdx+0], addR);
    InterlockedAdd(accum_buffer[baseIdx+1], addG);
    InterlockedAdd(accum_buffer[baseIdx+2], addB);
    InterlockedAdd(accum_buffer[baseIdx+3], addA);

    // Persist exactly once per dispatch
    if (id == 0) {
        globalData[0].camPos = camPos;
        globalData[0].zoom = zoom_factor;
    }
}

