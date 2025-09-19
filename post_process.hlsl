struct PushConstants {
    float time;
    float exposure;
    float gamma;
    float contrast;
    uint texture_width;
    uint texture_height;
    float vignette_strength;
    float _pad0;
};

[[vk::push_constant]] PushConstants push_constants;

StructuredBuffer<uint> accum_buffer : register(t0);

struct VertexOutput {
    float4 clip_position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

static const float2 POSITIONS[3] = {
    float2(-1.0f, -1.0f),
    float2( 3.0f, -1.0f),
    float2(-1.0f,  3.0f)
};

static const float2 UVS[3] = {
    float2(0.0f, 1.0f),
    float2(2.0f, 1.0f),
    float2(0.0f, -1.0f)
};

VertexOutput vs_main(uint vertex_index : SV_VertexID) {
    VertexOutput output;
    output.clip_position = float4(POSITIONS[vertex_index], 0.0f, 1.0f);
    output.uv = UVS[vertex_index];
    return output;
}

static const float COLOR_SCALE = 4096.0f;
static const float WEIGHT_SCALE = 1024.0f;

float3 decode_pixel(uint2 coord, uint2 dims, out float weight) {
    coord = min(coord, dims - 1);
    uint index = (coord.y * dims.x + coord.x) * 4u;
    uint4 encoded = uint4(
        accum_buffer[index + 0],
        accum_buffer[index + 1],
        accum_buffer[index + 2],
        accum_buffer[index + 3]
    );
    weight = (float)encoded.w / WEIGHT_SCALE;
    if (weight <= 0.0001f) {
        weight = 0.0f;
        return float3(0.0f, 0.0f, 0.0f);
    }
    float3 accum = float3(encoded.xyz) / COLOR_SCALE;
    return accum / weight;
}

float4 fs_main(VertexOutput input_data) : SV_Target {
    uint width = push_constants.texture_width;
    uint height = push_constants.texture_height;
    if (width == 0 || height == 0) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float2 dims_f = float2((float)width, (float)height);
    float2 uv = saturate(input_data.uv);
    float2 pixel = uv * (dims_f - 1.0f);
    uint2 base = (uint2)pixel;
    float2 frac_coord = frac(pixel);

    float3 accum_color = 0.0f.xxx;
    float accum_weight = 0.0f;

    [unroll]
    for (uint oy = 0; oy <= 1; ++oy) {
        for (uint ox = 0; ox <= 1; ++ox) {
            uint2 coord = base + uint2(ox, oy);
            float sample_weight;
            float3 sample = decode_pixel(coord, uint2(width, height), sample_weight);
            float wx = (ox == 0) ? (1.0f - frac_coord.x) : frac_coord.x;
            float wy = (oy == 0) ? (1.0f - frac_coord.y) : frac_coord.y;
            float w = wx * wy;
            accum_color += sample * sample_weight * w;
            accum_weight += sample_weight * w;
        }
    }

    float3 color = (accum_weight > 0.0f) ? (accum_color / accum_weight) : float3(0.0f, 0.0f, 0.0f);

    float exposure = max(push_constants.exposure, 0.1f);
    color = 1.0f - exp(-color * exposure);

    float gamma = max(push_constants.gamma, 0.01f);
    color = pow(color, float3(1.0f / gamma, 1.0f / gamma, 1.0f / gamma));

    float contrast = clamp(push_constants.contrast, 0.0f, 2.0f);
    color = lerp(float3(0.5f, 0.5f, 0.5f), color, contrast);

    float vignette_strength = saturate(push_constants.vignette_strength);
    float2 centered = uv - 0.5f.xx;
    float vignette = 1.0f - vignette_strength * smoothstep(0.4f, 0.9f, dot(centered, centered));
    color *= vignette;

    return float4(saturate(color), 1.0f);
}
