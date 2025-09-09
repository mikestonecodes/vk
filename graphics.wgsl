
struct PushConstants {
    screen_width: i32,
    screen_height: i32,
}

var<push_constant> push_constants: PushConstants;

struct Quad {
    position: vec2<f32>,
    size: vec2<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<storage, read> quads: array<Quad>;

// Quad vertices (two triangles forming a square)
var<private> positions: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(-0.5, -0.5),  // Bottom left
    vec2<f32>(0.5, -0.5),   // Bottom right
    vec2<f32>(-0.5, 0.5),   // Top left
    vec2<f32>(0.5, -0.5),   // Bottom right
    vec2<f32>(0.5, 0.5),    // Top right
    vec2<f32>(-0.5, 0.5)    // Top left
);

// Texture coordinates for the quad
var<private> tex_coords: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 1.0),  // Bottom left
    vec2<f32>(1.0, 1.0),  // Bottom right
    vec2<f32>(0.0, 0.0),  // Top left
    vec2<f32>(1.0, 1.0),  // Bottom right
    vec2<f32>(1.0, 0.0),  // Top right
    vec2<f32>(0.0, 0.0)   // Top left
);

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) tex_coord: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance_index: u32) -> VertexOutput {
    var out: VertexOutput;

    // Get the base quad vertex (-0.5 to 0.5)
    let vertex_pos = positions[vertex_index];

    // Get quad data from compute shader buffer
    let quad = quads[instance_index];

    // Scale the vertex by the quad's size
    let scaled_vertex = vertex_pos * quad.size;

    // Final position = quad center + scaled vertex offset
    let final_pos = quad.position + scaled_vertex;

    // No aspect ratio correction for now - just use the position directly
    out.clip_position = vec4<f32>(final_pos.x, final_pos.y, 0.0, 1.0);
    out.color = quad.color;
    out.tex_coord = tex_coords[vertex_index];
    return out;
}


@group(0) @binding(1) var texture_sampler: sampler;
@group(0) @binding(2) var texture_image: texture_2d<f32>;

@fragment
fn fs_main(@location(0) color: vec4<f32>, @location(1) tex_coord: vec2<f32>) -> @location(0) vec4<f32> {
    let tex_color = textureSample(texture_image, texture_sampler, tex_coord);
    // Blend texture color with quad color
    let final_color = tex_color.rgb * color.rgb;
    return vec4<f32>(final_color, tex_color.a * color.a);
}
