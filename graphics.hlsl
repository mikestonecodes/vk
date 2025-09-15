struct PushConstants {
    int screen_width;
    int screen_height;
};

[[vk::push_constant]] PushConstants push_constants;

struct Quad {
    float2 position;
    float2 size;
    float4 color;
    float rotation;
    float depth;
    float2 _padding; // Align to 16-byte boundary
};

StructuredBuffer<Quad> visible_quads : register(t0);

// Quad vertices (two triangles forming a square)
static float2 positions[6] = {
    float2(-0.5, -0.5),  // Bottom left
    float2(0.5, -0.5),   // Bottom right
    float2(-0.5, 0.5),   // Top left
    float2(0.5, -0.5),   // Bottom right
    float2(0.5, 0.5),    // Top right
    float2(-0.5, 0.5)    // Top left
};

// Texture coordinates for the quad
static float2 tex_coords[6] = {
    float2(0.0, 1.0),  // Bottom left
    float2(1.0, 1.0),  // Bottom right
    float2(0.0, 0.0),  // Top left
    float2(1.0, 1.0),  // Bottom right
    float2(1.0, 0.0),  // Top right
    float2(0.0, 0.0)   // Top left
};

struct VertexOutput {
    float4 clip_position : SV_POSITION;
    float4 color : COLOR0;
    float2 tex_coord : TEXCOORD0;
    float2 world_pos : TEXCOORD1;
};

VertexOutput vs_main(uint vertex_index : SV_VertexID, uint instance_index : SV_InstanceID) {
    VertexOutput output;

    // Get quad data from visible buffer - all quads here are guaranteed to be visible
    Quad quad = visible_quads[instance_index];

    // Get the base quad vertex (-0.5 to 0.5)
    float2 vertex_pos = positions[vertex_index];

    // Scale the vertex by the quad's size
    float2 scaled_vertex = vertex_pos * quad.size;

    // Apply rotation around the quad center
    float cos_rot = cos(quad.rotation);
    float sin_rot = sin(quad.rotation);
    float2 rotated_vertex = float2(
        scaled_vertex.x * cos_rot - scaled_vertex.y * sin_rot,
        scaled_vertex.x * sin_rot + scaled_vertex.y * cos_rot
    );

    // Final position = quad center + rotated scaled vertex offset
    float2 final_pos = quad.position + rotated_vertex;

    // Apply aspect ratio correction to keep quads square
    float aspect_ratio = (float)push_constants.screen_width / (float)push_constants.screen_height;
    float2 corrected_pos = float2(final_pos.x / aspect_ratio, final_pos.y);

    // Use computed depth for proper Z-buffering and overdraw elimination
    float normalized_depth = clamp(quad.depth, 0.0, 1.0);
    output.clip_position = float4(corrected_pos.x, corrected_pos.y, normalized_depth, 1.0);
    output.color = quad.color;
    output.tex_coord = tex_coords[vertex_index];
    output.world_pos = quad.position;
    return output;
}

SamplerState texture_sampler : register(s1);
Texture2D texture_image : register(t2);

struct OitOutput {
    float4 accum : SV_Target0;
    float revealage : SV_Target1;
};

OitOutput fs_main(VertexOutput input) {
    OitOutput output;

    float4 tex_color = texture_image.Sample(texture_sampler, input.tex_coord);

    // Enhanced depth perception through multiple visual cues
    float depth_from_z = input.clip_position.z;

    // Distance from center creates natural depth falloff
    float center_distance = length(input.tex_coord - float2(0.5, 0.5)) * 2.0;
    float world_distance = length(input.world_pos) * 0.1;

    // Multiple depth factors for stronger perception
    float depth_darkness = 1.0 - clamp(depth_from_z * 1.5 + world_distance, 0.0, 0.6);
    float edge_fade = 1.0 - clamp(center_distance * 0.3, 0.0, 0.2);
    float combined_depth_factor = depth_darkness * edge_fade;

    float3 shaded_color = tex_color.rgb * input.color.rgb * combined_depth_factor;
    float alpha = saturate(tex_color.a * input.color.a * combined_depth_factor);

    float depth_weight = saturate(1.0 - depth_from_z);
    float weight = max(depth_weight * 0.8 + 0.2, 0.01);

    output.accum = float4(shaded_color * alpha * weight, alpha * weight);
    output.revealage = alpha;
    return output;
}
