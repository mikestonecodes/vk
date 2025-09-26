struct PushConstants {
    uint  screen_width;
    uint  screen_height;
};
[[vk::push_constant]] PushConstants push_constants;

// 🔑 Use bindless arrays
[[vk::binding(0, 0)]] StructuredBuffer<uint> buffers[];
[[vk::binding(1, 0)]] Texture2D<float4>     textures[];
[[vk::binding(2, 0)]] SamplerState          samplers[];

static const float2 POSITIONS[3] = {
    float2(-1,-1), float2(3,-1), float2(-1,3)
};
static const float2 UVS[3] = {
    float2(0,0), float2(2,0), float2(0,2)
};

struct VertexOutput { float4 clip_position:SV_POSITION; float2 uv:TEXCOORD0; };

VertexOutput vs_main(uint vid:SV_VertexID) {
    VertexOutput o;
    o.clip_position = float4(POSITIONS[vid],0,1);
    o.uv = UVS[vid];
    return o;
}

static const float COLOR_SCALE = 4096.0f;
struct GlobalData {
	float2 camPos;
	float zoom;
};

[[vk::binding(3, 0)]] RWStructuredBuffer<GlobalData> globalData;


static const float3 LUMA = float3(0.299f, 0.587f, 0.114f);
static const int    KERNEL_RADIUS = 5;
static const int    SECTOR_COUNT  = 8;
static const int    ANGLE_SAMPLES = 3;
static const float  TWO_PI        = 6.28318530718f;

float3 ACESFilm(float3 x) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

float3 adjust_saturation(float3 rgb, float adjustment) {
    float intensity = dot(rgb, float3(0.2125f, 0.7154f, 0.0721f));
    return lerp(float3(intensity, intensity, intensity), rgb, adjustment);
}

float quantize_luminance(float luminance, float levels) {
    float q = floor(luminance * (levels - 1.0f) + 0.5f) / (levels - 1.0f);
    return clamp(q, 0.18f, 0.74f);
}

float3 painterly_shade(float3 color, float q) {
    if (q < 0.5f) {
        return lerp(float3(0.12f, 0.12f, 0.12f), color, q * 2.0f);
    }
    return lerp(color, float3(1.0f, 1.0f, 1.0f), (q - 0.5f) * 2.0f);
}

float3 apply_paper_texture(float3 color, float3 paper, float strength) {
    float3 paper_mix = lerp(float3(1.0f, 1.0f, 1.0f), paper, strength);
    return color * paper_mix;
}

float gaussian_weight(float distance, float sigma) {
    return exp(-(distance * distance) / (2.0f * sigma * sigma));
}

float4 sample_accum(int2 coord, uint w, uint h) {
    int max_x = int(w) - 1;
    int max_y = int(h) - 1;
    coord.x = clamp(coord.x, 0, max_x);
    coord.y = clamp(coord.y, 0, max_y);

    uint index = uint(coord.y * int(w) + coord.x) * 4u;
    float3 col = float3(buffers[0][index+0],
                        buffers[0][index+1],
                        buffers[0][index+2]) / COLOR_SCALE;
    float density = (float)buffers[0][index+3] / COLOR_SCALE;
    return float4(col, density);
}

struct SectorStats {
    float3 avgColor;
    float  variance;
    float  avgDensity;
};

void compute_sector_stats(int2 center, uint w, uint h, float base_angle, out SectorStats stats) {
    float3 weighted_color_sum = float3(0.0f, 0.0f, 0.0f);
    float3 weighted_color_sq_sum = float3(0.0f, 0.0f, 0.0f);
    float  weighted_density_sum = 0.0f;
    float  total_weight = 0.0f;

    float sigma = float(KERNEL_RADIUS) * 0.66f;
    float sector_width = TWO_PI / float(SECTOR_COUNT);
    float step = sector_width / float(ANGLE_SAMPLES * 2 + 1);

    // Always include the center sample so fine detail isn't lost
    float4 center_sample = sample_accum(center, w, h);
    weighted_color_sum    += center_sample.rgb;
    weighted_color_sq_sum += center_sample.rgb * center_sample.rgb;
    weighted_density_sum  += center_sample.a;
    total_weight          += 1.0f;

    for (int r = 1; r <= KERNEL_RADIUS; ++r) {
        float radius = float(r);
        for (int s = -ANGLE_SAMPLES; s <= ANGLE_SAMPLES; ++s) {
            float angle = base_angle + float(s) * step;
            float2 offset = radius * float2(cos(angle), sin(angle));
            int2 sample_coord = center + int2(round(offset));

            float distance = length(offset);
            float angular_weight = 1.0f - abs(float(s)) / float(ANGLE_SAMPLES + 1);
            float weight = gaussian_weight(distance, sigma) * angular_weight;
            if (weight <= 0.0f) continue;

            float4 sample = sample_accum(sample_coord, w, h);
            float3 col = sample.rgb;

            weighted_color_sum    += col * weight;
            weighted_color_sq_sum += (col * col) * weight;
            weighted_density_sum  += sample.a * weight;
            total_weight          += weight;
        }
    }

    float inv_weight = total_weight > 1e-5f ? 1.0f / total_weight : 0.0f;
    float3 avg = weighted_color_sum * inv_weight;
    float3 variance_rgb = weighted_color_sq_sum * inv_weight - avg * avg;
    variance_rgb = max(variance_rgb, float3(0.0f, 0.0f, 0.0f));

    stats.avgColor = avg;
    stats.variance = dot(variance_rgb, LUMA);
    stats.avgDensity = weighted_density_sum * inv_weight;
}

float4 kuwahara_filter(int2 coord, uint w, uint h) {
    SectorStats sectors[SECTOR_COUNT];
    [unroll]
    for (int i = 0; i < SECTOR_COUNT; ++i) {
        float base_angle = (float(i) / float(SECTOR_COUNT)) * TWO_PI;
        compute_sector_stats(coord, w, h, base_angle, sectors[i]);
    }

    SectorStats best = sectors[0];
    [unroll]
    for (int i = 1; i < SECTOR_COUNT; ++i) {
        bool better_variance = sectors[i].variance < best.variance - 1e-6f;
        bool similar_variance = abs(sectors[i].variance - best.variance) <= 1e-6f;
        bool better_density = sectors[i].avgDensity > best.avgDensity;
        if (better_variance || (similar_variance && better_density)) {
            best = sectors[i];
        }
    }

    return float4(best.avgColor, best.avgDensity);
}



float4 fs_main(VertexOutput input) : SV_Target {
    uint w = push_constants.screen_width;
    uint h = push_constants.screen_height;

    float2 uv = saturate(input.uv * 0.5f);
    uint2 p = uint2(uv * float2(w,h));
    p = min(p, uint2(w-1,h-1));

    int2 pixel = int2(p);
    float4 center_sample = sample_accum(pixel, w, h);
    float4 filtered = kuwahara_filter(pixel, w, h);

    float accumDensity = max(center_sample.a, filtered.a);
    if (accumDensity < 1e-6f) return float4(0,0,0,1);

    float kuwahara_weight = 0.9f;
    float3 baseColor = lerp(center_sample.rgb, filtered.rgb, kuwahara_weight);

    // Start from a slightly boosted base to keep particle highlights visible
    float3 color = saturate(baseColor * 1.35f);

    // Luminance driven quantization for painterly banding
    float luminance = dot(color, LUMA);
    float q = quantize_luminance(luminance, 10.0f);
    color = painterly_shade(color, q);

    // Subtle watercolor texture to add paper grain to the strokes
    float2 paper_uv = frac(input.uv * 0.5f);
    float3 paper = textures[0].Sample(samplers[0], paper_uv).rgb;
    color = apply_paper_texture(color, paper, 0.45f);

    // Density driven contrast tweak keeps faint regions readable
    float density_factor = saturate(accumDensity * 1.7f);
    color = lerp(float3(0.04f, 0.04f, 0.04f), color, density_factor);

    // Enhanced saturation followed by ACES tone mapping for filmic response
    color = adjust_saturation(color, 1.6f);
    color = ACESFilm(color);

    return float4(color, accumDensity);
}
