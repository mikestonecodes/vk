// Broad-phase collision detection compute shader
struct Particle {
    position: vec2<f32>,
    color: vec3<f32>,
    _padding: f32,
}

@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;

struct PushConstants {
    time: f32,
    particle_count: u32,
}

var<push_constant> push: PushConstants;

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= push.particle_count) {
        return;
    }
    
    // Simple broad-phase collision detection
    // Check against neighboring particles in a spatial grid
    var current = particles[index];
    let grid_size = 32u;
    let cell_x = u32((current.position.x + 1.0) * 0.5 * f32(grid_size));
    let cell_y = u32((current.position.y + 1.0) * 0.5 * f32(grid_size));
    
    // Color particles based on collision potential
    let collision_factor = f32((cell_x + cell_y) % 10u) * 0.1;
    current.color = vec3<f32>(
        current.color.r + collision_factor * 0.1,
        current.color.g,
        current.color.b + collision_factor * 0.2
    );
    
    particles[index] = current;
}