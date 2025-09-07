struct PushConstants {
    time: f32,
    particle_count: u32,
}

var<push_constant> push_constants: PushConstants;

struct Particle {
    position: vec2<f32>,
    color: vec3<f32>,
    _padding: f32,  // Align to 16 bytes
}

@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;

// Simple hash function for pseudo-random numbers
fn hash(n: f32) -> f32 {
    return fract(sin(n) * 43758.5453123);
}

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let instance_id = global_id.x;
    
    if (instance_id >= push_constants.particle_count) {
        return;
    }
    
    let id = f32(instance_id);
    
    // Create some randomness based on instance ID
    let hash_x = hash(id * 12.9898);
    let hash_y = hash(id * 78.233);
    let hash_speed = hash(id * 37.719);
    
    // Particle moves in a circle with some randomness
    let speed = 0.3 + hash_speed * 0.5;
    let angle = push_constants.time * speed + hash_x * 6.28318; // 2*PI
    let radius = 0.3 + hash_y * 0.4;
    
    // Explicitly center the circle at screen center
    let circle_center = vec2<f32>(0.0, 0.0);  // Screen center in NDC
    let position = circle_center + vec2<f32>(
        cos(angle) * radius,
        sin(angle) * radius
    );
    
    let color = vec3<f32>(
        0.5 + 0.5 * sin(push_constants.time + id * 2.1),
        0.5 + 0.5 * sin(push_constants.time + id * 1.7 + 1.0),
        0.5 + 0.5 * sin(push_constants.time + id * 1.3 + 2.0)
    );
    
    particles[instance_id].position = position;
    particles[instance_id].color = color;
}