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



float4 fs_main(VertexOutput input) : SV_Target {
    uint w = push_constants.screen_width;
    uint h = push_constants.screen_height;

    float2 uv = saturate(input.uv * 0.5f);
    uint2 p = uint2(uv * float2(w,h));
    p = min(p, uint2(w-1,h-1));

    const int R = 16;
    float3 col    = 0.0;
    float density = 0.0;
    float weightSum = 0.0;

    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int2 q = int2(p) + int2(dx, dy);
            if (q.x < 0 || q.x >= int(w) || q.y < 0 || q.y >= int(h)) continue;

            float2 spriteUV = (float2(dx,dy) / float(R*2) + 0.5);

            float4 spriteSample = textures[0].Sample(samplers[0], spriteUV);
            if (spriteSample.a < 1e-6f) continue;

            uint base = (q.y * w + q.x) * 4u;
            float3 accumCol = float3(buffers[0][base+0],
                                     buffers[0][base+1],
                                     buffers[0][base+2]) / COLOR_SCALE;
            float accumDensity = (float)buffers[0][base+3] / COLOR_SCALE;

            col     += accumCol    * spriteSample.rgb;
            density += accumDensity * spriteSample.a;
            weightSum += spriteSample.a;
        }
    }

    if (weightSum > 0.0) {
        col     /= weightSum;
        density /= weightSum;
    }
    if (density < 1e-6f) return float4(0,0,0,1);

    return float4(col, density);
}
