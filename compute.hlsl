static const float COLOR_SCALE = 4096.0f;

struct PushConstants {
    float time;
    float delta_time;
    uint  screen_width;
    uint  screen_height;
    float brightness;
    uint  move_forward;
    uint  move_backward;
    uint  move_right;
    uint  move_left;
    uint  zoom_in;
    uint  zoom_out;
    uint  speed;
    uint  reset_camera;
    uint  options;
    uint  _pad0;
};
[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(0, 0)]] RWStructuredBuffer<uint> buffers[];

static const uint OPTION_CAMERA_UPDATE = 1u << 0;

static const float CAMERA_DEFAULT_ZOOM = 5.0f;
static const float CAMERA_MOVE_SPEED   = 40.0f;
static const float CAMERA_MIN_ZOOM     = 2.0f;
static const float CAMERA_MAX_ZOOM     = 5000.0f;
static const float CAMERA_ZOOM_RATE    = 2.2f;
static const float CAMERA_FAST_SCALE   = 2.4f;

static const uint CAMERA_SIGNATURE = 0xC0FFEEAAu;

struct CameraStateData {
    float2 position;
    float  zoom;
    float  pad0;
    uint   initialized;
    uint   pad1;
    uint   pad2;
    uint   pad3;
};

[[vk::binding(3, 0)]] RWStructuredBuffer<CameraStateData> camera_state;

struct KeyState {
    bool forward;
    bool backward;
    bool right;
    bool left;
    bool zoom_in;
    bool zoom_out;
    bool speed;
    bool reset;
};

KeyState read_key_state_inputs() {
    KeyState keys;
    keys.forward  = push_constants.move_forward != 0u;
    keys.backward = push_constants.move_backward != 0u;
    keys.right    = push_constants.move_right != 0u;
    keys.left     = push_constants.move_left != 0u;
    keys.zoom_in  = push_constants.zoom_in != 0u;
    keys.zoom_out = push_constants.zoom_out != 0u;
    keys.speed    = push_constants.speed != 0u;
    keys.reset    = push_constants.reset_camera != 0u;
    return keys;
}

int compute_circle_sample_radius(float zoom, float aspect, float2 resolution) {
    float world_step_x = abs(zoom) * (2.0f / resolution.x) * aspect;
    float world_step_y = abs(zoom) * (2.0f / resolution.y);
    float max_step = max(world_step_x, world_step_y);
    int extra = (int)ceil(max_step);
    return clamp(extra + 2, 2, 10);
}

float hash11(float n) {
    return frac(sin(n) * 1343758.5453123f);
}

float2 hash21(float2 p) {
    return float2(
        hash11(dot(p, float2(127.1f, 311.7f))),
        hash11(dot(p, float2(269.5f, 183.3f)))
    );
}

float3 hash31(float2 p) {
    return float3(
        hash11(dot(p, float2(12.9898f, 78.233f))),
        hash11(dot(p, float2(93.9898f, 67.345f))),
        hash11(dot(p, float2(45.332f, 11.135f)))
    );
}

float soft_circle(float distance, float radius, float softness) {
    float inner = max(radius - softness, 0.0001f);
    return saturate(1.0f - smoothstep(inner, radius, distance));
}

CameraStateData read_camera_state() {
    CameraStateData state = camera_state[0];
    if (state.initialized != CAMERA_SIGNATURE ||
        !isfinite(state.zoom) ||
        state.zoom < CAMERA_MIN_ZOOM * 0.5f ||
        state.zoom > CAMERA_MAX_ZOOM * 2.0f) {
        state.position = float2(0.0f, 0.0f);
        state.zoom = CAMERA_DEFAULT_ZOOM;
        state.initialized = CAMERA_SIGNATURE;
        state.pad0 = 0.0f;
        state.pad1 = 0u;
        state.pad2 = 0u;
        state.pad3 = 0u;
        camera_state[0] = state;
    }
    return state;
}

void update_camera_state(KeyState keys, float delta_time) {
    if (delta_time <= 0.0f) {
        delta_time = 0.0f;
    }

    CameraStateData state = read_camera_state();

    if (keys.reset) {
        state.position = float2(0.0f, 0.0f);
        state.zoom = CAMERA_DEFAULT_ZOOM;
        state.initialized = CAMERA_SIGNATURE;
        state.pad0 = 0.0f;
        state.pad1 = 0u;
        state.pad2 = 0u;
        state.pad3 = 0u;
        camera_state[0] = state;
        return;
    }

    float2 move = float2(0.0f, 0.0f);
    if (keys.forward)  move.y += 1.0f;
    if (keys.backward) move.y -= 1.0f;
    if (keys.right)    move.x += 1.0f;
    if (keys.left)     move.x -= 1.0f;

    if (dot(move, move) > 0.0f) {
        move = normalize(move);
    }

    float zoom_ratio = clamp(state.zoom / CAMERA_DEFAULT_ZOOM, 0.25f, 12.0f);
    float move_speed = CAMERA_MOVE_SPEED * zoom_ratio;
    bool fast = keys.speed;
    if (fast) {
        move_speed *= CAMERA_FAST_SCALE;
    }

    state.position += move * move_speed * delta_time;

    float zoom_rate = CAMERA_ZOOM_RATE;
    if (fast) {
        zoom_rate *= CAMERA_FAST_SCALE;
    }

    if (keys.zoom_out) {
        state.zoom -= state.zoom * zoom_rate * delta_time;
    }
    if (keys.zoom_in) {
        state.zoom += state.zoom * zoom_rate * delta_time;
    }

    state.zoom = clamp(state.zoom, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM);
    camera_state[0] = state;
}

[numthreads(128, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    uint id = tid.x;
    uint options = push_constants.options;
    KeyState keys = read_key_state_inputs();

    if (options & OPTION_CAMERA_UPDATE) {
        if (id == 0) {
            update_camera_state(keys, push_constants.delta_time);
        }
        return;
    }

    const uint W = push_constants.screen_width;
    const uint H = push_constants.screen_height;
    const uint total_pixels = W * H;
    if (id >= total_pixels) return;

    CameraStateData cam_state = read_camera_state();
    float zoom = max(cam_state.zoom, CAMERA_MIN_ZOOM);
    float2 camera_pos = cam_state.position;

    float2 resolution = float2(float(W), float(H));
    float2 invResolution = 1.0f / resolution;
    float2 uv = (float2(id % W, id / W) + 0.5f) * invResolution;
    float aspect = resolution.x / resolution.y;
    float2 view = uv * 2.0f - 1.0f;
    view.x *= aspect;

    float2 world = camera_pos + view * zoom;

    float3 color = float3(0.016f, 0.018f, 0.020f);
    float density = 0.0f;
    float2 baseCell = floor(world);
    int sample_radius = compute_circle_sample_radius(zoom, aspect, resolution);

    for (int oy = -sample_radius; oy <= sample_radius; ++oy) {
        for (int ox = -sample_radius; ox <= sample_radius; ++ox) {
            float2 cell = baseCell + float2(ox, oy);
            float seed = dot(cell, float2(53.34f, 19.13f));
            float presence = hash11(seed);
            if (presence < 0.97f) {
                continue;
            }

            float2 jitter = hash21(cell) - 0.5f;
            float radius = lerp(0.35f, 0.10f, hash11(seed + 17.23f));
            float softness = lerp(0.20f, 0.55f, hash11(seed + 41.07f));
            float2 center = cell + jitter * 0.9f;

            float dist = length(world - center);
            float coverage = soft_circle(dist, radius, softness);

            float3 randomColor = hash31(cell);
            float3 palette = float3(
                pow(randomColor.x, 1.8f),
                pow(randomColor.y, 1.6f),
                pow(randomColor.z, 1.4f)
            );
            float energy = lerp(0.18f, 0.95f, hash11(seed + 63.5f));

            color += palette * energy * coverage;
            density = max(density, coverage);
        }
    }

    if (density <= 0.0001f) {
        float2 center = float2(0.0f, 0.0f);
        float dist = length(world - center);
        float radius = 0.1f;
        float softness = 0.32f;
        float coverage = soft_circle(dist, radius, softness);
        float3 baseColor = hash31(float2(0.0f, 0.0f));
        float3 palette = float3(
            pow(baseColor.x, 1.8f),
            pow(baseColor.y, 1.6f),
            pow(baseColor.z, 1.4f)
        );
        float energy = 0.65f;

        color += palette * energy * coverage;
        density = max(density, coverage);
    }

    color *= push_constants.brightness;
    color = saturate(color);
    density = saturate(density);

    uint accum_idx = id * 4u;
    buffers[0][accum_idx + 0] = (uint)(color.r * COLOR_SCALE);
    buffers[0][accum_idx + 1] = (uint)(color.g * COLOR_SCALE);
    buffers[0][accum_idx + 2] = (uint)(color.b * COLOR_SCALE);
    buffers[0][accum_idx + 3] = (uint)(density * COLOR_SCALE);
}
