// Mega Splat - Colorize Pass: Convert blurred density to final color buffer

struct PushConstants {
    float time;
    float delta_time;
    uint  particle_count;
    uint  _pad0;
    uint  screen_width;
    uint  screen_height;
    float brightness;
    uint  blur_radius;
    float blur_sigma;
    uint  _pad1;
    uint  _pad2;
    uint  _pad3;
};
[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(1, 0)]] Texture2D<float> blur_input;
[[vk::binding(3, 0)]] SamplerState blur_sampler;
[[vk::binding(4, 0)]] RWStructuredBuffer<uint> color_output;

[numthreads(8,8,1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint2 coord = tid.xy;
    if (coord.x >= push_constants.screen_width || coord.y >= push_constants.screen_height) return;

    uint W = push_constants.screen_width;
    uint H = push_constants.screen_height;

    // Sample the final blurred density
    float2 uv = float2(coord) / float2(W, H);
    float density = blur_input.SampleLevel(blur_sampler, uv, 0).r;

    if (density < 1e-6) {
        // No contribution - clear the pixel
        uint idx = (coord.y * W + coord.x) * 4u;
        color_output[idx + 0] = 0;
        color_output[idx + 1] = 0;
        color_output[idx + 2] = 0;
        color_output[idx + 3] = 0;
        return;
    }

    // Generate color based on spatial location (creates color variety across the splat field)
    float3 base_color = float3(
        0.6 + 0.4 * sin(uv.x * 17.0 + push_constants.time * 0.5),
        0.6 + 0.4 * sin(uv.y * 23.0 + push_constants.time * 0.3),
        0.6 + 0.4 * sin((uv.x + uv.y) * 31.0 + push_constants.time * 0.7)
    );

    // Apply density as brightness
    float3 final_color = base_color * density;

    // Convert to integer format (matches original COLOR_SCALE)
    const float COLOR_SCALE = 4096.0;
    uint addR = uint(saturate(final_color.r) * COLOR_SCALE);
    uint addG = uint(saturate(final_color.g) * COLOR_SCALE);
    uint addB = uint(saturate(final_color.b) * COLOR_SCALE);
    uint addA = uint(COLOR_SCALE);

    // Write to output buffer
    uint idx = (coord.y * W + coord.x) * 4u;
    color_output[idx + 0] = addR;
    color_output[idx + 1] = addG;
    color_output[idx + 2] = addB;
    color_output[idx + 3] = addA;
}