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
[[vk::binding(1, 0)]] Texture2D<float4> sprite_texture;
[[vk::binding(2, 0)]] SamplerState sprite_sampler;


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

float4 fs_main(VertexOutput input) : SV_Target {
    uint w = push_constants.screen_width;
    uint h = push_constants.screen_height;

    // Map UV to pixel coords
    float2 uv = saturate(input.uv * 0.5f);
    uint2 p = uint2(uv * float2(w,h));
    p = min(p, uint2(w-1,h-1));

    // Sprite footprint radius in pixels (R=16 → 32×32 sprite kernel)
    const int R = 16;

    float3 col    = 0.0;
    float density = 0.0;
    float weightSum = 0.0;

    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int2 q = int2(p) + int2(dx, dy);
            if (q.x < 0 || q.x >= int(w) || q.y < 0 || q.y >= int(h)) {
                continue;
            }

            // Compute sprite UV in [0,1]
            float2 spriteUV = (float2(dx,dy) / float(R*2) + 0.5);

            // Sample sprite texture
            float4 spriteSample = sprite_texture.Sample(sprite_sampler, spriteUV);

            if (spriteSample.a < 1e-6f) {
                continue; // outside sprite footprint
            }

            // Accum buffer fetch
            uint base = (q.y * w + q.x) * 4u;
            float3 accumCol = float3(accum_buffer[base+0],
                                     accum_buffer[base+1],
                                     accum_buffer[base+2]) / COLOR_SCALE;
            float accumDensity = (float)accum_buffer[base+3] / COLOR_SCALE;

            // Weight by sprite
            col     += accumCol    * spriteSample.rgb;
            density += accumDensity * spriteSample.a;
            weightSum += spriteSample.a;
        }
    }

    if (weightSum > 0.0) {
        col     /= weightSum;
        density /= weightSum;
    }

    if (density < 1e-6f) {
        return float4(0,0,0,1);
    }

    float3 finalCol   = col;
    float  finalAlpha = density;

    return float4(finalCol, finalAlpha);
}

