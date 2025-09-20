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

    // Simple grid pattern
    uint grid_size = 16; // Grid cells per dimension
    uint particles_per_row = (uint)sqrt((float)push_constants.particle_count);
    particles_per_row = max(1u, particles_per_row);

    uint grid_x = particle_id % particles_per_row;
    uint grid_y = particle_id / particles_per_row;

    float2 grid_pos = float2((float)grid_x / (float)particles_per_row, (float)grid_y / (float)particles_per_row);

    float2 uv = grid_pos;
    if (any(uv < 0.0f) || any(uv > 1.0f)) {
        return;
    }

    // Simple color based on grid position
    float3 rgb = float3(grid_pos.x, grid_pos.y, 0.5f);
    rgb = saturate(rgb);

    float base_weight = push_constants.brightness;

    float2 tex_dims = float2((float)(tex_width - 1u), (float)(tex_height - 1u));
    float2 pixel = uv * tex_dims;
    int2 base_coord = int2(pixel);

    const int radius_px = 1;
    for (int oy = -radius_px; oy <= radius_px; ++oy) {
        for (int ox = -radius_px; ox <= radius_px; ++ox) {
            int2 coord = base_coord + int2(ox, oy);
            if (coord.x < 0 || coord.y < 0 || coord.x >= int(tex_width) || coord.y >= int(tex_height)) {
                continue;
            }

            float local_weight = base_weight;
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

