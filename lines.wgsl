struct PushConstants {
    screen_width: i32,
    screen_height: i32,
}

var<push_constant> push_constants: PushConstants;

struct Line {
    start_pos: vec2<f32>,
    end_pos: vec2<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<storage, read> lines: array<Line>;

// Line vertices (two endpoints per line)
var<private> positions: array<vec2<f32>, 2> = array<vec2<f32>, 2>(
    vec2<f32>(0.0, 0.0),  // Start point
    vec2<f32>(1.0, 1.0),  // End point
);

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance_index: u32) -> VertexOutput {
    var out: VertexOutput;

    // Get line data from compute shader buffer
    let line = lines[instance_index];
    
    // Skip rendering transparent lines
    if line.color.a <= 0.01 {
        out.clip_position = vec4<f32>(0.0, 0.0, -1.0, 1.0); // Place offscreen
        out.color = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        return out;
    }

    // Select start or end position based on vertex index
    let world_pos = select(line.start_pos, line.end_pos, vertex_index == 1u);

    // Apply aspect ratio correction
    let aspect_ratio = f32(push_constants.screen_width) / f32(push_constants.screen_height);
    let corrected_pos = vec2<f32>(world_pos.x / aspect_ratio, world_pos.y);
    
    out.clip_position = vec4<f32>(corrected_pos.x, corrected_pos.y, 0.0, 1.0);
    out.color = line.color;
    return out;
}

@fragment
fn fs_main(@location(0) color: vec4<f32>) -> @location(0) vec4<f32> {
    return color;
}