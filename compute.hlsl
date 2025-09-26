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


float2 fade2(float2 t) {
    return t * t * (3.0f - 2.0f * t);
}

uint hash2d(int2 p, uint seed) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u + seed * 362437u;
    h ^= h >> 13;
    h *= 1274126177u;
    h ^= h >> 16;
    return h;
}

float value_noise(float2 p, uint seed) {
    float2 cell = floor(p);
    float2 local = frac(p);
    float2 u = fade2(local);

    int2 base = int2(cell);
    float n00 = hash11(hash2d(base, seed));
    float n10 = hash11(hash2d(base + int2(1, 0), seed));
    float n01 = hash11(hash2d(base + int2(0, 1), seed));
    float n11 = hash11(hash2d(base + int2(1, 1), seed));

    float nx0 = lerp(n00, n10, u.x);
    float nx1 = lerp(n01, n11, u.x);
    return lerp(nx0, nx1, u.y);
}

float fbm(float2 p, int octaves, float lacunarity, float gain, uint seed) {
    float amplitude = 0.5f;
    float frequency = 1.0f;
    float value = 0.0f;
    float range = 0.0f;

    [unroll]
    for (int i = 0; i < 8; ++i) {
        if (i >= octaves) break;
        value += value_noise(p * frequency, seed + uint(i) * 97u) * amplitude;
        range += amplitude;
        frequency *= lacunarity;
        amplitude *= gain;
    }

    return range > 0.0f ? value / range : 0.0f;
}

struct BiomeSample {
    float3 color;
    float  terrain;
    float  moisture;
};

BiomeSample sample_biome(float2 pos, float planet_radius) {
    BiomeSample sample;

    float2 coord = pos * 0.00018f;
    float elevation = fbm(coord, 5, 1.85f, 0.55f, 127u);
    float ridged    = fbm(coord * 1.8f + float2(12.3f, -7.5f), 4, 2.05f, 0.5f, 233u);
    float macro     = fbm(coord * 0.45f + float2(-21.0f, 31.0f), 3, 1.7f, 0.65f, 389u);
    float terrain   = saturate(0.55f * elevation + 0.35f * ridged + 0.10f * macro);

    float moisture  = fbm(coord + float2(96.3f, -42.7f), 4, 1.9f, 0.58f, 491u);
    float latitude  = abs(pos.y) / planet_radius;
    float polar     = smoothstep(0.55f, 0.85f, latitude);

    float ocean     = 1.0f - smoothstep(0.30f, 0.42f, terrain);
    float shore     = smoothstep(0.30f, 0.42f, terrain) * (1.0f - smoothstep(0.42f, 0.50f, terrain));
    float plains    = smoothstep(0.38f, 0.62f, terrain) * (1.0f - smoothstep(0.62f, 0.80f, terrain));
    float mountain  = smoothstep(0.60f, 0.78f, terrain) * (1.0f - smoothstep(0.78f, 0.88f, terrain));
    float snow      = smoothstep(0.85f, 0.95f, terrain) + polar * 0.6f;

    float humid     = smoothstep(0.45f, 0.75f, moisture);
    float arid      = 1.0f - smoothstep(0.35f, 0.65f, moisture);

    float desert    = plains * arid;
    float forest    = plains * humid;
    float grass     = max(plains - desert - forest, 0.0f);

    float total = ocean + shore + desert + forest + grass + mountain + snow + 1e-5f;

    float3 color =
        ocean    * float3(0.25f, 0.37f, 0.62f) +
        shore    * float3(0.68f, 0.76f, 0.65f) +
        desert   * float3(0.88f, 0.73f, 0.48f) +
        forest   * float3(0.26f, 0.48f, 0.33f) +
        grass    * float3(0.55f, 0.72f, 0.40f) +
        mountain * float3(0.56f, 0.52f, 0.50f) +
        snow     * float3(0.92f, 0.93f, 0.96f);

    color /= total;

    int2 jitter_cell = int2(floor(pos * 0.02f));
    float hue_jitter = hash11(hash2d(jitter_cell, 0x9e3779b9u)) * 0.1f - 0.05f;
    color = saturate(color + hue_jitter);

    color = saturate(lerp(color, pow(color, float3(0.90f, 0.90f, 0.92f)), 0.6f));

    sample.color = color;
    sample.terrain = terrain;
    sample.moisture = moisture;
    return sample;
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

    // Generate particle positions that cover the screen
    float2 screen_center = float2(W, H) * 0.5;
    float2 particle_uv = rand2(id + 12345u);
    float2 screen_pos = particle_uv * float2(W, H);
    float2 world_pos = (screen_pos - screen_center) / zoom_factor + camPos;

    // Early culling - skip particles outside visible area with margin
    float margin = 32.0; // pixels
    if (screen_pos.x < -margin || screen_pos.x >= W + margin ||
        screen_pos.y < -margin || screen_pos.y >= H + margin) {
        return; // Skip this particle entirely
    }

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
    float2 plant_center = float2(0.0f, 0.0f);
    float plant_radius = 10000.0f; // Much larger radius
    float dist_to_center = length(world_pos - plant_center);

    BiomeSample biome_here = sample_biome(world_pos, plant_radius);

    if (dist_to_center < plant_radius && planet_blend > 0.0f) {
        // Inside planet - render varied terrain
        uint2 screen_pos_uint = uint2(screen_pos);
        screen_pos_uint = min(screen_pos_uint, uint2(W-1, H-1));
        uint baseIdx = (screen_pos_uint.y * W + screen_pos_uint.x) * 4u;

        float3 plant_color = biome_here.color;

        // Painterly-friendly variation with soft brush accents
        float micro_variation = fbm(world_pos * 0.0012f + float2(17.0f, -9.3f), 2, 2.15f, 0.6f, 877u);
        plant_color *= lerp(0.86f, 1.12f, micro_variation);

        float edge_fade = 1.0f - saturate(dist_to_center / (plant_radius * 0.86f));
        plant_color *= (0.72f + 0.28f * edge_fade);

        plant_color = saturate(plant_color * max(push_constants.brightness, 0.0f));

        // Batch color values to reduce atomic operations
        uint addR = (uint)(plant_color.r * planet_blend * COLOR_SCALE);
        uint addG = (uint)(plant_color.g * planet_blend * COLOR_SCALE);
        uint addB = (uint)(plant_color.b * planet_blend * COLOR_SCALE);
        uint addA = (uint)(COLOR_SCALE * planet_blend);

        // Only add if contribution is significant
        if (addA > COLOR_SCALE * 0.01f) {
            InterlockedAdd(accum_buffer[baseIdx+0], addR);
            InterlockedAdd(accum_buffer[baseIdx+1], addG);
            InterlockedAdd(accum_buffer[baseIdx+2], addB);
            InterlockedAdd(accum_buffer[baseIdx+3], addA);
        }
    }
    // Stars in space (outside planet)
    else if (planet_blend > 0.0) {
        // Create stars based on world position - very sparse since they splat
        uint star_hash = asuint(world_pos.x * 0.01) ^ asuint(world_pos.y * 0.01);
        if (hash11(star_hash) > 0.993) { // Very sparse stars for splatting
            uint2 screen_pos_uint = uint2(screen_pos);
            screen_pos_uint = min(screen_pos_uint, uint2(W-1, H-1));
            uint baseIdx = (screen_pos_uint.y * W + screen_pos_uint.x) * 4u;

            // Make stars bright with color variation
            float star_variation = hash11(star_hash * 123u);
            float3 star_color;
            if (star_variation < 0.1) {
                star_color = float3(15.0, 12.0, 8.0); // Orange giant
            } else if (star_variation < 0.3) {
                star_color = float3(8.0, 12.0, 18.0); // Blue star
            } else if (star_variation < 0.6) {
                star_color = float3(18.0, 15.0, 12.0); // White star
            } else {
                star_color = float3(12.0, 18.0, 14.0); // Green-white
            }

            uint addR = (uint)(saturate(star_color.r * planet_blend) * COLOR_SCALE);
            uint addG = (uint)(saturate(star_color.g * planet_blend) * COLOR_SCALE);
            uint addB = (uint)(saturate(star_color.b * planet_blend) * COLOR_SCALE);
            uint addA = (uint)(COLOR_SCALE * planet_blend);

            if (addA > COLOR_SCALE * 0.01) {
                InterlockedAdd(accum_buffer[baseIdx+0], addR);
                InterlockedAdd(accum_buffer[baseIdx+1], addG);
                InterlockedAdd(accum_buffer[baseIdx+2], addB);
                InterlockedAdd(accum_buffer[baseIdx+3], addA);
            }
        }
    }

    // Dirt layer (brush strokes following biome flow)
    if (dirt_blend > 0.0f) {
        float2 temporal_offset = float2(push_constants.time * 0.03f, -push_constants.time * 0.017f);
        float brush_field = fbm(world_pos * 0.00085f + temporal_offset, 4, 1.85f, 0.55f, 601u);
        float scatter = hash11(world_hash * 977u);

        if (brush_field > scatter) {
            float2 flow_origin = world_pos + (rand2(world_hash + 999u) - 0.5f) * 80.0f;
            float flow_angle = fbm(flow_origin * 0.0006f + float2(push_constants.time * 0.02f, -push_constants.time * 0.015f), 3, 1.9f, 0.6f, 811u) * TWO_PI;
            float2 dir = float2(cos(flow_angle), sin(flow_angle));
            float jitter = hash11(world_hash * 313u) - 0.5f;
            float pulse_speed = 0.4f + 0.6f * hash11(world_hash * 173u);
            float pulse = sin(push_constants.time * pulse_speed + hash11(world_hash * 127u) * TWO_PI);
            float stroke_length = lerp(14.0f, 64.0f, brush_field);

            float2 particle_world_pos = flow_origin + dir * stroke_length * pulse + float2(-dir.y, dir.x) * jitter * stroke_length * 0.35f;
            float2 screen_particle_pos = (particle_world_pos - camPos) * zoom_factor + screen_center;
            int2 ip = int2(floor(screen_particle_pos + 0.5f));

            // Check if particle is visible on screen
            if (ip.x >= 0 && ip.x < int(W) && ip.y >= 0 && ip.y < int(H)) {
                uint2 pix = uint2(ip);
                uint baseIdx = (pix.y * W + pix.x) * 4u;

                BiomeSample stroke_biome = sample_biome(particle_world_pos, plant_radius);
                float3 baseCol = saturate(pow(stroke_biome.color, float3(0.88f, 0.90f, 0.92f)));
                baseCol *= (0.70f + 0.60f * brush_field);
                baseCol = saturate(baseCol * max(push_constants.brightness, 0.0f));

                float alpha_boost = 0.60f + 0.40f * brush_field;
                uint addR = (uint)(baseCol.r * dirt_blend * COLOR_SCALE);
                uint addG = (uint)(baseCol.g * dirt_blend * COLOR_SCALE);
                uint addB = (uint)(baseCol.b * dirt_blend * COLOR_SCALE);
                uint addA = (uint)(COLOR_SCALE * dirt_blend * alpha_boost);

                if (addA > COLOR_SCALE * 0.01f) {
                    InterlockedAdd(accum_buffer[baseIdx+0], addR);
                    InterlockedAdd(accum_buffer[baseIdx+1], addG);
                    InterlockedAdd(accum_buffer[baseIdx+2], addB);
                    InterlockedAdd(accum_buffer[baseIdx+3], addA);
                }
            }
        }
    }

    // Persist exactly once per dispatch
    if (id == 0) {
        globalData[0].camPos = camPos;
        globalData[0].zoom = zoom_factor;
    }
}
