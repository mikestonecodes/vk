struct PushConstants {
    float time;
    float exposure;
    float gamma;
    float contrast;
    uint  screen_width;
    uint  screen_height;
    float vignette_strength;
    float _pad0;
    uint  _pad1;
    uint  _pad2;
};
[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(0, 0)]] StructuredBuffer<uint> accum_buffer;

struct VertexOutput { float4 clip_position:SV_POSITION; float2 uv:TEXCOORD0; };

static const float2 POSITIONS[3] = {
    float2(-1,-1), float2(3,-1), float2(-1,3)
};
static const float2 UVS[3] = {
    float2(0,0), float2(2,0), float2(0,2)
};

VertexOutput vs_main(uint vid:SV_VertexID) {
    VertexOutput o;
    o.clip_position = float4(POSITIONS[vid],0,1);
    o.uv = UVS[vid];
    return o;
}

static const float COLOR_SCALE = 4096.0f;

float4 fs_main(VertexOutput input) : SV_Target {
    uint w = push_constants.screen_width;
    uint h = push_constants.screen_height;

    float2 uv = saturate(input.uv * 0.5f); // 0..2 → 0..1
    uint2 p = uint2(uv * float2(w,h));
    p = min(p, uint2(w-1,h-1));

    uint base = (p.y * w + p.x) * 4u;
    uint4 enc = uint4(accum_buffer[base+0], accum_buffer[base+1], accum_buffer[base+2], accum_buffer[base+3]);

    float3 color = float3(enc.xyz) / COLOR_SCALE;

    if (dot(color,color) < 1e-6f)
        return float4(1,0,1,1); // magenta debug background

    return float4(color,1);
}
