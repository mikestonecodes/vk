struct PushConstants {
    uint  screen_width;
    uint  screen_height;
};
[[vk::push_constant]] PushConstants push_constants;

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

static const float COLOR_SCALE = 2096.0f;

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

float4 fs_main(VertexOutput input) : SV_Target {
    uint w = push_constants.screen_width;
    uint h = push_constants.screen_height;

    float2 uv = saturate(input.uv * 0.5f);
    uint2 p = uint2(uv * float2(w,h));
    p = min(p, uint2(w-1,h-1));

    int2 pixel = int2(p);
    float4 sample = sample_accum(pixel, w, h);

    return float4(sample.rgb, sample.a);
}

