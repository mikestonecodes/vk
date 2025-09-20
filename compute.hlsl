struct PushConstants {
    float time;
    float delta_time;
    uint particle_count;
    uint _pad0;
    uint texture_width;
    uint texture_height;
    float spread;
    float brightness;
    uint sprite_width;
    uint sprite_height;
};

[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(0, 0)]] RWStructuredBuffer<uint> accum_buffer;
[[vk::binding(1, 0)]] Texture2D sprite_texture;
[[vk::binding(2, 0)]] SamplerState sprite_sampler;

static const float COLOR_SCALE = 4096.0f;
static const float WEIGHT_SCALE = 1024.0f;

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

    uint total_pixels = tex_width * tex_height;
    if (particle_id >= total_pixels) {
        return;
    }

    uint sprite_w = max(1u, push_constants.sprite_width);
    uint sprite_h = max(1u, push_constants.sprite_height);
    if (sprite_w == 0 || sprite_h == 0) {
        return;
    }

    float grid_scale = max(push_constants.spread, 0.25f);
    uint grid_cols = max(1u, (uint)round(4.0f * grid_scale));
    uint grid_rows = max(1u, (uint)round(3.0f * grid_scale));

    uint px = particle_id % tex_width;
    uint py = particle_id / tex_width;

    uint tile_width = max(1u, tex_width / grid_cols);
    uint tile_height = max(1u, tex_height / grid_rows);

    uint tile_stride_x = max(1u, tile_width - 1u);
    uint tile_stride_y = max(1u, tile_height - 1u);

    uint local_x = px % tile_width;
    uint local_y = py % tile_height;

    float sprite_u = (float)local_x / (float)tile_stride_x;
    float sprite_v = (float)local_y / (float)tile_stride_y;

    sprite_u = saturate(sprite_u);
    sprite_v = saturate(sprite_v);

    float2 sample_uv = float2(sprite_u, sprite_v);
    float4 rgba = sprite_texture.SampleLevel(sprite_sampler, sample_uv, 0.0f);

    float alpha = max(rgba.a, 0.0001f);
    float local_weight = alpha * push_constants.brightness;
    float3 deposit = rgba.rgb * local_weight;

    uint base_index = (py * tex_width + px) * 4u;

    InterlockedAdd(accum_buffer[base_index + 0], (uint)round(saturate(deposit.r) * COLOR_SCALE));
    InterlockedAdd(accum_buffer[base_index + 1], (uint)round(saturate(deposit.g) * COLOR_SCALE));
    InterlockedAdd(accum_buffer[base_index + 2], (uint)round(saturate(deposit.b) * COLOR_SCALE));
    InterlockedAdd(accum_buffer[base_index + 3], max(1u, (uint)round(local_weight * WEIGHT_SCALE)));
}
