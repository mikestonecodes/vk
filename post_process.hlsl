struct PushConstants {
    float time;
    float intensity;
};

[[vk::push_constant]] PushConstants push_constants;

Texture2D input_texture : register(t0);
SamplerState texture_sampler : register(s1);

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

float4 fs_main(VertexOutput input_data) : SV_Target {
    uint2 texture_size;
    input_texture.GetDimensions(texture_size.x, texture_size.y);
    float2 resolution = float2(texture_size);
    float2 uv = input_data.uv;

    // Sample the original color
    float3 color = input_texture.Sample(texture_sampler, uv).rgb;

    // Apply bloom effect
    float bloom_radius = 3.0;
    float3 bloom_color = float3(0.0, 0.0, 0.0);
    float bloom_samples = 9.0;

    for (float x = -1.0; x <= 1.0; x += 1.0) {
        for (float y = -1.0; y <= 1.0; y += 1.0) {
            float2 offset = float2(x, y) * bloom_radius / resolution;
            float3 sample_color = input_texture.Sample(texture_sampler, uv + offset).rgb;
            bloom_color += sample_color;
        }
    }
    bloom_color /= bloom_samples;

    // Apply color grading and tone mapping
    float3 bloomed = lerp(color, bloom_color, 0.3);

    // Simple tone mapping (Reinhard)
    float3 tone_mapped = bloomed / (bloomed + float3(1.0, 1.0, 1.0));

    // Apply gamma correction
    float3 gamma_corrected = pow(tone_mapped, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    // Add slight vignetting
    float2 center = float2(0.5, 0.5);
    float vignette_dist = distance(uv, center);
    float vignette = 1.0 - smoothstep(0.4, 0.8, vignette_dist);

    // Apply chromatic aberration
    float aberration_strength = 0.002 * push_constants.intensity;
    float r = input_texture.Sample(texture_sampler, uv + float2(aberration_strength, 0.0)).r;
    float g = gamma_corrected.g;
    float b = input_texture.Sample(texture_sampler, uv - float2(aberration_strength, 0.0)).b;

    float3 final_color = float3(r, g, b) * vignette;

    return float4(final_color, 1.0);
}