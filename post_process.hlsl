struct PushConstants {
    float time;
    float intensity;
};

[[vk::push_constant]] PushConstants push_constants;

Texture2D accum_texture : register(t0);
Texture2D reveal_texture : register(t1);
SamplerState texture_sampler : register(s2);

struct VertexOutput {
    float4 clip_position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

// Fullscreen triangle vertices
static float2 positions[3] = {
    float2(-1.0, -1.0),
    float2(3.0, -1.0),
    float2(-1.0, 3.0)
};

static float2 uvs[3] = {
    float2(0.0, 1.0),
    float2(2.0, 1.0),
    float2(0.0, -1.0)
};

VertexOutput vs_main(uint vertex_index : SV_VertexID) {
    VertexOutput output;
    output.clip_position = float4(positions[vertex_index], 0.0, 1.0);
    output.uv = uvs[vertex_index];
    return output;
}

float4 sample_composited(float2 uv) {
    float4 accum = accum_texture.Sample(texture_sampler, uv);
    float reveal = reveal_texture.Sample(texture_sampler, uv).r;
    float weight = max(accum.a, 1e-4);
    float3 resolved = accum.rgb / weight;
    float alpha = saturate(1.0 - reveal);
    return float4(resolved * alpha, alpha);
}

float3 apply_tone_map(float3 color) {
    float3 tone_mapped = color / (color + float3(1.0, 1.0, 1.0));
    return pow(tone_mapped, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
}

float4 fs_main(VertexOutput input_data) : SV_Target {
    uint2 texture_size;
    accum_texture.GetDimensions(texture_size.x, texture_size.y);
    float2 resolution = float2(texture_size);
    float2 uv = input_data.uv;

    // Sample the resolved weighted-blended color
    float4 base_sample = sample_composited(uv);
    float3 color = base_sample.rgb;

    // Apply bloom effect
    float bloom_radius = 3.0;
    float3 bloom_color = float3(0.0, 0.0, 0.0);
    float bloom_samples = 9.0;

    for (float x = -1.0; x <= 1.0; x += 1.0) {
        for (float y = -1.0; y <= 1.0; y += 1.0) {
            float2 offset = float2(x, y) * bloom_radius / resolution;
            float4 bloom_sample = sample_composited(uv + offset);
            bloom_color += bloom_sample.rgb;
        }
    }
    bloom_color /= bloom_samples;

    // Apply color grading and tone mapping
    float3 bloomed = lerp(color, bloom_color, 0.3);

    float3 gamma_corrected = apply_tone_map(bloomed);

    // Add slight vignetting
    float2 center = float2(0.5, 0.5);
    float vignette_dist = distance(uv, center);
    float vignette = 1.0 - smoothstep(0.4, 0.8, vignette_dist);

    // Apply chromatic aberration
    float aberration_strength = 0.002 * push_constants.intensity;
    float3 aberration_r_sample = apply_tone_map(sample_composited(uv + float2(aberration_strength, 0.0)).rgb);
    float3 aberration_b_sample = apply_tone_map(sample_composited(uv - float2(aberration_strength, 0.0)).rgb);
    float r = aberration_r_sample.r;
    float g = gamma_corrected.g;
    float b = aberration_b_sample.b;

    float3 final_color = float3(r, g, b) * vignette;

    return float4(final_color, 1.0);
}