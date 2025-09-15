struct PushConstants {
    float time;
    uint quad_count;
    float delta_time;
    // Level spawning control
    float spawn_delay;  // seconds between each level appearing
    float max_visible_level;  // current maximum visible level (grows over time)
    // Input state
    float mouse_x;
    float mouse_y;
    uint mouse_left;
    uint mouse_right;
    // Keyboard state (vim keys + common keys)
    uint key_h;
    uint key_j;
    uint key_k;
    uint key_l;
    uint key_w;
    uint key_a;
    uint key_s;
    uint key_d;
    uint key_q;
    uint key_e;
    uint texture_width;
    uint texture_height;
    float splat_extent;
    float fog_strength;
};

[[vk::push_constant]] PushConstants push_constants;

struct Quad {
    float2 position;
    float2 size;
    float4 color;
    float rotation;
    float depth;
    float2 _padding; // Align to 16-byte boundary
};

struct CameraState {
    float x;
    float y;
    float zoom;
    float _padding;
};

struct Line {
    float2 start_pos;
    float2 end_pos;
    float4 color;
};

RWStructuredBuffer<Quad> world_quads : register(u0);
RWStructuredBuffer<Quad> visible_quads : register(u1);
RWStructuredBuffer<uint> visible_count : register(u2);
RWStructuredBuffer<CameraState> camera : register(u3);
RWStructuredBuffer<uint> accum_buffer : register(u4);
Texture2D sprite_texture : register(t5);
SamplerState sprite_sampler : register(s6);

[numthreads(64, 1, 1)]
void main(uint3 global_id : SV_DispatchThreadID) {
    uint quad_id = global_id.x;
    if (quad_id >= push_constants.quad_count) {
        return;
    }

    // Update camera state only for first thread to avoid race conditions
    if (quad_id == 0) {
        // Reset visible count at start of each frame
        uint dummy;
        InterlockedExchange(visible_count[0], 0, dummy);

        float move_speed = 1.0;
        float zoom_speed = 1.5;
        float dt = push_constants.delta_time;

        // Update camera based on input (WASD)
        if (push_constants.key_a != 0) { camera[0].x -= move_speed * dt; }
        if (push_constants.key_d != 0) { camera[0].x += move_speed * dt; }
        if (push_constants.key_w != 0) { camera[0].y += move_speed * dt; }
        if (push_constants.key_s != 0) { camera[0].y -= move_speed * dt; }

        // Zoom controls (Q = zoom in, E = zoom out)
        if (push_constants.key_q != 0) { camera[0].zoom += zoom_speed * dt; }
        if (push_constants.key_e != 0) { camera[0].zoom -= zoom_speed * dt; }
        camera[0].zoom = clamp(camera[0].zoom, 0.05, 30.0);
        // For next frame, draw all quads and preserve deterministic ordering by ID
        // Host reads this value one frame later, so set it now after reset
        visible_count[0] = push_constants.quad_count;
    }

    // Ensure camera updates and counter reset are visible to all threads
    GroupMemoryBarrierWithGroupSync();

    // Infinite world positioning - distribute quads across infinite space
    // Use deterministic pseudo-random positioning based on quad ID
    float pos_seed_x = (float)quad_id * 0.1372549 + 1000.0; // Large prime-like multiplier
    float pos_seed_y = (float)quad_id * 0.2718281 + 2000.0; // Different seed for Y

    // Create infinite world positions using multiple octaves of noise-like functions
    // Concentrate particles closer to the origin to densely fill the screen
    float world_scale = 1.2; // Smaller spread -> higher on-screen density
    float base_x = sin(pos_seed_x) * world_scale + cos(pos_seed_x * 0.7) * world_scale * 0.5;
    float base_y = sin(pos_seed_y) * world_scale + cos(pos_seed_y * 0.7) * world_scale * 0.5;

    // Add chaotic movement and drift for animation
    float chaos_factor = sin((float)quad_id * 0.1 + push_constants.time * 0.01) * cos((float)quad_id * 0.7 + push_constants.time * 1.5);
    // Reduce drift so particles remain within view more consistently
    float drift_x = sin((float)quad_id * 0.123 + push_constants.time * 0.08) * 0.25;
    float drift_y = cos((float)quad_id * 0.456 + push_constants.time * 0.2) * 0.25;

    // Constant quad size - not dependent on count or grid
    // Use smaller quads for a denser, non-blocky appearance
    float2 constant_size = float2(0.03, 0.03);
    float size_variation = 1.0 + sin((float)quad_id * 0.789 + push_constants.time * 0.6) * 0.25; // Small variation
    float2 quad_size = constant_size * size_variation;

    float2 world_pos = float2(base_x + drift_x, base_y + drift_y);

    float zoom = camera[0].zoom;
    float2 camera_relative_pos = (world_pos + float2(camera[0].x, camera[0].y)) * zoom;
    // Clamp maximum size to avoid unbounded growth when zoomed in heavily
    float2 final_size = min(quad_size * zoom, float2(1.0, 1.0));

    // Enhanced culling: frustum + size-based performance culling
    // Slightly wider bounds to avoid over-culling due to aspect/transform differences
    float4 screen_bounds = float4(-1.6, -1.6, 1.6, 1.6);
    float2 quad_half_size = final_size * 0.5;
    float4 quad_bounds = float4(
        camera_relative_pos.x - quad_half_size.x,
        camera_relative_pos.y - quad_half_size.y,
        camera_relative_pos.x + quad_half_size.x,
        camera_relative_pos.y + quad_half_size.y
    );

    // Frustum culling
    bool outside_frustum = quad_bounds.z < screen_bounds.x ||
                          quad_bounds.x > screen_bounds.z ||
                          quad_bounds.w < screen_bounds.y ||
                          quad_bounds.y > screen_bounds.w;

    // Balanced culling - eliminate worst offenders but keep variety
    float max_size = max(final_size.x, final_size.y);
    float area = final_size.x * final_size.y;
    bool too_big = max_size > 0.6 || area > 0.2; // Retain protection from giant quads
    bool too_small = false; // Do not cull tiny quads; maximize density

    // Additional performance-based culling for overlaps
    float distance_from_center = length(camera_relative_pos);
    bool very_close_to_camera = distance_from_center < 0.05;
    bool performance_cull = very_close_to_camera && max_size > 0.4; // Less aggressive

    // Temporarily disable culling to guarantee visibility and validate depth path
    bool should_cull = false;

    // Calculate depth with better separation for early Z rejection
    // Use quad ID to create hierarchical depth layers
    float quad_level = (float)(quad_id % 10) / 10.0; // Create 10 depth levels based on quad ID
    float size_factor = (final_size.x + final_size.y) * 0.5;

    // Combine level-based depth with size factor for better separation
    float base_depth = quad_level * 0.6; // Level contributes 0.0-0.6
    float size_depth = clamp(size_factor * 0.1, 0.0, 0.4); // Size contributes 0.0-0.4
    // Keep depth strictly below clear value to guarantee passing with LESS or LESS_OR_EQUAL
    float computed_depth = clamp(base_depth + size_depth, 0.0, 0.99);

    // Always update world buffer with computed quad data
    world_quads[quad_id].position = camera_relative_pos;
    world_quads[quad_id].size = final_size;
    world_quads[quad_id].rotation = sin((float)quad_id * 0.234 + push_constants.time * 1.8) * 1.5 + chaos_factor;
    world_quads[quad_id].depth = computed_depth;

    // Compute color for world quad
    float color_shift = sin((float)quad_id * 0.167 + push_constants.time * 0.5);
    float color_pulse = cos((float)quad_id * 0.891 + push_constants.time * 0.2);

    float3 base_colors[2] = {
        float3(0.2, 0.4, 9.9),  // Deep blue
        float3(0.2, 0.4, 9.9),  // Deep blue
    };

    uint color_index = (uint)abs(color_shift * 2.5) % 5;
    float3 base_color = (color_index == 1) ? base_colors[1] : base_colors[0];
    float3 paint_color = base_color + float3(color_pulse * 0.3, color_shift * 0.2, chaos_factor * 0.4);
    float alpha_variation = 0.3 + abs(sin((float)quad_id * 0.678 + push_constants.time * 1.9)) * 0.7;

    world_quads[quad_id].color = float4(
        paint_color.r,
        paint_color.g,
        paint_color.b,
        alpha_variation
    );


    // Only add to visible buffer if not culled
    if (!should_cull) {
        // Deterministic painter-style ordering: write by quad ID index
        // This ensures the draw order is exactly by ID

        // Apply depth-based alpha and color modifications for better depth perception
        float depth_alpha_factor = clamp(1.0 - computed_depth * 0.3, 0.3, 1.0);
        float depth_brightness = clamp(1.0 - computed_depth * 0.4, 0.4, 1.0);

        world_quads[quad_id].color = float4(
            paint_color.r * depth_brightness,
            paint_color.g * depth_brightness,
            paint_color.b * depth_brightness,
            alpha_variation * depth_alpha_factor
        );


        // Project particle into the accumulation texture and splat with a soft falloff
        uint tex_w = push_constants.texture_width;
        uint tex_h = push_constants.texture_height;
        if (tex_w > 0 && tex_h > 0) {
            float aspect_ratio = (float)tex_w / max(1.0, (float)tex_h);
            float2 ndc = float2(camera_relative_pos.x / aspect_ratio, camera_relative_pos.y);
            float2 uv = ndc * 0.5 + 0.5;

            bool inside = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
            if (inside) {
                float2 dims = float2((float)tex_w, (float)tex_h);
                float2 pixel_f = uv * (dims - 1.0);
                int2 base_pixel = int2(pixel_f + 0.5);

                float splat_extent = max(push_constants.splat_extent, 0.0);
                int radius = min(3, max(1, (int)ceil(splat_extent)));
                float radius_f = max(1.0, (float)radius);
                float gaussian_base = 0.65 + push_constants.fog_strength * 0.45;

                const float COLOR_SCALE = 4096.0;
                const float WEIGHT_SCALE = 2048.0;

                float depth_energy = saturate(1.0 - computed_depth * 0.9);
                float fog_boost = exp(-computed_depth * 2.2) * push_constants.fog_strength;
                float intensity = saturate(world_quads[quad_id].color.a * 0.5 + depth_energy * 0.7 + fog_boost);
                float3 deposit_color = saturate(world_quads[quad_id].color.rgb * intensity);

                for (int oy = -radius; oy <= radius; ++oy) {
                    for (int ox = -radius; ox <= radius; ++ox) {
                        int2 pixel_coord = base_pixel + int2(ox, oy);
                        if (pixel_coord.x < 0 || pixel_coord.y < 0 || pixel_coord.x >= int(tex_w) || pixel_coord.y >= int(tex_h)) {
                            continue;
                        }

                        float distance2 = (float)(ox * ox + oy * oy);
                        float falloff = exp(-distance2 * gaussian_base);
                        float2 sprite_uv = (float2(float(ox), float(oy)) / radius_f) * 0.5 + 0.5;
                        if (sprite_uv.x < 0.0 || sprite_uv.x > 1.0 || sprite_uv.y < 0.0 || sprite_uv.y > 1.0) {
                            continue;
                        }

                        float4 sprite_sample = sprite_texture.SampleLevel(sprite_sampler, sprite_uv, 0.0);
                        float sprite_alpha = sprite_sample.a;
                        if (sprite_alpha <= 0.0001) {
                            continue;
                        }

                        float local_weight = intensity * sprite_alpha * falloff;
                        if (local_weight <= 0.0001) {
                            continue;
                        }

                        float3 texture_color = sprite_sample.rgb;
                        float3 color_tint = lerp(float3(1.0, 1.0, 1.0), texture_color, sprite_alpha);
                        float3 local_color = saturate(deposit_color * color_tint * sprite_alpha * falloff);
                        uint encoded_r = (uint)round(local_color.r * COLOR_SCALE);
                        uint encoded_g = (uint)round(local_color.g * COLOR_SCALE);
                        uint encoded_b = (uint)round(local_color.b * COLOR_SCALE);
                        uint encoded_w = max(1, (uint)round(local_weight * WEIGHT_SCALE));

                        uint base_index = (uint(pixel_coord.y) * tex_w + uint(pixel_coord.x)) * 4;
                        InterlockedAdd(accum_buffer[base_index + 0], encoded_r);
                        InterlockedAdd(accum_buffer[base_index + 1], encoded_g);
                        InterlockedAdd(accum_buffer[base_index + 2], encoded_b);
                        InterlockedAdd(accum_buffer[base_index + 3], encoded_w);
                    }
                }
            }
        }

        visible_quads[quad_id] = world_quads[quad_id];
    }
}
