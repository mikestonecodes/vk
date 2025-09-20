// Mega Splat - Blur Vertical Pass

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
[[vk::binding(2, 0)]] RWTexture2D<float> blur_output;
[[vk::binding(3, 0)]] SamplerState blur_sampler;

[numthreads(8,8,1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint2 coord = tid.xy;
    if (coord.x >= push_constants.screen_width || coord.y >= push_constants.screen_height) return;

    int radius = int(push_constants.blur_radius);
    float sigma = push_constants.blur_sigma;
    float sigma2 = sigma * sigma;

    float sum = 0.0;
    float weight_sum = 0.0;

    // Gaussian kernel sampling
    for (int dy = -radius; dy <= radius; ++dy) {
        int2 sample_coord = int2(coord) + int2(0, dy);

        // Clamp sampling coordinates
        sample_coord.y = clamp(sample_coord.y, 0, int(push_constants.screen_height) - 1);

        float2 uv = float2(sample_coord) / float2(push_constants.screen_width, push_constants.screen_height);

        // Gaussian weight
        float weight = exp(-0.5 * (dy * dy) / sigma2);

        float sample_value = blur_input.SampleLevel(blur_sampler, uv, 0).r;
        sum += sample_value * weight;
        weight_sum += weight;
    }

    blur_output[coord] = sum / max(weight_sum, 1e-6);
}