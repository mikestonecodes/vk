@group(0) @binding(1) var texture_sampler: sampler;
@group(0) @binding(2) var texture_image: texture_2d<f32>;

@fragment
fn fs_main(@location(0) color: vec3<f32>, @location(1) tex_coord: vec2<f32>) -> @location(0) vec4<f32> {
    let tex_color = textureSample(texture_image, texture_sampler, tex_coord);
    // Blend texture color with particle color
    let final_color = tex_color.rgb * color;
    return vec4<f32>(final_color, tex_color.a);
}
