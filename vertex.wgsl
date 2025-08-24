struct PushConstants {
    time: f32,
}

var<push_constant> push_constants: PushConstants;

var<private> positions: array<vec2<f32>, 3> = array<vec2<f32>, 3>(
    vec2<f32>(0.0, -0.5),
    vec2<f32>(0.5, 0.5),
    vec2<f32>(-0.5, 0.5)
);

var<private> colors: array<vec3<f32>, 3> = array<vec3<f32>, 3>(
    vec3<f32>(1.0, 0.0, 0.0),
    vec3<f32>(0.0, 1.0, 0.0),
    vec3<f32>(0.0, 0.0, 1.0)
);

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec3<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    
    let pos = positions[vertex_index];
    let angle = push_constants.time;
    let cos_a = cos(angle);
    let sin_a = sin(angle);
    
    let rotated_pos = vec2<f32>(
        pos.x * cos_a - pos.y * sin_a,
        pos.x * sin_a + pos.y * cos_a
    );
    
    out.clip_position = vec4<f32>(rotated_pos, 0.0, 1.0);
    out.color = colors[vertex_index];
    return out;
}
