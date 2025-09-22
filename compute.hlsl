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

    // Scale-dependent rendering
    float scale = 1.0 / zoom_factor;

    // Smooth transition - calculate blend factors
    float transition_start = 1.0;
    float transition_end = 3.0;
    float planet_blend = saturate((scale - transition_start) / (transition_end - transition_start));
    float dirt_blend = 1.0 - planet_blend;

    // Planet layer - make it huge so it fills the screen when zoomed out
    float2 plant_center = float2(0, 0);
    float plant_radius = 10000.0; // Much larger radius
    float dist_to_center = length(world_pos - plant_center);

    if (dist_to_center < plant_radius && planet_blend > 0.0) {
        // Inside planet - render varied terrain
        uint2 screen_pos_uint = uint2(pixel_id % W, pixel_id / W);
        uint baseIdx = (screen_pos_uint.y * W + screen_pos_uint.x) * 4u;

        // Create varied terrain based on world position - make regions much larger
        uint terrain_hash = asuint(world_pos.x * 0.0001) ^ asuint(world_pos.y * 0.0001);
        float terrain_type = hash11(terrain_hash);

        float3 plant_color;
        if (terrain_type < 0.3) {
            // Forests - green
            plant_color = float3(0.2, 0.6, 0.2);
        } else if (terrain_type < 0.5) {
            // Grasslands - light green
            plant_color = float3(0.4, 0.7, 0.3);
        } else if (terrain_type < 0.7) {
            // Deserts - sandy brown
            plant_color = float3(0.8, 0.7, 0.4);
        } else {
            // Oceans - blue
            plant_color = float3(0.2, 0.4, 0.8);
        }

        plant_color *= max(push_constants.brightness, 0.0);
        uint addR = (uint)(saturate(plant_color.r * planet_blend) * COLOR_SCALE);
        uint addG = (uint)(saturate(plant_color.g * planet_blend) * COLOR_SCALE);
        uint addB = (uint)(saturate(plant_color.b * planet_blend) * COLOR_SCALE);
        uint addA = (uint)(COLOR_SCALE * planet_blend);

        InterlockedAdd(accum_buffer[baseIdx+0], addR);
        InterlockedAdd(accum_buffer[baseIdx+1], addG);
        InterlockedAdd(accum_buffer[baseIdx+2], addB);
        InterlockedAdd(accum_buffer[baseIdx+3], addA);
    }
    // Stars in space (outside planet)
    else if (planet_blend > 0.0) {
        // Create stars based on world position - very sparse since they splat
        uint star_hash = asuint(world_pos.x * 0.01) ^ asuint(world_pos.y * 0.01);
        if (hash11(star_hash) > 0.993) { // Very sparse stars for splatting
            uint2 screen_pos_uint = uint2(pixel_id % W, pixel_id / W);
            uint baseIdx = (screen_pos_uint.y * W + screen_pos_uint.x) * 4u;

            // Make stars bright white
            float3 star_color = float3(9.0, 9.0, 9.0) ;

            uint addR = (uint)(saturate(star_color.r * planet_blend) * COLOR_SCALE);
            uint addG = (uint)(saturate(star_color.g * planet_blend) * COLOR_SCALE);
            uint addB = (uint)(saturate(star_color.b * planet_blend) * COLOR_SCALE);
            uint addA = (uint)(COLOR_SCALE * planet_blend);

            InterlockedAdd(accum_buffer[baseIdx+0], addR);
            InterlockedAdd(accum_buffer[baseIdx+1], addG);
            InterlockedAdd(accum_buffer[baseIdx+2], addB);
            InterlockedAdd(accum_buffer[baseIdx+3], addA);
        }
    }

    // Dirt layer
    if (dirt_blend > 0.0 && hash11(world_hash)) {
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

            // --- Color aligned with planet terrain ---
            uint terrain_hash_dirt = asuint(world_pos.x * 0.0001) ^ asuint(world_pos.y * 0.0001);
            float terrain_type_dirt = hash11(terrain_hash_dirt);

            float3 baseCol;
            if (terrain_type_dirt < 0.3) {
                // Forest soil - dark brown
                baseCol = float3(0.3, 0.2, 0.1);
            } else if (terrain_type_dirt < 0.5) {
                // Grassland soil - medium brown
                baseCol = float3(0.4, 0.3, 0.2);
            } else if (terrain_type_dirt < 0.7) {
                // Desert sand - light tan
                baseCol = float3(0.6, 0.5, 0.3);
            } else {
                // Ocean sediment - gray-blue
                baseCol = float3(0.3, 0.3, 0.4);
            }

            // Add some variation
            float variation = 0.7 + 0.6 * hash11(world_hash * 771u);
            baseCol *= variation * max(push_constants.brightness, 0.0);
            uint addR = (uint)(saturate(baseCol.r * dirt_blend) * COLOR_SCALE);
            uint addG = (uint)(saturate(baseCol.g * dirt_blend) * COLOR_SCALE);
            uint addB = (uint)(saturate(baseCol.b * dirt_blend) * COLOR_SCALE);
            uint addA = (uint)(COLOR_SCALE * dirt_blend);

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
