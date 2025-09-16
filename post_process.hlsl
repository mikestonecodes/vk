struct PushConstants {
    float time;
    float intensity;
    uint texture_width;
    uint texture_height;
};

[[vk::push_constant]] PushConstants push_constants;

StructuredBuffer<uint> accum_buffer : register(t0);

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

static const float COLOR_SCALE = 4096.0;
static const float WEIGHT_SCALE = 2048.0;

float3 decode_color(int2 coord, int2 size, out float weight) {
    coord = clamp(coord, int2(0, 0), size - 1);
    uint base_index = (uint(coord.y) * push_constants.texture_width + uint(coord.x)) * 4u;
    uint4 raw = uint4(
        accum_buffer[base_index + 0],
        accum_buffer[base_index + 1],
        accum_buffer[base_index + 2],
        accum_buffer[base_index + 3]
    );
    weight = (float)raw.w / WEIGHT_SCALE;
    float3 accum = float3(raw.xyz) / COLOR_SCALE;
    if (weight <= 0.0001) {
        weight = 0.0;
        return float3(0.0, 0.0, 0.0);
    }
    return accum / weight;
}

float4 fs_main(VertexOutput input_data) : SV_Target {
    int2 texture_size = int2(int(push_constants.texture_width), int(push_constants.texture_height));
    float2 dims = max(float2(texture_size), float2(1.0, 1.0));
    float2 uv = saturate(input_data.uv);

    float2 pixel = uv * max(dims - 1.0, float2(1.0, 1.0));
    int2 base_coord = int2(pixel);
    float2 frac_coord = frac(pixel);

    float3 accum_color = float3(0.0, 0.0, 0.0);
    float accum_weight = 0.0;

    // Manual bilinear filter for integer texture
    for (int oy = 0; oy <= 1; ++oy) {
        for (int ox = 0; ox <= 1; ++ox) {
            int2 coord = base_coord + int2(ox, oy);
            float sample_weight;
            float3 sample_color = decode_color(coord, texture_size, sample_weight);
            float wx = (ox == 0) ? (1.0 - frac_coord.x) : frac_coord.x;
            float wy = (oy == 0) ? (1.0 - frac_coord.y) : frac_coord.y;
            float w = wx * wy;
            float weighted = sample_weight * w;
            accum_color += sample_color * weighted;
            accum_weight += weighted;
        }
    }

    float3 base_color = (accum_weight > 0.0) ? accum_color / accum_weight : float3(0.0, 0.0, 0.0);

    // Capture central weight for fog modulation
    float center_weight;
    float3 center_color = decode_color(base_coord, texture_size, center_weight);
    float density = saturate(center_weight * 0.12);

    // Soft bloom by sampling a wider neighborhood
    float3 bloom_color = float3(0.0, 0.0, 0.0);
    float bloom_weight = 0.0;
    const int bloom_radius = 2;
    for (int y = -bloom_radius; y <= bloom_radius; ++y) {
        for (int x = -bloom_radius; x <= bloom_radius; ++x) {
            int2 coord = base_coord + int2(x, y);
            float sample_weight;
            float3 sample_color = decode_color(coord, texture_size, sample_weight);
            float falloff = exp(-float(x * x + y * y) * 0.35);
            bloom_color += sample_color * falloff;
            bloom_weight += falloff;
        }
    }
    bloom_color /= max(bloom_weight, 0.001);

    float3 combined = lerp(base_color, bloom_color, 0.4);
    combined = lerp(combined, center_color, 0.2);

    // Fog-style blend pulls color toward a cool mist as density increases
    float fog_factor = saturate(1.0 - exp(-density * 2.2));
    float3 fog_tint = float3(0.08, 0.12, 0.18);
    combined = lerp(combined, fog_tint, fog_factor * 0.5);

    // Tone mapping and gamma correction for final image
    float3 tone_mapped = combined / (combined + float3(1.0, 1.0, 1.0));
    float3 gamma_corrected = pow(tone_mapped, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    // Vignette for subtle framing
    float vignette = 1.0 - smoothstep(0.45, 0.85, length(uv - float2(0.5, 0.5)));

    // Slight animated pulse to keep things lively
    float pulse = 0.05 * sin(push_constants.time * 0.8);
    float exposure = 1.0 + pulse + push_constants.intensity * 0.1;

    float3 final_color = saturate(gamma_corrected * exposure) * vignette;

    return float4(final_color, 1.0);
}
