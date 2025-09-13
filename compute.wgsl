struct PushConstants {
    time: f32,
    quad_count: u32,
    delta_time: f32,
    // Level spawning control
    spawn_delay: f32,  // seconds between each level appearing
    max_visible_level: f32,  // current maximum visible level (grows over time)
    // Input state
    mouse_x: f32,
    mouse_y: f32,
    mouse_left: u32,
    mouse_right: u32,
    // Keyboard state (vim keys + common keys)
    key_h: u32,
    key_j: u32,
    key_k: u32,
    key_l: u32,
    key_w: u32,
    key_a: u32,
    key_s: u32,
    key_d: u32,
    key_q: u32,
    key_e: u32,
}

var<push_constant> push_constants: PushConstants;

struct Quad {
    position: vec2<f32>,
    size: vec2<f32>,
    color: vec4<f32>,
    rotation: f32,
    _padding: vec3<f32>, // Align to 16-byte boundary
}

struct CameraState {
    x: f32,
    y: f32,
    zoom: f32,
    _padding: f32,
}

struct Line {
    start_pos: vec2<f32>,
    end_pos: vec2<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<storage, read_write> quads: array<Quad>;
@group(0) @binding(1) var<storage, read_write> camera: CameraState;

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let quad_id = global_id.x;
    if quad_id >= push_constants.quad_count {
        return;
    }

    // Update camera state only for first thread to avoid race conditions
    if quad_id == 0u {
        let move_speed = 2.0;
        let zoom_speed = 0.1;
        let dt = push_constants.delta_time;

        // Update camera based on input (WASD)
        if push_constants.key_a != 0u { camera.x -= move_speed * dt; }
        if push_constants.key_d != 0u { camera.x += move_speed * dt; }
        if push_constants.key_w != 0u { camera.y += move_speed * dt; }
        if push_constants.key_s != 0u { camera.y -= move_speed * dt; }

        // Zoom with q/e - multiplicative zoom for smooth "through" feeling
        if push_constants.key_e != 0u {
            camera.zoom *= 1.0 + zoom_speed * dt * 5.0; // zoom in multiplicatively
        }
        if push_constants.key_q != 0u {
            camera.zoom /= 1.0 + zoom_speed * dt * 5.0; // zoom out multiplicatively
        }
        camera.zoom = max(0.01, camera.zoom);
    }

    // Ensure camera updates are visible to all threads
    workgroupBarrier();
    // Create more organic, irregular quad distribution
    let grid_size = u32(ceil(sqrt(f32(push_constants.quad_count))));
    let quad_x = quad_id % grid_size;
    let quad_y = quad_id / grid_size;

    // Add chaotic movement and irregular sizing
    let chaos_factor = sin(f32(quad_id) * 0.1 + push_constants.time * 0.01) * cos(f32(quad_id) * 0.7 + push_constants.time * 1.5);
    let drift_x = sin(f32(quad_id) * 0.123 + push_constants.time * 0.08) * 0.0;
    let drift_y = cos(f32(quad_id) * 0.456 + push_constants.time * 00.2) * 0.5;

    // Irregular screen coverage with varying sizes
    let screen_width = 20.0;
    let screen_height = 15.0;
    let size_variation = 1.0 + sin(f32(quad_id) * 0.789 + push_constants.time * 0.6) * 0.8;
    let base_size = vec2<f32>(screen_width / f32(grid_size), screen_height / f32(grid_size));
    let quad_size = base_size * size_variation * (2.0 + chaos_factor);

    // Scattered, paint-splatter positioning
    let scatter_x = sin(f32(quad_id) * 2.345 + push_constants.time * 0.001) * screen_width * 0.3;
    let scatter_y = cos(f32(quad_id) * 3.678 + push_constants.time * 0.001) * screen_height * 0.3;

    let start_x = -screen_width * 0.5;
    let start_y = -screen_height * 0.5;
    let base_pos = vec2<f32>(
        start_x + f32(quad_x) * base_size.x * 0.7,
        start_y + f32(quad_y) * base_size.y * 0.7
    );

    let world_pos = base_pos + vec2<f32>(scatter_x + drift_x, scatter_y + drift_y);

    quads[quad_id].position = world_pos + vec2<f32>(camera.x, camera.y);
    quads[quad_id].size = quad_size * camera.zoom;
    quads[quad_id].rotation = sin(f32(quad_id) * 0.234 + push_constants.time * 1.8) * 1.5 + chaos_factor;

    // Trippy paint splatter colors with wild variations
    let color_shift = sin(f32(quad_id) * 0.167 + push_constants.time * 0.5);
    let color_pulse = cos(f32(quad_id) * 0.891 + push_constants.time * 0.2);

    let base_colors = array<vec3<f32>, 2>(
        vec3<f32>(0.2, 0.4, 9.9),  // Deep blue
        vec3<f32>(0.2, 0.4, 9.9),  // Deep blue
    );

    let color_index = u32(abs(color_shift * 2.5)) % 5u;
    let base_color = select(
        base_colors[0],
        base_colors[1],
        color_index == 1u
    );
    let paint_color = base_color + vec3<f32>(color_pulse * 0.3, color_shift * 0.2, chaos_factor * 0.4) ;

    let alpha_variation = 0.3 + abs(sin(f32(quad_id) * 0.678 + push_constants.time * 1.9)) * 0.7;

    quads[quad_id].color = vec4<f32>(
        paint_color.r,
        paint_color.g,
        paint_color.b,
        alpha_variation
    );
}

