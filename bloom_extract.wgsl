// Bloom extraction shader - extract bright regions

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
    let color = textureSample(input_texture, input_sampler, in.uv);
    
    // Extract bright regions above threshold
    let brightness_threshold = 0.6;
    let brightness = dot(color.rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    
    if (brightness > brightness_threshold) {
        // Enhance bright regions
        let bloom_color = color.rgb * push.intensity * 2.0;
        return vec4<f32>(bloom_color, color.a);
    } else {
        // Darken non-bright regions
        return vec4<f32>(color.rgb * 0.1, color.a);
    }
}