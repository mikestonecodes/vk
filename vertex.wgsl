struct PushConstants {
    time: f32,
}

var<push_constant> push_constants: PushConstants;

// Quad vertices (two triangles forming a square)
var<private> positions: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(-0.5, -0.5),  // Bottom left
    vec2<f32>(0.5, -0.5),   // Bottom right
    vec2<f32>(-0.5, 0.5),   // Top left
    vec2<f32>(0.5, -0.5),   // Bottom right
    vec2<f32>(0.5, 0.5),    // Top right
    vec2<f32>(-0.5, 0.5)    // Top left
);

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec3<f32>,
}

// Simple hash function for pseudo-random numbers
fn hash(n: f32) -> f32 {
    return fract(sin(n) * 43758.5453123);
}

// Generate particle properties based on instance ID
fn get_particle_position(instance_id: u32) -> vec2<f32> {
    let id = f32(instance_id);

    // Create some randomness based on instance ID
    let hash_x = hash(id * 12.9898);
    let hash_y = hash(id * 78.233);
    let hash_speed = hash(id * 37.719);

    // Particle moves in a circle with some randomness
    let speed = 0.3 + hash_speed * 0.5;
    let angle = push_constants.time * speed + hash_x * 6.28318; // 2*PI
    let radius = 0.3 + hash_y * 0.4;

    return vec2<f32>(
        cos(angle) * radius,
        sin(angle) * radius
    );
}

fn get_particle_color(instance_id: u32) -> vec3<f32> {
    let id = f32(instance_id);
    return vec3<f32>(
        0.5 + 0.5 * sin(push_constants.time + id * 2.1),
        0.5 + 0.5 * sin(push_constants.time + id * 1.7 + 1.0),
        0.5 + 0.5 * sin(push_constants.time + id * 1.3 + 2.0)
    );
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance_index: u32) -> VertexOutput {
    var out: VertexOutput;

    // Get the base quad vertex
    let vertex_pos = positions[vertex_index];

    // Get particle position and properties
    let particle_pos = get_particle_position(instance_index);
    let particle_color = get_particle_color(instance_index);

    // Scale down the particle (make it smaller)
    let particle_size = 0.01;
    let scaled_vertex = vertex_pos * particle_size;

    // Final position = particle center + scaled vertex offset
    let final_pos = particle_pos + scaled_vertex;

    out.clip_position = vec4<f32>(final_pos, 0.0, 1.0);
    out.color = particle_color;
    return out;
}
