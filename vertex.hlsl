// Basic vertex shader for textured quads
struct VertexOutput {
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

VertexOutput main(uint vertexId : SV_VertexID) {
    VertexOutput output;

    // Generate a fullscreen quad using vertex ID
    float2 positions[6] = {
        float2(-1.0, -1.0), // Bottom left
        float2( 1.0, -1.0), // Bottom right
        float2(-1.0,  1.0), // Top left
        float2( 1.0, -1.0), // Bottom right
        float2( 1.0,  1.0), // Top right
        float2(-1.0,  1.0)  // Top left
    };

    float2 texCoords[6] = {
        float2(0.0, 1.0), // Bottom left
        float2(1.0, 1.0), // Bottom right
        float2(0.0, 0.0), // Top left
        float2(1.0, 1.0), // Bottom right
        float2(1.0, 0.0), // Top right
        float2(0.0, 0.0)  // Top left
    };

    output.position = float4(positions[vertexId], 0.0, 1.0);
    output.texCoord = texCoords[vertexId];

    return output;
}