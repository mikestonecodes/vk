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

    uint2 p = uint2(input.clip_position.xy);
    p = min(p, uint2(w-1,h-1));

    // Simple circular dropoff from center
    float2 center = float2(w * 0.5, h * 0.5);
    float2 pos = float2(p);
    float dist = length(pos - center);
    float maxDist = length(float2(w, h)) * 0.5;

    float circleAlpha = 1.0 - saturate(dist / maxDist);
    circleAlpha = circleAlpha * circleAlpha; // Smooth falloff

    uint base = (p.y * w + p.x) * 4u;
    float3 accumCol = float3(buffers[0][base+0],
                             buffers[0][base+1],
                             buffers[0][base+2]) / COLOR_SCALE;
    float accumDensity = (float)buffers[0][base+3] / COLOR_SCALE;

    float3 col = accumCol * circleAlpha;
    float density = accumDensity * circleAlpha;

    if (density < 1e-6f) return float4(0,0,0,1);

    col = saturate(col * 2.0);
    col = pow(col, 0.8);

    return float4(col, density);
}
