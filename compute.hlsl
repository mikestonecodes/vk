static const float COLOR_SCALE = 4096.0f;
static const float CAMERA_DEFAULT_ZOOM = 5.0f;
static const float CAMERA_MOVE_SPEED   = 40.0f;
static const float CAMERA_MIN_ZOOM     = 2.0f;
static const float CAMERA_MAX_ZOOM     = 5000.0f;
static const float CAMERA_ZOOM_RATE    = 2.2f;
static const float CAMERA_FAST_SCALE   = 2.4f;

static const float CELL_SIZE = 2.0f;
static const float WORLD_RANGE_LIMIT = 1e6f;
static const uint  DYNAMIC_BODY_START = 1u;
static const uint  MAX_ACTIVE_DYNAMIC = 25000u;

static const uint  BODY_CAPACITY = 512000u;
static const uint  GRID_X = 512u;
static const uint  GRID_Y = 512u;
static const uint  DYNAMIC_BODY_POOL = 60000u;
static const float DYNAMIC_BODY_SPEED = 42.0f;
static const float DYNAMIC_BODY_RADIUS = 0.20f;
static const float DYNAMIC_BODY_MAX_DISTANCE = 450.0f;
static const float ROOT_BODY_RADIUS = 0.65f;
static const float BODY_DAMPING = 0.02f;
static const float RELAXATION = 1.0f;
static const float DT_CLAMP = 1.0f / 30.0f;
static const uint  PHYS_SUBSTEPS = 1u;

static const float DELTA_SCALE = 32768.0f;
static const uint DISPATCH_CAMERA_UPDATE      = 0u;
static const uint DISPATCH_INITIALIZE         = 1u;
static const uint DISPATCH_CLEAR_GRID         = 2u;
static const uint DISPATCH_INTEGRATE          = 3u;
static const uint DISPATCH_HISTOGRAM          = 4u;
static const uint DISPATCH_PREFIX_COPY        = 5u;
static const uint DISPATCH_PREFIX_SCAN        = 6u;
static const uint DISPATCH_PREFIX_COPY_SOURCE = 7u;
static const uint DISPATCH_PREFIX_FINALIZE    = 8u;
static const uint DISPATCH_SCATTER            = 9u;
static const uint DISPATCH_ZERO_DELTAS        = 10u;
static const uint DISPATCH_CONSTRAINTS        = 11u;
static const uint DISPATCH_APPLY_DELTAS       = 12u;
static const uint DISPATCH_FINALIZE           = 13u;
static const uint DISPATCH_RENDER             = 14u;

// GPU physics compute pipeline
struct ComputePushConstants {
    float time;
    float delta_time;
    uint  screen_width;
    uint  screen_height;
    uint  move_forward;
    uint  move_backward;
    uint  move_right;
    uint  move_left;
    uint  zoom_in;
    uint  zoom_out;
    uint  speed;
    uint  reset_camera;
    uint  dispatch_mode;
    uint  scan_offset;
    uint  scan_source;
    uint  spawn_circle;
    float mouse_ndc_x;
    float mouse_ndc_y;
    uint  pad0;
    uint  pad1;
};
[[vk::push_constant]] ComputePushConstants push_constants;

struct CameraStateData {
    float2 position;
    float  zoom;
    float  padding;
};

struct SpawnState {
    uint next_dynamic;
    uint active_dynamic;
    uint pad0;
    uint pad1;
};

struct WorldCircle {
    float2 center;
    float  radius;
    float  softness;
    float3 color;
    float  energy;
};


[[vk::binding(0, 0)]] RWStructuredBuffer<uint> accumulation_buffer;
[[vk::binding(3, 0)]] RWStructuredBuffer<CameraStateData> camera_state;
[[vk::binding(20, 0)]] RWStructuredBuffer<float2> body_pos;
[[vk::binding(21, 0)]] RWStructuredBuffer<float2> body_pos_pred;
[[vk::binding(22, 0)]] RWStructuredBuffer<float2> body_vel;
[[vk::binding(23, 0)]] RWStructuredBuffer<float>  body_radius;
[[vk::binding(24, 0)]] RWStructuredBuffer<float>  body_inv_mass;
[[vk::binding(25, 0)]] RWStructuredBuffer<uint>   body_active;
[[vk::binding(26, 0)]] RWStructuredBuffer<int2> body_delta_accum;
[[vk::binding(27, 0)]] RWStructuredBuffer<SpawnState> spawn_state;
[[vk::binding(30, 0)]] RWStructuredBuffer<uint> cell_counts;
[[vk::binding(31, 0)]] RWStructuredBuffer<uint> cell_offsets;
[[vk::binding(32, 0)]] RWStructuredBuffer<uint> cell_scratch;
[[vk::binding(33, 0)]] RWStructuredBuffer<uint> sorted_indices;



///UTILS///

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

float2 safe_normalize(float2 v, float fallback_x) {
    float len_sq = dot(v, v);
    if (len_sq <= 1e-12f) {
        return float2(fallback_x, sqrt(1.0f - fallback_x * fallback_x));
    }
    return v * rsqrt(len_sq);
}
uint wrap_int(int value, uint size_value) {
    int size = max(int(size_value), 1);
    int r = value % size;
    if (r < 0) {
        r += size;
    }
    return uint(r);
}

uint2 world_to_cell(float2 p) {
    float inv_cell = 1.0f / CELL_SIZE;
    int gx = int(floor(p.x * inv_cell));
    int gy = int(floor(p.y * inv_cell));
    uint grid_x = GRID_X;
    uint grid_y = GRID_Y;
    return uint2(
        wrap_int(gx, grid_x),
        wrap_int(gy, grid_y)
    );
}

uint cell_index(uint2 g) {
    uint grid_x = GRID_X;
    return g.y * grid_x + g.x;
}
bool world_circle_from_cell(float2 cell, out WorldCircle circle) {
    float seed = dot(cell, float2(53.34f, 19.13f));
    float presence = hash11(seed);
    if (presence < 0.97f) {
        circle = (WorldCircle)0;
        return false;
    }

    float2 jitter = hash21(cell) - 0.5f;
    circle.center = cell + jitter * 0.9f;
    circle.radius = lerp(0.35f, 0.10f, hash11(seed + 17.23f));
    circle.softness = lerp(0.20f, 0.55f, hash11(seed + 41.07f));

    float3 randomColor = hash31(cell);
    circle.color = float3(
        pow(randomColor.x, 1.8f),
        pow(randomColor.y, 1.6f),
        pow(randomColor.z, 1.4f)
    );
    circle.energy = lerp(0.18f, 0.95f, hash11(seed + 63.5f));
    return true;
}

int float_to_delta(float value) {
    float scaled = clamp(value * DELTA_SCALE, -214748000.0f, 214748000.0f);
    return int(scaled);
}

float delta_to_float(int value) {
    return float(value) / DELTA_SCALE;
}

void store_body_delta(uint id, float2 value) {
    body_delta_accum[id] = int2(float_to_delta(value.x), float_to_delta(value.y));
}

float2 load_body_delta(uint id) {
    int2 packed = body_delta_accum[id];
    return float2(delta_to_float(packed.x), delta_to_float(packed.y));
}

void atomic_add_body_delta(uint id, float2 value) {
    int inc_x = float_to_delta(value.x);
    int inc_y = float_to_delta(value.y);
    if (inc_x != 0) {
        InterlockedAdd(body_delta_accum[id].x, inc_x);
    }
    if (inc_y != 0) {
        InterlockedAdd(body_delta_accum[id].y, inc_y);
    }
}


CameraStateData load_camera_state() {
    return camera_state[0];
}

uint grid_cell_count() {
    return GRID_X * GRID_Y;
}

//MAIN STUFF

void update_camera_state(float delta_time) {
    if (delta_time <= 0.0f) {
        delta_time = 0.0f;
    }

    CameraStateData state = load_camera_state();

    if (push_constants.reset_camera != 0u) {
        state.position = float2(0.0f, 0.0f);
        state.zoom = CAMERA_DEFAULT_ZOOM;
        state.padding = 0.0f;
        camera_state[0] = state;
        return;
    }

    float2 move = float2(0.0f, 0.0f);
    if (push_constants.move_forward != 0u)  move.y += 1.0f;
    if (push_constants.move_backward != 0u) move.y -= 1.0f;
    if (push_constants.move_right != 0u)    move.x += 1.0f;
    if (push_constants.move_left != 0u)     move.x -= 1.0f;

    if (dot(move, move) > 0.0f) {
        move = normalize(move);
    }

    float zoom_ratio = clamp(state.zoom / CAMERA_DEFAULT_ZOOM, 0.25f, 12.0f);
    float move_speed = CAMERA_MOVE_SPEED * zoom_ratio;
    bool fast = (push_constants.speed != 0u);
    if (fast) {
        move_speed *= CAMERA_FAST_SCALE;
    }

    state.position += move * move_speed * delta_time;

    float zoom_rate = CAMERA_ZOOM_RATE;
    if (fast) {
        zoom_rate *= CAMERA_FAST_SCALE;
    }

    if (push_constants.zoom_out != 0u) {
        state.zoom -= state.zoom * zoom_rate * delta_time;
    }
    if (push_constants.zoom_in != 0u) {
        state.zoom += state.zoom * zoom_rate * delta_time;
    }

    state.zoom = clamp(state.zoom, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM);
    state.padding = 0.0f;
    camera_state[0] = state;
}

bool collide_world(float2 p, float expand, out float2 n_out, out float depth_out, out float2 center_out, out float radius_out, out float energy_out) {
    float2 base_cell = floor(p);
    bool hit = false;
    float best_depth = 0.0f;
    float2 best_normal = float2(0.0f, 0.0f);
    WorldCircle best_circle = (WorldCircle)0;

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            float2 cell = base_cell + float2(ox, oy);
            WorldCircle circle;
            if (!world_circle_from_cell(cell, circle)) {
                continue;
            }
            float2 delta = p - circle.center;
            float dist = length(delta);
            float penetration = (circle.radius + expand) - dist;
            if (penetration > best_depth) {
                float safe_dist = max(dist, 1e-4f);
                best_depth = penetration;
                best_normal = delta / safe_dist;
                hit = true;
                best_circle = circle;
            }
        }
    }

    if (hit) {
        n_out = best_normal;
        depth_out = best_depth;
        center_out = best_circle.center;
        radius_out = best_circle.radius;
        energy_out = best_circle.energy;
    } else {
        n_out = float2(0.0f, 0.0f);
        depth_out = 0.0f;
        center_out = float2(0.0f, 0.0f);
        radius_out = 0.0f;
        energy_out = 0.0f;
    }
    return hit;
}



void deactivate_body(uint id) {
    if (id >= BODY_CAPACITY) {
        return;
    }
    uint state = body_active[id];
    if (state == 0u) {
        return;
    }

    if (id >= DYNAMIC_BODY_START) {
        uint active = spawn_state[0].active_dynamic;
        if (active > 0u) {
            spawn_state[0].active_dynamic = active - 1u;
        }
    }

    float2 current = body_pos_pred[id];
    body_active[id] = 0u;
    body_pos[id] = current;
    body_pos_pred[id] = current;
    body_vel[id] = float2(0.0f, 0.0f);
    store_body_delta(id, float2(0.0f, 0.0f));
}



void initialize_bodies(uint id) {
    if (id == 0u) {
        spawn_state[0].next_dynamic = 0u;
        spawn_state[0].active_dynamic = 0u;
        spawn_state[0].pad0 = 0u;
        spawn_state[0].pad1 = 0u;
    }
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    bool is_root = (id == 0u);
    body_active[id] = is_root ? 1u : 0u;
    body_radius[id] = is_root ? ROOT_BODY_RADIUS : DYNAMIC_BODY_RADIUS;
    body_inv_mass[id] = is_root ? 0.0f : 1.0f;
    body_pos[id] = float2(0.0f, 0.0f);
    body_pos_pred[id] = body_pos[id];
    body_vel[id] = float2(0.0f, 0.0f);
    store_body_delta(id, float2(0.0f, 0.0f));
}

void clear_grid(uint id) {
    uint cells = grid_cell_count();
    if (id >= cells) {
        return;
    }
    cell_counts[id] = 0u;
    cell_scratch[id] = 0u;
}

void maybe_spawn_circles() {
    if (push_constants.spawn_circle == 0u) {
        return;
    }

    uint capacity = BODY_CAPACITY;
    if (capacity <= DYNAMIC_BODY_START) {
        return;
    }

    uint pool = min(DYNAMIC_BODY_POOL, capacity - DYNAMIC_BODY_START);
    if (pool == 0u) {
        return;
    }

    CameraStateData cam = load_camera_state();
    float2 root = body_pos[0u];

    float aspect = (push_constants.screen_height > 0u)
        ? (float(push_constants.screen_width) / float(push_constants.screen_height))
        : 1.0f;
    float2 uv = float2(push_constants.mouse_ndc_x, push_constants.mouse_ndc_y);
    float2 view = uv * 2.0f - 1.0f;
    view.x *= aspect;
    float zoom = max(cam.zoom, 0.001f);
    float2 target_world = cam.position + view * zoom;
    float2 dir = target_world - root;
    float len_sq = dot(dir, dir);
    if (len_sq <= 1e-8f) {
        dir = float2(1.0f, 0.0f);
    } else {
        dir *= rsqrt(len_sq);
    }

    const uint SPAWN_BATCH = 16u;
    uint active_current = spawn_state[0].active_dynamic;
    if (active_current >= MAX_ACTIVE_DYNAMIC) {
        return;
    }

    uint spawn_budget = min(SPAWN_BATCH, MAX_ACTIVE_DYNAMIC - active_current);
    if (spawn_budget == 0u) {
        return;
    }

    uint next_index_base = spawn_state[0].next_dynamic;

    for (uint n = 0u; n < spawn_budget; ++n) {
        uint next_index = next_index_base + n;
        uint slot = DYNAMIC_BODY_START + (next_index % pool);
        if (slot >= capacity) {
            slot = capacity - 1u;
        }

        float jitter = (float(n) / float(max(SPAWN_BATCH, 1u))) - 0.5f;
        float angle_step = 0.08f * float(n);
        float2 rotated = float2(
            dir.x * cos(angle_step) - dir.y * sin(angle_step),
            dir.x * sin(angle_step) + dir.y * cos(angle_step)
        );

        float spread = 0.6f + 0.15f * float(n % 4u);
        float spawn_offset = ROOT_BODY_RADIUS + DYNAMIC_BODY_RADIUS + 0.05f + jitter * 0.1f;
        float2 spawn_pos = root + rotated * spawn_offset;
        float2 velocity = rotated * (DYNAMIC_BODY_SPEED * spread);

        body_active[slot] = 1u;
        body_radius[slot] = DYNAMIC_BODY_RADIUS;
        body_inv_mass[slot] = 1.0f;
        body_pos[slot] = spawn_pos;
        body_pos_pred[slot] = spawn_pos;
        body_vel[slot] = velocity;
        store_body_delta(slot, float2(0.0f, 0.0f));
    }

    spawn_state[0].next_dynamic = next_index_base + spawn_budget;
    spawn_state[0].active_dynamic = active_current + spawn_budget;
}

void integrate_predict(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    if (body_active[id] == 0u) {
        return;
    }

    float dt = min(push_constants.delta_time, DT_CLAMP);
    dt = max(dt, 0.0f);
    if (PHYS_SUBSTEPS > 1u) {
        dt = dt / float(PHYS_SUBSTEPS);
    }

    float inv_mass = body_inv_mass[id];
    float2 vel = body_vel[id];

    if (inv_mass <= 0.0f) {
        body_vel[id] = float2(0.0f, 0.0f);
        body_pos_pred[id] = body_pos[id];
        return;
    }

    float2 pos = body_pos[id];
    float2 predicted = pos + vel * dt;

    if (!all(isfinite(predicted))) {
        predicted = pos;
        vel = float2(0.0f, 0.0f);
    }

    body_vel[id] = vel;
    body_pos_pred[id] = predicted;
}

void histogram_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    if (body_active[id] == 0u) {
        return;
    }

    float2 pos = body_pos_pred[id];
    if (!all(isfinite(pos))) {
        return;
    }

    uint2 cell = world_to_cell(pos);
    uint index = cell_index(cell);
    InterlockedAdd(cell_counts[index], 1u);
}

void prefix_copy_kernel(uint id) {
    uint cells = grid_cell_count();
    if (id >= cells) {
        return;
    }
    uint count = cell_counts[id];
    cell_offsets[id] = count;
    cell_scratch[id] = 0u;
    if (id == 0u) {
        cell_offsets[cells] = 0u;
    }
}

void prefix_scan_step(uint id, uint source, uint offset) {
    if (offset == 0u) {
        return;
    }
    uint cells = grid_cell_count();
    if (id >= cells) {
        return;
    }

    bool src_is_offsets = (source == 0u);
    uint value = src_is_offsets ? cell_offsets[id] : cell_scratch[id];
    if (id >= offset) {
        uint addend = src_is_offsets ? cell_offsets[id - offset] : cell_scratch[id - offset];
        value += addend;
    }

    if (src_is_offsets) {
        cell_scratch[id] = value;
    } else {
        cell_offsets[id] = value;
    }
}

void prefix_copy_source(uint id) {
    uint cells = grid_cell_count();
    if (id >= cells) {
        return;
    }
    cell_scratch[id] = cell_offsets[id];
}

void prefix_finalize_kernel(uint id, uint source) {
    uint cells = grid_cell_count();
    if (cells == 0u) {
        return;
    }

    bool src_is_offsets = (source == 0u);

    if (id < cells) {
        uint inclusive_prev = (id == 0u) ? 0u : (src_is_offsets ? cell_offsets[id - 1u] : cell_scratch[id - 1u]);
        cell_offsets[id] = inclusive_prev;
        cell_scratch[id] = 0u;
    }

    if (id == 0u) {
        uint last_inclusive = src_is_offsets ? cell_offsets[cells - 1u] : cell_scratch[cells - 1u];
        cell_offsets[cells] = last_inclusive;
    }
}

void scatter_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    if (body_active[id] == 0u) {
        return;
    }

    float2 pos = body_pos_pred[id];
    if (!all(isfinite(pos))) {
        return;
    }

    uint2 cell = world_to_cell(pos);
    uint idx = cell_index(cell);
    uint base = cell_offsets[idx];
    uint offset;
    InterlockedAdd(cell_scratch[idx], 1u, offset);
    uint write_index = base + offset;

    if (write_index < capacity) {
        sorted_indices[write_index] = id;
    }
}

void zero_deltas(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    if (body_active[id] == 0u) {
        return;
    }
    store_body_delta(id, float2(0.0f, 0.0f));
}

void constraints_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }

    if (body_active[id] == 0u) {
        return;
    }

    float2 xi = body_pos_pred[id];
    float  ri = body_radius[id];
    float  wi = body_inv_mass[id];

    if (!all(isfinite(xi))) {
        return;
    }

    // World collision
    if (wi > 0.0f) {
        float2 normal;
        float depth;
        float2 circle_center;
        float circle_radius;
        float circle_energy;
        if (collide_world(xi, ri, normal, depth, circle_center, circle_radius, circle_energy)) {
            if (id >= DYNAMIC_BODY_START) {
                return;
            }
            float2 corr = -(depth)*normal * wi;
            atomic_add_body_delta(id, corr);
        }
    }

    uint2 gi = world_to_cell(xi);
    uint grid_x = GRID_X;
    uint grid_y = GRID_Y;
    uint cells = grid_cell_count();

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            uint nx = wrap_int(int(gi.x) + ox, grid_x);
            uint ny = wrap_int(int(gi.y) + oy, grid_y);
            uint c = ny * grid_x + nx;
            if (c >= cells) {
                continue;
            }
            uint begin = cell_offsets[c];
            uint end = cell_offsets[c + 1u];
            for (uint k = begin; k < end; ++k) {
                uint j = sorted_indices[k];
                if (j <= id || j >= capacity) {
                    continue;
                }
                if (body_active[j] == 0u) {
                    continue;
                }

                float2 xj = body_pos_pred[j];
                float  rj = body_radius[j];
                float  wj = body_inv_mass[j];

                float2 delta = xj - xi;
                float dist_sq = dot(delta, delta);
                float target = ri + rj;
                if (dist_sq >= target * target || dist_sq <= 1e-12f) {
                    continue;
                }

                float dist = sqrt(dist_sq);
                float2 n = delta / max(dist, 1e-6f);
                float penetration = target - dist;
                float wsum = wi + wj;
                if (wsum <= 0.0f) {
                    continue;
                }

                float2 corr_i = -(wi / wsum) * penetration * n;
                float2 corr_j =  (wj / wsum) * penetration * n;

                atomic_add_body_delta(id, corr_i);
                atomic_add_body_delta(j, corr_j);
            }
        }
    }
}

void apply_deltas(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    if (body_active[id] == 0u) {
        return;
    }

    float2 dp = load_body_delta(id) * RELAXATION;
    float mag = length(dp);
    float max_shift = DYNAMIC_BODY_RADIUS * 2.0f + ROOT_BODY_RADIUS;
    if (mag > max_shift) {
        dp *= (max_shift / max(mag, 1e-4f));
    }

    if (body_inv_mass[id] > 0.0f) {
        body_pos_pred[id] += dp;
    }
}

void finalize_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        return;
    }
    if (body_active[id] == 0u) {
        return;
    }

    float dt = min(push_constants.delta_time, DT_CLAMP);
    dt = max(dt, 1e-4f);
    if (PHYS_SUBSTEPS > 1u) {
        dt = dt / float(PHYS_SUBSTEPS);
    }

    float2 x0 = body_pos[id];
    float2 x1 = body_pos_pred[id];
    float inv_mass = body_inv_mass[id];

    if (inv_mass <= 0.0f) {
        x1 = x0;
    }

    float2 vel = (x1 - x0) / dt;
    float damping = saturate(1.0f - BODY_DAMPING);
    vel *= damping;

    if (!all(isfinite(vel)) || !all(isfinite(x1))) {
        vel = float2(0.0f, 0.0f);
        x1 = x0;
        if (inv_mass > 0.0f) {
            body_pos_pred[id] = x0;
            body_pos[id] = x0;
            body_vel[id] = float2(0.0f, 0.0f);
            deactivate_body(id);
            return;
        }
    }

    if (inv_mass <= 0.0f) {
        body_vel[id] = float2(0.0f, 0.0f);
    } else {
        body_vel[id] = vel;
    }
    body_pos[id] = x1;
    body_pos_pred[id] = x1;

    if (id >= DYNAMIC_BODY_START && inv_mass > 0.0f) {
        float dist_sq = dot(x1, x1);
        float limit = DYNAMIC_BODY_MAX_DISTANCE;
        if (dist_sq > limit * limit) {
            body_vel[id] = float2(0.0f, 0.0f);
            deactivate_body(id);
            return;
        }
    }
}

int compute_circle_sample_radius(float zoom, float aspect, float2 resolution) {
    float world_step_x = abs(zoom) * (2.0f / resolution.x) * aspect;
    float world_step_y = abs(zoom) * (2.0f / resolution.y);
    float max_step = max(world_step_x, world_step_y);
    int extra = (int)ceil(max_step);
    return clamp(extra + 2, 2, 10);
}

void render_kernel(uint id) {
    uint width = push_constants.screen_width;
    uint height = push_constants.screen_height;
    uint total_pixels = width * height;
    if (id >= total_pixels || width == 0u || height == 0u) {
        return;
    }

    CameraStateData cam_state = load_camera_state();
    float zoom = max(cam_state.zoom, CAMERA_MIN_ZOOM);
    float2 camera_pos = cam_state.position;

    float2 resolution = float2(float(width), float(height));
    float2 invResolution = 1.0f / resolution;
    float2 uv = (float2(id % width, id / width) + 0.5f) * invResolution;

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
            WorldCircle circle;
            if (!world_circle_from_cell(cell, circle)) {
                continue;
            }
            float dist = length(world - circle.center);
            float coverage = soft_circle(dist, circle.radius, circle.softness);
            color += circle.color * circle.energy * coverage;
            density = max(density, coverage);
        }
    }

    if (density <= 0.0001f) {
        WorldCircle circle;
        circle.center = float2(0.0f, 0.0f);
        circle.radius = ROOT_BODY_RADIUS;
        circle.softness = circle.radius * 0.5f;
        circle.color = float3(0.85f, 0.90f, 0.98f);
        circle.energy = 0.65f;
        float dist = length(world - circle.center);
        float coverage = soft_circle(dist, circle.radius, circle.softness);
        color += circle.color * circle.energy * coverage;
        density = max(density, coverage);
    }

    // Dynamic bodies
    uint grid_x = GRID_X;
    uint grid_y = GRID_Y;
    uint cells = grid_cell_count();
    uint2 gi = world_to_cell(world);

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            uint nx = wrap_int(int(gi.x) + ox, grid_x);
            uint ny = wrap_int(int(gi.y) + oy, grid_y);
            uint c = ny * grid_x + nx;
            if (c >= cells) {
                continue;
            }
            uint begin = cell_offsets[c];
            uint end = cell_offsets[c + 1u];
            for (uint k = begin; k < end; ++k) {
                uint j = sorted_indices[k];
                if (j >= BODY_CAPACITY || body_active[j] == 0u) {
                    continue;
                }
                float2 pos = body_pos[j];
                float radius = body_radius[j];
                float softness = max(radius * 0.6f, 0.05f);
                float dist = length(world - pos);
                float coverage = soft_circle(dist, radius, softness);
                if (coverage <= 0.0f) {
                    continue;
                }
                float3 body_col = (j == 0u)
                    ? float3(0.80f, 0.90f, 1.15f)
                    : float3(1.65f, 0.55f, 0.25f);
                color += body_col * coverage * 1.4f;
                density = max(density, coverage);
            }
        }
    }

    color = saturate(color);
    density = saturate(density);

    uint accum_idx = id * 4u;
    accumulation_buffer[accum_idx + 0u] = (uint)(color.r * COLOR_SCALE);
    accumulation_buffer[accum_idx + 1u] = (uint)(color.g * COLOR_SCALE);
    accumulation_buffer[accum_idx + 2u] = (uint)(color.b * COLOR_SCALE);
    accumulation_buffer[accum_idx + 3u] = (uint)(density * COLOR_SCALE);
}

[numthreads(128, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint mode = push_constants.dispatch_mode;

    switch (mode) {
        case DISPATCH_CAMERA_UPDATE: {
            if (tid.x == 0u) {
                update_camera_state(push_constants.delta_time);
                maybe_spawn_circles();
            }
            break;
        }
        case DISPATCH_INITIALIZE: {
            initialize_bodies(tid.x);
            break;
        }
        case DISPATCH_CLEAR_GRID: {
            clear_grid(tid.x);
            break;
        }
        case DISPATCH_INTEGRATE: {
            integrate_predict(tid.x);
            break;
        }
        case DISPATCH_HISTOGRAM: {
            histogram_kernel(tid.x);
            break;
        }
        case DISPATCH_PREFIX_COPY: {
            prefix_copy_kernel(tid.x);
            break;
        }
        case DISPATCH_PREFIX_SCAN: {
            prefix_scan_step(tid.x, push_constants.scan_source, push_constants.scan_offset);
            break;
        }
        case DISPATCH_PREFIX_COPY_SOURCE: {
            prefix_copy_source(tid.x);
            break;
        }
        case DISPATCH_PREFIX_FINALIZE: {
            prefix_finalize_kernel(tid.x, push_constants.scan_source);
            break;
        }
        case DISPATCH_SCATTER: {
            scatter_kernel(tid.x);
            break;
        }
        case DISPATCH_ZERO_DELTAS: {
            zero_deltas(tid.x);
            break;
        }
        case DISPATCH_CONSTRAINTS: {
            constraints_kernel(tid.x);
            break;
        }
        case DISPATCH_APPLY_DELTAS: {
            apply_deltas(tid.x);
            break;
        }
        case DISPATCH_FINALIZE: {
            finalize_kernel(tid.x);
            break;
        }
        case DISPATCH_RENDER: {
            render_kernel(tid.x);
            break;
        }
        default:
            break;
    }
}
