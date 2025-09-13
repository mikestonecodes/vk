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

        float move_speed = 2.0;
        float zoom_speed = 0.1;
        float dt = push_constants.delta_time;

        // Update camera based on input (WASD)
        if (push_constants.key_a != 0) { camera[0].x -= move_speed * dt; }
        if (push_constants.key_d != 0) { camera[0].x += move_speed * dt; }
        if (push_constants.key_w != 0) { camera[0].y += move_speed * dt; }
        if (push_constants.key_s != 0) { camera[0].y -= move_speed * dt; }

        // Zoom with q/e - multiplicative zoom for smooth "through" feeling
        if (push_constants.key_e != 0) {
            camera[0].zoom *= 1.0 + zoom_speed * dt * 5.0; // zoom in multiplicatively
        }
        if (push_constants.key_q != 0) {
            camera[0].zoom /= 1.0 + zoom_speed * dt * 5.0; // zoom out multiplicatively
        }
        camera[0].zoom = max(0.01, camera[0].zoom);
    }

    // Ensure camera updates and counter reset are visible to all threads
    GroupMemoryBarrierWithGroupSync();

    // Infinite world positioning - distribute quads across infinite space
    // Use deterministic pseudo-random positioning based on quad ID
    float pos_seed_x = (float)quad_id * 0.1372549 + 1000.0; // Large prime-like multiplier
    float pos_seed_y = (float)quad_id * 0.2718281 + 2000.0; // Different seed for Y

    // Create infinite world positions using multiple octaves of noise-like functions
    float world_scale = 15.0; // How spread out quads are in world space - smaller for denser particles
    float base_x = sin(pos_seed_x) * world_scale + cos(pos_seed_x * 0.7) * world_scale * 0.5;
    float base_y = sin(pos_seed_y) * world_scale + cos(pos_seed_y * 0.7) * world_scale * 0.5;

    // Add chaotic movement and drift for animation
    float chaos_factor = sin((float)quad_id * 0.1 + push_constants.time * 0.01) * cos((float)quad_id * 0.7 + push_constants.time * 1.5);
    float drift_x = sin((float)quad_id * 0.123 + push_constants.time * 0.08) * 2.0;
    float drift_y = cos((float)quad_id * 0.456 + push_constants.time * 0.2) * 2.0;

    // Constant quad size - not dependent on count or grid
    float2 constant_size = float2(0.08, 0.08); // Fixed size for all quads - smaller for denser appearance
    float size_variation = 1.0 + sin((float)quad_id * 0.789 + push_constants.time * 0.6) * 0.3; // Small variation
    float2 quad_size = constant_size * size_variation;

    float2 world_pos = float2(base_x + drift_x, base_y + drift_y);

    float2 camera_relative_pos = world_pos + float2(camera[0].x, camera[0].y);
    float2 final_size = min(quad_size * camera[0].zoom, float2(1.5, 1.5));

    // Enhanced culling: frustum + size-based performance culling
    float4 screen_bounds = float4(-1.2, -1.2, 1.2, 1.2); // Slightly expanded for safety
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
    bool too_big = max_size > 0.6 || area > 0.2; // Less strict limits
    bool too_small = max_size < 0.005; // Keep more small quads visible

    // Additional performance-based culling for overlaps
    float distance_from_center = length(camera_relative_pos);
    bool very_close_to_camera = distance_from_center < 0.05;
    bool performance_cull = very_close_to_camera && max_size > 0.4; // Less aggressive

    bool should_cull = outside_frustum || too_big || too_small; // Re-enable culling but remove performance_cull

    // Calculate depth with better separation for early Z rejection
    // Use quad ID to create hierarchical depth layers
    float quad_level = (float)(quad_id % 10) / 10.0; // Create 10 depth levels based on quad ID
    float size_factor = (final_size.x + final_size.y) * 0.5;

    // Combine level-based depth with size factor for better separation
    float base_depth = quad_level * 0.6; // Level contributes 0.0-0.6
    float size_depth = clamp(size_factor * 0.1, 0.0, 0.4); // Size contributes 0.0-0.4
    float computed_depth = clamp(base_depth + size_depth, 0.0, 1.0);

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
        uint visible_index;
        InterlockedAdd(visible_count[0], 1, visible_index);

        // Apply depth-based alpha and color modifications for better depth perception
        float depth_alpha_factor = clamp(1.0 - computed_depth * 0.3, 0.3, 1.0);
        float depth_brightness = clamp(1.0 - computed_depth * 0.4, 0.4, 1.0);

        world_quads[quad_id].color = float4(
            paint_color.r * depth_brightness,
            paint_color.g * depth_brightness,
            paint_color.b * depth_brightness,
            alpha_variation * depth_alpha_factor
        );

        visible_quads[visible_index] = world_quads[quad_id];
    }
}