// Detailed fluid-based smoke inspired by GPU Pro 2 "Simple and Fast Fluids"

static const float COLOR_SCALE = 4096.0f;
static const int   PASSES = 4;

struct PushConstants {
    float time;
    float delta_time;
    uint  particle_count;
    uint  _pad0;
    uint  screen_width;
    uint  screen_height;
    float brightness;
    float mouse_x;
    float mouse_y;
    uint  mouse_left;
    uint  mouse_right;
    uint  _pad1;
};
[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(0, 0)]] RWStructuredBuffer<uint> buffers[];

struct GlobalData {
    float2 prevMouseUv;
    float  prevMouseDown;
    float  frameCount;
    uint   ping;
    float  pad0;
    float  pad1;
    float  pad2;
};
[[vk::binding(3, 0)]] RWStructuredBuffer<GlobalData> globalData;

float hash11(uint n) {
    n ^= n * 0x27d4eb2d;
    n ^= n >> 15;
    n *= 0x85ebca6b;
    n ^= n >> 13;
    return (n & 0x00FFFFFFu) / 16777215.0f;
}

float2 fade2(float2 t) {
    return t * t * (3.0f - 2.0f * t);
}

uint hash2d(int2 p, uint seed) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u + seed * 362437u;
    h ^= h >> 13;
    h *= 1274126177u;
    h ^= h >> 16;
    return h;
}

float value_noise(float2 p, uint seed) {
    float2 cell = floor(p);
    float2 local = frac(p);
    float2 u = fade2(local);

    int2 base = int2(cell);
    float n00 = hash11(hash2d(base, seed));
    float n10 = hash11(hash2d(base + int2(1, 0), seed));
    float n01 = hash11(hash2d(base + int2(0, 1), seed));
    float n11 = hash11(hash2d(base + int2(1, 1), seed));

    float nx0 = lerp(n00, n10, u.x);
    float nx1 = lerp(n01, n11, u.x);
    return lerp(nx0, nx1, u.y);
}

float fbm(float2 p, int octaves, float lacunarity, float gain, uint seed) {
    float amplitude = 0.5f;
    float frequency = 1.0f;
    float value = 0.0f;
    float range = 0.0f;

    [unroll]
    for (int i = 0; i < 8; ++i) {
        if (i >= octaves) break;
        value += value_noise(p * frequency, seed + uint(i) * 97u) * amplitude;
        range += amplitude;
        frequency *= lacunarity;
        amplitude *= gain;
    }

    return range > 0.0f ? value / range : 0.0f;
}

uint buffer_idx(uint base_offset, uint W, uint H, int ix, int iy) {
    ix = clamp(ix, 0, int(W) - 1);
    iy = clamp(iy, 0, int(H) - 1);
    return base_offset + (uint(iy) * W + uint(ix)) * 4u;
}

float4 load_buffer(uint buffer_index, uint base_offset, uint W, uint H, int ix, int iy) {
    uint idx = buffer_idx(base_offset, W, H, ix, iy);
    return float4(
        asfloat(buffers[buffer_index][idx + 0]),
        asfloat(buffers[buffer_index][idx + 1]),
        asfloat(buffers[buffer_index][idx + 2]),
        asfloat(buffers[buffer_index][idx + 3])
    );
}

float4 sample_buffer_linear(uint buffer_index, uint base_offset, uint W, uint H, float2 uv) {
    float2 clamped = clamp(uv, float2(0.0f, 0.0f), float2(1.0f, 1.0f));
    float2 pos = clamped * float2(W, H) - 0.5f;
    int2 i0 = int2(floor(pos));
    float2 f = frac(pos);

    float4 c00 = load_buffer(buffer_index, base_offset, W, H, i0.x,     i0.y);
    float4 c10 = load_buffer(buffer_index, base_offset, W, H, i0.x + 1, i0.y);
    float4 c01 = load_buffer(buffer_index, base_offset, W, H, i0.x,     i0.y + 1);
    float4 c11 = load_buffer(buffer_index, base_offset, W, H, i0.x + 1, i0.y + 1);

    float4 cx0 = lerp(c00, c10, f.x);
    float4 cx1 = lerp(c01, c11, f.x);
    return lerp(cx0, cx1, f.y);
}

void store_buffer(uint buffer_index, uint base_offset, uint W, uint H, int ix, int iy, float4 value) {
    if (ix < 0 || iy < 0 || ix >= int(W) || iy >= int(H)) return;
    uint idx = buffer_idx(base_offset, W, H, ix, iy);
    buffers[buffer_index][idx + 0] = asuint(value.x);
    buffers[buffer_index][idx + 1] = asuint(value.y);
    buffers[buffer_index][idx + 2] = asuint(value.z);
    buffers[buffer_index][idx + 3] = asuint(value.w);
}

float3 getPalette(float x, float3 c1, float3 c2, float3 p1, float3 p2) {
    float x2 = frac(x / 2.0f);
    x = frac(x);
    float3 pws = float3((1.0f - x) * (1.0f - x), 2.0f * (1.0f - x) * x, x * x);
    float3 palA = float3(
        dot(float3(c1.x, p1.x, c2.x), pws),
        dot(float3(c1.y, p1.y, c2.y), pws),
        dot(float3(c1.z, p1.z, c2.z), pws)
    );
    float3 palB = float3(
        dot(float3(c2.x, p2.x, c1.x), pws),
        dot(float3(c2.y, p2.y, c1.y), pws),
        dot(float3(c2.z, p2.z, c1.z), pws)
    );
    return clamp(lerp(palA, palB, step(0.5f, x2)), 0.0f, 1.0f);
}

float3 palette_primary(float x) {
    return getPalette(-x, float3(0.20f, 0.48f, 0.74f), float3(0.92f, 0.42f, 0.16f),
                      float3(1.0f, 1.10f, 0.60f), float3(1.0f, -0.40f, 0.05f));
}

float3 palette_secondary(float x) {
    return getPalette(-x, float3(0.42f, 0.32f, 0.56f), float3(0.92f, 0.76f, 0.46f),
                      float3(0.12f, 0.82f, 1.30f), float3(1.25f, -0.12f, 0.12f));
}

float2 point1(float t) {
    t *= 0.62f;
    return float2(0.18f, 0.5f + sin(t) * 0.25f);
}

float2 point2(float t) {
    t *= 0.62f;
    return float2(0.82f, 0.5f + cos(t + 1.5708f) * 0.25f);
}

float4 solve_fluid(
    uint buffer_index,
    uint base_offset,
    float2 uv,
    int ix,
    int iy,
    uint W,
    uint H,
    float2 stepSize,
    float4 mouse_vec,
    float4 prev_mouse_vec,
    float2 center)
{
    const float dt = 0.15f;
    const float vorticityThreshold = 0.25f;
    const float velocityThreshold  = 24.0f;
    const float viscosityThreshold = 0.64f;
    const float k = 0.2f;
    const float s = k / dt;

    float4 fluidData = load_buffer(buffer_index, base_offset, W, H, ix, iy);
    float4 fr = load_buffer(buffer_index, base_offset, W, H, ix + 1, iy);
    float4 fl = load_buffer(buffer_index, base_offset, W, H, ix - 1, iy);
    float4 ft = load_buffer(buffer_index, base_offset, W, H, ix, iy + 1);
    float4 fd = load_buffer(buffer_index, base_offset, W, H, ix, iy - 1);

    float3 ddx = (fr.xyz - fl.xyz) * 0.5f;
    float3 ddy = (ft.xyz - fd.xyz) * 0.5f;
    float divergence = ddx.x + ddy.y;
    float2 densityDiff = float2(ddx.z, ddy.z);

    fluidData.z -= dt * dot(float3(densityDiff, divergence), fluidData.xyz);

    float2 laplacian = fr.xy + fl.xy + ft.xy + fd.xy - 4.0f * fluidData.xy;
    float2 viscosityForce = viscosityThreshold * laplacian;

    float2 uvHistory = uv - dt * fluidData.xy * stepSize;
    float4 advect = sample_buffer_linear(buffer_index, base_offset, W, H, uvHistory);
    fluidData.x = advect.x;
    fluidData.y = advect.y;
    fluidData.w = advect.w;

    float2 extForce = float2(0.0f, 0.0f);
    if (mouse_vec.z > 1.0f && prev_mouse_vec.z > 1.0f) {
        float2 dragDir = clamp((mouse_vec.xy - prev_mouse_vec.xy) * stepSize * 600.0f, -10.0f, 10.0f);
        float2 p = uv - mouse_vec.xy * stepSize;
        extForce += 0.001f / max(dot(p, p), 1e-5f) * dragDir;
    }

    float2 rel = uv - center;
    float radius = length(rel) + 1e-5f;
    float2 swirl_dir = float2(-rel.y, rel.x);
    float swirl_gauss = exp(-pow(radius * 3.0f, 2.0f));
    float swirl_strength = 0.0009f * swirl_gauss;
    extForce += swirl_dir * swirl_strength;

    fluidData.xy += dt * (viscosityForce - s * densityDiff + extForce);
    fluidData.xy = max(float2(0.0f, 0.0f), abs(fluidData.xy) - 5e-6f) * sign(fluidData.xy);

    fluidData.w = (fd.x - ft.x + fr.y - fl.y);
    float2 vorticity = float2(abs(ft.w) - abs(fd.w), abs(fl.w) - abs(fr.w));
    float vort_len = length(vorticity) + 1e-5f;
    vorticity = vorticity * (vorticityThreshold / vort_len) * fluidData.w;
    fluidData.xy += vorticity;

    fluidData.y *= smoothstep(0.5f, 0.48f, abs(uv.y - 0.5f));
    fluidData.x *= smoothstep(0.5f, 0.49f, abs(uv.x - 0.5f));

    float minW = -vorticityThreshold;
    float maxW = vorticityThreshold;
    fluidData = clamp(
        fluidData,
        float4(float2(-velocityThreshold, -velocityThreshold), 0.5f, minW),
        float4(float2(velocityThreshold, velocityThreshold), 3.0f, maxW)
    );

    return fluidData;
}

float4 update_color(
    uint fluid_buffer_index,
    uint fluid_offset,
    uint color_buffer_index,
    uint color_read_offset,
    float2 uv,
    float2 stepSize,
    uint W,
    uint H,
    float time,
    float frame,
    float4 mouse_vec,
    float4 prev_mouse_vec)
{
    const float dt = 0.15f;

    float4 fluid = sample_buffer_linear(fluid_buffer_index, fluid_offset, W, H, uv);
    float2 velo = fluid.xy;

    float4 col_prev = (frame < 0.5f)
        ? float4(0.0f, 0.0f, 0.0f, 0.0f)
        : sample_buffer_linear(color_buffer_index, color_read_offset, W, H, uv - dt * velo * stepSize * 3.0f);

    float4 col = col_prev;
    float2 center = float2(0.5f, 0.5f);
    float2 rel = uv - center;
    float radius = length(rel);
    float angle = atan2(rel.y, rel.x);

    float swirl_wave = sin(time * 0.65f + angle * 2.9f);
    float ring = exp(-pow(radius * 1.9f, 2.3f));
    float hollow = exp(-pow(max(radius - 0.20f, 0.0f) * 4.3f, 2.0f));
    float base_strength = (0.0028f + 0.0016f * swirl_wave) * (ring + hollow * 0.85f);

    float palette_mix = fbm(uv * 8.0f + time * 0.22f, 3, 2.3f, 0.55f, 211u);
    float3 base_color = lerp(palette_primary(time * 0.05f + angle * 0.2f),
                             palette_secondary(time * 0.09f - radius * 2.6f),
                             saturate(palette_mix));

    col.rgb += base_color * base_strength * 2.2f;
    col.a   += base_strength * 1.8f;

    float2 mouse_uv = mouse_vec.xy * stepSize;
    float2 prev_mouse_uv = prev_mouse_vec.xy * stepSize;

    if (mouse_vec.z > 1.0f && prev_mouse_vec.z > 1.0f) {
        float hue = hash11(asuint(mouse_vec.z + mouse_vec.x + mouse_vec.y + time));
        float3 mouse_color = lerp(palette_secondary(time * 0.18f + hue * 0.5f),
                                  palette_primary(time * 0.11f - hue * 0.35f), 0.55f);
        float bloom = smoothstep(-0.4f, 0.6f, length(mouse_uv - prev_mouse_uv));
        float dist = max(pow(length(uv - mouse_vec.xy * stepSize), 1.55f), 1e-4f);
        col += float4(mouse_color, 1.0f) * (bloom * 0.0006f) / dist;
    }

    float2 p1 = point1(time);
    float2 p2 = point2(time);
    float dens_boost = 0.0010f * (ring + hollow * 0.6f);
    col.rgb += 0.0015f / (0.0006f + pow(length(uv - p1), 1.7f)) * dt * 0.12f * palette_primary(time * 0.05f);
    col.rgb += 0.0015f / (0.0006f + pow(length(uv - p2), 1.7f)) * dt * 0.12f * palette_secondary(time * 0.05f + 0.675f);
    col.a   += dens_boost;

    float circle_mask = 1.0f - smoothstep(0.26f, 0.38f, radius);
    float circle_emission = circle_mask * 0.55f;
    col.rgb = lerp(col.rgb, palette_primary(time * 0.13f), circle_emission);
    col.a   = max(col.a, circle_mask * 1.1f);

    col = clamp(col, 0.0f, 5.0f);
    col = max(col - (col * 0.005f), 0.0f);

    return col;
}

[numthreads(128, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    uint id = tid.x;
    const uint W = push_constants.screen_width;
    const uint H = push_constants.screen_height;
    const uint total_pixels = W * H;
    if (id >= total_pixels) return;

    float2 resolution = float2(float(W), float(H));
    float2 invResolution = 1.0f / resolution;
    float2 uv = (float2(id % W, id / W) + 0.5f) * invResolution;

    GlobalData state = globalData[0];
    float frame = state.frameCount;
    if (!(frame >= 0.0f && frame < 1e9f)) {
        frame = 0.0f;
        state.ping = 0u;
        state.prevMouseUv = uv;
        state.prevMouseDown = 0.0f;
        state.frameCount = 0.0f;
    }

    uint ping = state.ping & 1u;
    uint next_ping = 1u - ping;
    uint stride = total_pixels * 4u;

    uint fluid_read_offset  = ping * stride;
    uint fluid_write_offset = next_ping * stride;
    uint color_read_offset  = ping * stride;
    uint color_write_offset = next_ping * stride;

    float2 mouse_px = float2(push_constants.mouse_x, push_constants.mouse_y);
    float2 mouse_uv = clamp(mouse_px * invResolution, float2(0.0f, 0.0f), float2(1.0f, 1.0f));
    bool mouse_add = (push_constants.mouse_left != 0u);
    bool mouse_erase = (push_constants.mouse_right != 0u);
    float4 mouse_vec = float4(mouse_px, mouse_add ? 2.0f : 0.0f, mouse_erase ? 2.0f : 0.0f);

    float2 prev_mouse_uv = (frame > 0.5f) ? state.prevMouseUv : mouse_uv;
    float4 prev_mouse_vec = load_buffer(1, fluid_read_offset, W, H, 0, 0);
    if (frame < 0.5f) {
        prev_mouse_vec = mouse_vec;
    }

    const float2 center = float2(0.5f, 0.5f);
    float2 stepSize = invResolution;
    int ix = int(id % W);
    int iy = int(id / W);

    uint read_offset = fluid_read_offset;
    uint write_offset = fluid_write_offset;

    for (int pass = 0; pass < PASSES; ++pass) {
        float4 data;
        if (iy == 0) {
            data = mouse_vec;
        } else {
            data = solve_fluid(1, read_offset, uv, ix, iy, W, H, stepSize, mouse_vec, prev_mouse_vec, center);
            if (frame < 0.5f) {
                data = float4(0.0f, 0.0f, 0.0f, 0.0f);
            }
            if (mouse_erase) {
                float dist2 = dot(uv - mouse_uv, uv - mouse_uv);
                float erase = exp(-dist2 * 1200.0f);
                data.z = max(data.z - erase * 2.0f, 0.0f);
                data.xy *= (1.0f - erase * 0.4f);
            }
        }

        store_buffer(1, write_offset, W, H, ix, iy, data);

        if (pass < PASSES - 1) {
            uint tmp = read_offset;
            read_offset = write_offset;
            write_offset = tmp;
        }
    }

    float4 color = update_color(1, write_offset, 2, color_read_offset, uv, stepSize, W, H, push_constants.time, frame, mouse_vec, prev_mouse_vec);

    if (iy == 0) {
        if (ix == 0) {
            color = mouse_vec;
        } else {
            color = float4(0.0f, 0.0f, 0.0f, 0.0f);
        }
    }

    store_buffer(2, color_write_offset, W, H, ix, iy, color);

    uint accum_idx = id * 4u;
    buffers[0][accum_idx + 0] = (uint)(saturate(color.r / 5.0f) * COLOR_SCALE * push_constants.brightness);
    buffers[0][accum_idx + 1] = (uint)(saturate(color.g / 5.0f) * COLOR_SCALE * push_constants.brightness);
    buffers[0][accum_idx + 2] = (uint)(saturate(color.b / 5.0f) * COLOR_SCALE * push_constants.brightness);
    buffers[0][accum_idx + 3] = (uint)(saturate(color.a / 5.0f) * COLOR_SCALE);

    if (id == 0) {
        state.prevMouseUv = mouse_uv;
        state.prevMouseDown = mouse_add ? 1.0f : 0.0f;
        state.frameCount = frame + 1.0f;
        state.ping = next_ping;
        globalData[0] = state;
    }
}
