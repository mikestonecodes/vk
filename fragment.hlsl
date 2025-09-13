// Basic fragment shader for textured quads
Texture2D texture0 : register(t0);
SamplerState sampler0 : register(s0);

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

float4 main(VertexOutput input) : SV_TARGET {
    return texture0.Sample(sampler0, input.texCoord);
}