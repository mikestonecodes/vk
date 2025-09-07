struct Particle {
    position: vec2<f32>,
    color: vec3<f32>,
    _padding: f32,  // Align to 16 bytes
}

@group(0) @binding(0) var<storage, read> particles: array<Particle>;

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

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance_index: u32) -> VertexOutput {
    var out: VertexOutput;

    // Get the base quad vertex
    let vertex_pos = positions[vertex_index];

    // Get particle data from compute shader buffer
    let particle = particles[instance_index];

    // Scale down the particle (make it smaller)
    let particle_size = 0.01;
    let scaled_vertex = vertex_pos * particle_size;

    // Final position = particle center + scaled vertex offset
    let final_pos = particle.position + scaled_vertex;

    out.clip_position = vec4<f32>(final_pos, 0.0, 1.0);
    out.color = particle.color;
    return out;
}
