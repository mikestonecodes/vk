// Vertical blur shader for bloom effect

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    
    // Full-screen triangle
    let x = f32(i32(vertex_index) - 1);
    let y = f32(i32(vertex_index & 1u) * 2 - 1);
    
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    out.uv = vec2<f32>(x * 0.5 + 0.5, -y * 0.5 + 0.5);
    
    return out;
}

@group(0) @binding(0) var input_texture: texture_2d<f32>;
@group(0) @binding(1) var input_sampler: sampler;

struct PushConstants {
    time: f32,
    intensity: f32,
}

var<push_constant> push: PushConstants;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let texel_size = 1.0 / vec2<f32>(textureDimensions(input_texture));
    let blur_radius = 4.0 * push.intensity;
    
    var color = vec4<f32>(0.0);
    
    // Vertical blur with unrolled loop
    color += textureSample(input_texture, input_sampler, in.uv) * 0.227027;
    
    let offset1 = 1.0 * texel_size.y * blur_radius;
    color += textureSample(input_texture, input_sampler, in.uv + vec2<f32>(0.0, offset1)) * 0.1945946;
    color += textureSample(input_texture, input_sampler, in.uv - vec2<f32>(0.0, offset1)) * 0.1945946;
    
    let offset2 = 2.0 * texel_size.y * blur_radius;
    color += textureSample(input_texture, input_sampler, in.uv + vec2<f32>(0.0, offset2)) * 0.1216216;
    color += textureSample(input_texture, input_sampler, in.uv - vec2<f32>(0.0, offset2)) * 0.1216216;
    
    let offset3 = 3.0 * texel_size.y * blur_radius;
    color += textureSample(input_texture, input_sampler, in.uv + vec2<f32>(0.0, offset3)) * 0.054054;
    color += textureSample(input_texture, input_sampler, in.uv - vec2<f32>(0.0, offset3)) * 0.054054;
    
    let offset4 = 4.0 * texel_size.y * blur_radius;
    color += textureSample(input_texture, input_sampler, in.uv + vec2<f32>(0.0, offset4)) * 0.016216;
    color += textureSample(input_texture, input_sampler, in.uv - vec2<f32>(0.0, offset4)) * 0.016216;
    
    return color;
}