struct PushConstants {
    float time;
    float delta_time;
    uint particle_count;
    uint _pad0;
    uint texture_width;
    uint texture_height;
    float spread;
    float brightness;
};

[[vk::push_constant]] PushConstants push_constants;

RWStructuredBuffer<uint> accum_buffer : register(u0);

static const float COLOR_SCALE = 4096.0f;
static const float WEIGHT_SCALE = 1024.0f;

static const float TAU = 6.28318530718f;
static const float GOLDEN_RATIO = 1.61803398875f;

[numthreads(128, 1, 1)]
void main(uint3 global_id : SV_DispatchThreadID) {
    uint particle_id = global_id.x;
    if (particle_id >= push_constants.particle_count) {
        return;
    }

    uint tex_width = push_constants.texture_width;
    uint tex_height = push_constants.texture_height;
    if (tex_width == 0 || tex_height == 0) {
        return;
    }

    float seed = (float)particle_id * (GOLDEN_RATIO - 1.0f);
    float angle = seed * TAU + push_constants.time * 0.25f;
    float swirl = sin(push_constants.time * 0.2f + seed * 4.0f) * 0.5f;
    float radius = 0.35f + push_constants.spread * 0.4f + sin(seed * 7.0f + push_constants.time * 0.8f) * 0.2f;
    float2 disk = float2(cos(angle + swirl), sin(angle + swirl)) * radius;

    float aspect = (float)tex_width / max(1.0f, (float)tex_height);
    float2 ndc = float2(disk.x / aspect, disk.y);
    float2 uv = ndc * 0.5f + 0.5f;
    if (any(uv < 0.0f) || any(uv > 1.0f)) {
        return;
    }

    float hue = frac(seed * 0.37f + push_constants.time * 0.05f);
    float3 rgb = float3(
        sin(TAU * (hue + 0.0f)) * 0.5f + 0.5f,
        sin(TAU * (hue + 0.33f)) * 0.5f + 0.5f,
        sin(TAU * (hue + 0.66f)) * 0.5f + 0.5f
    );
    rgb = saturate(rgb);

    float shimmer = sin(seed * 11.0f + push_constants.time * 1.4f) * 0.5f + 0.5f;
    float base_weight = (0.6f + 0.4f * shimmer) * max(0.1f, push_constants.brightness);

    float2 tex_dims = float2((float)(tex_width - 1u), (float)(tex_height - 1u));
    float2 pixel = uv * tex_dims;
    int2 base_coord = int2(pixel);

    const int radius_px = 2;
    for (int oy = -radius_px; oy <= radius_px; ++oy) {
        for (int ox = -radius_px; ox <= radius_px; ++ox) {
            int2 coord = base_coord + int2(ox, oy);
            if (coord.x < 0 || coord.y < 0 || coord.x >= int(tex_width) || coord.y >= int(tex_height)) {
                continue;
            }

            float dist2 = (float)(ox * ox + oy * oy);
            float falloff = exp(-dist2 * 0.6f);
            float local_weight = base_weight * falloff;
            if (local_weight <= 0.0001f) {
                continue;
            }

            float3 deposit = rgb * local_weight;
            uint base_index = (uint(coord.y) * tex_width + uint(coord.x)) * 4u;

            InterlockedAdd(accum_buffer[base_index + 0], (uint)round(saturate(deposit.r) * COLOR_SCALE));
            InterlockedAdd(accum_buffer[base_index + 1], (uint)round(saturate(deposit.g) * COLOR_SCALE));
            InterlockedAdd(accum_buffer[base_index + 2], (uint)round(saturate(deposit.b) * COLOR_SCALE));
            InterlockedAdd(accum_buffer[base_index + 3], max(1u, (uint)round(local_weight * WEIGHT_SCALE)));
        }
    }
}

