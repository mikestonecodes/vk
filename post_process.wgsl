struct PushConstants {
    time: f32,
    intensity: f32,
}

var<push_constant> push_constants: PushConstants;

@group(0) @binding(0) var input_texture: texture_2d<f32>;
@group(0) @binding(1) var texture_sampler: sampler;

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

// Fullscreen triangle vertices
var<private> positions: array<vec2<f32>, 3> = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0),
    vec2<f32>(3.0, -1.0),
    vec2<f32>(-1.0, 3.0)
);

var<private> uvs: array<vec2<f32>, 3> = array<vec2<f32>, 3>(
    vec2<f32>(0.0, 1.0),
    vec2<f32>(2.0, 1.0),
    vec2<f32>(0.0, -1.0)
);

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4<f32>(positions[vertex_index], 0.0, 1.0);
    out.uv = uvs[vertex_index];
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let resolution = vec2<f32>(textureDimensions(input_texture));
    let uv = in.uv;
    
    // Sample the original color
    let color = textureSample(input_texture, texture_sampler, uv).rgb;
    
    // Apply bloom effect
    let bloom_radius = 3.0;
    var bloom_color = vec3<f32>(0.0);
    let bloom_samples = 9.0;
    
    for (var x = -1.0; x <= 1.0; x += 1.0) {
        for (var y = -1.0; y <= 1.0; y += 1.0) {
            let offset = vec2<f32>(x, y) * bloom_radius / resolution;
            let sample_color = textureSample(input_texture, texture_sampler, uv + offset).rgb;
            bloom_color += sample_color;
        }
    }
    bloom_color /= bloom_samples;
    
    // Apply color grading and tone mapping
    let bloomed = mix(color, bloom_color, 0.3);
    
    // Simple tone mapping (Reinhard)
    let tone_mapped = bloomed / (bloomed + vec3<f32>(1.0));
    
    // Apply gamma correction
    let gamma_corrected = pow(tone_mapped, vec3<f32>(1.0 / 2.2));
    
    // Add slight vignetting
    let center = vec2<f32>(0.5);
    let vignette_dist = distance(uv, center);
    let vignette = 1.0 - smoothstep(0.4, 0.8, vignette_dist);
    
    // Apply chromatic aberration
    let aberration_strength = 0.002 * push_constants.intensity;
    let r = textureSample(input_texture, texture_sampler, uv + vec2<f32>(aberration_strength, 0.0)).r;
    let g = gamma_corrected.g;
    let b = textureSample(input_texture, texture_sampler, uv - vec2<f32>(aberration_strength, 0.0)).b;
    
    let final_color = vec3<f32>(r, g, b) * vignette;
    
    return vec4<f32>(final_color, 1.0);
}