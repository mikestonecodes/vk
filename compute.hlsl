static const float COLOR_SCALE = 4096.0f;
static const float CAMERA_DEFAULT_ZOOM = 5.0f;
static const float CAMERA_MOVE_SPEED   = 40.0f;
static const float CAMERA_MIN_ZOOM     = 2.0f;
static const float CAMERA_MAX_ZOOM     = 5000.0f;
static const float CAMERA_ZOOM_RATE    = 2.2f;
static const float CAMERA_FAST_SCALE   = 2.4f;

static const uint  PHYS_PROJECTILE_START = 1u;
static const float CELL_SIZE = 2.0f;
static const float WORLD_RANGE_LIMIT = 1e6f;
static const uint  MAX_EXPLOSIONS = 256u;
static const uint  MAX_CHAIN_EVENTS = 128u;
static const uint  MAX_ACTIVE_PROJECTILES = 25000u;
static const float EXPLOSION_LIFETIME = 1.0f;

static const uint  BODY_CAPACITY = 512000u;
static const uint  GRID_X = 512u;
static const uint  GRID_Y = 512u;
static const uint  PROJECTILE_POOL = 60000u;
static const float PROJECTILE_SPEED = 42.0f;
static const float PROJECTILE_RADIUS = 0.20f;
static const float PROJECTILE_MAX_DISTANCE = 450.0f;
static const float PLAYER_RADIUS = 0.65f;
static const float PLAYER_DAMPING = 0.02f;
static const float RELAXATION = 1.0f;
static const float DT_CLAMP = 1.0f / 30.0f;
static const uint  PHYS_SUBSTEPS = 1u;

// GPU physics compute pipeline
struct ComputePushConstants {
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
    uint  dispatch_mode;
    uint  scan_offset;
    uint  scan_source;
    uint  spawn_projectile;
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

[[vk::binding(0, 0)]] RWStructuredBuffer<uint> accumulation_buffer;
[[vk::binding(3, 0)]] RWStructuredBuffer<CameraStateData> camera_state;

[[vk::binding(20, 0)]] RWStructuredBuffer<float2> body_pos;
[[vk::binding(21, 0)]] RWStructuredBuffer<float2> body_pos_pred;
[[vk::binding(22, 0)]] RWStructuredBuffer<float2> body_vel;
[[vk::binding(23, 0)]] RWStructuredBuffer<float>  body_radius;
[[vk::binding(24, 0)]] RWStructuredBuffer<float>  body_inv_mass;
[[vk::binding(25, 0)]] RWStructuredBuffer<uint>   body_active;
[[vk::binding(26, 0)]] RWStructuredBuffer<int2> body_delta_accum;

struct ExplosionEvent {
    float2 center;
    float  radius;
    float  energy;
    float  start_time;
    uint   target_id;
    uint   processed;
    uint   reserved0;
    uint   reserved1;
};

struct SpawnState {
    uint next_projectile;
    uint next_explosion;
    uint explosion_head;
    uint active_projectiles;
    ExplosionEvent events[MAX_EXPLOSIONS];
};
[[vk::binding(27, 0)]] RWStructuredBuffer<SpawnState> spawn_state;

[[vk::binding(30, 0)]] RWStructuredBuffer<uint> cell_counts;
[[vk::binding(31, 0)]] RWStructuredBuffer<uint> cell_offsets;
[[vk::binding(32, 0)]] RWStructuredBuffer<uint> cell_scratch;
[[vk::binding(33, 0)]] RWStructuredBuffer<uint> sorted_indices;

static const float DELTA_SCALE = 32768.0f;

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

static const uint DISPATCH_CAMERA_UPDATE        = 0u;
static const uint DISPATCH_INITIALIZE           = 1u;
static const uint DISPATCH_CLEAR_GRID           = 2u;
static const uint DISPATCH_SPAWN_PROJECTILE     = 3u;
static const uint DISPATCH_INTEGRATE            = 4u;
static const uint DISPATCH_HISTOGRAM            = 5u;
static const uint DISPATCH_PREFIX_COPY          = 6u;
static const uint DISPATCH_PREFIX_SCAN          = 7u;
static const uint DISPATCH_PREFIX_COPY_SOURCE   = 8u;
static const uint DISPATCH_PREFIX_FINALIZE      = 9u;
static const uint DISPATCH_SCATTER              = 10u;
static const uint DISPATCH_ZERO_DELTAS          = 11u;
static const uint DISPATCH_CONSTRAINTS          = 12u;
static const uint DISPATCH_APPLY_DELTAS         = 13u;
static const uint DISPATCH_FINALIZE             = 14u;
static const uint DISPATCH_RENDER               = 15u;

CameraStateData load_camera_state() {
    CameraStateData state = camera_state[0];
    bool invalid = !all(isfinite(state.position)) || !isfinite(state.zoom) || state.zoom <= 0.0f;
    if (invalid) {
        state.position = float2(0.0f, 0.0f);
        state.zoom = CAMERA_DEFAULT_ZOOM;
    }
    state.padding = 0.0f;
    if (invalid) {
        camera_state[0] = state;
    }
    return state;
}

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

struct WorldCircle {
    float2 center;
    float  radius;
    float  softness;
    float3 color;
    float  energy;
};

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

float2 safe_normalize(float2 v, float fallback_x) {
    float len_sq = dot(v, v);
    if (len_sq <= 1e-12f) {
        return float2(fallback_x, sqrt(1.0f - fallback_x * fallback_x));
    }
    return v * rsqrt(len_sq);
}

uint grid_cell_count() {
    return GRID_X * GRID_Y;
}

void record_explosion_event(float2 center, float radius, float energy, float start_time, uint target_id) {
    uint original_index;
    InterlockedAdd(spawn_state[0].next_explosion, 1u, original_index);

    uint slot = original_index % MAX_EXPLOSIONS;

    ExplosionEvent ev;
    ev.center = center;
    ev.radius = radius;
    ev.energy = max(energy, 0.0f);
    ev.start_time = start_time;
    ev.target_id = target_id;
    ev.processed = 0u;
    ev.reserved0 = 0u;
    ev.reserved1 = 0u;
    spawn_state[0].events[slot] = ev;
}

void deactivate_body(uint id) {
    if (id >= BODY_CAPACITY) {
        return;
    }
    uint state = body_active[id];
    if (state == 0u) {
        return;
    }

    if (id >= PHYS_PROJECTILE_START) {
        uint active = spawn_state[0].active_projectiles;
        if (active > 0u) {
            spawn_state[0].active_projectiles = active - 1u;
        }
    }

    float2 current = body_pos_pred[id];
    body_active[id] = 0u;
    body_pos[id] = current;
    body_pos_pred[id] = current;
    body_vel[id] = float2(0.0f, 0.0f);
    store_body_delta(id, float2(0.0f, 0.0f));
}

void trigger_projectile_explosion(uint source_id, float2 circle_center, float circle_radius, float circle_energy) {
    if (source_id == 0u) {
        return;
    }
    if (source_id < BODY_CAPACITY && body_active[source_id] >= 2u) {
        return;
    }
    float base_radius = max(circle_radius, PROJECTILE_RADIUS);
    float energy = max(circle_energy, 0.2f);
    record_explosion_event(circle_center, base_radius, energy, push_constants.time, source_id);
    if (source_id < BODY_CAPACITY && body_active[source_id] != 0u) {
        body_active[source_id] = 2u; // Mark as pending explosion
    }
}


void initialize_bodies(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) {
        if (id == 0) {
            spawn_state[0].next_projectile = 0u;
            spawn_state[0].next_explosion = 0u;
            spawn_state[0].explosion_head = 0u;
            spawn_state[0].active_projectiles = 0u;
        }
        return;
    }

    bool is_player = (id == 0u);
    body_active[id] = is_player ? 1u : 0u;
    body_radius[id] = is_player ? PLAYER_RADIUS : PROJECTILE_RADIUS;
    body_inv_mass[id] = is_player ? 0.0f : 1.0f;
    body_pos[id] = float2(0.0f, 0.0f);
    body_pos_pred[id] = body_pos[id];
    body_vel[id] = float2(0.0f, 0.0f);
    store_body_delta(id, float2(0.0f, 0.0f));

    if (id == 0u) {
        spawn_state[0].next_projectile = 0u;
        spawn_state[0].next_explosion = 0u;
        spawn_state[0].explosion_head = 0u;
        spawn_state[0].active_projectiles = 0u;
        for (uint e = 0u; e < MAX_EXPLOSIONS; ++e) {
            spawn_state[0].events[e].center = float2(0.0f, 0.0f);
            spawn_state[0].events[e].radius = 0.0f;
            spawn_state[0].events[e].energy = 0.0f;
            spawn_state[0].events[e].start_time = 0.0f;
            spawn_state[0].events[e].target_id = 0u;
            spawn_state[0].events[e].processed = 1u;
            spawn_state[0].events[e].reserved0 = 0u;
            spawn_state[0].events[e].reserved1 = 0u;
        }
    }
}

void clear_grid(uint id) {
    uint cells = grid_cell_count();
    if (id >= cells) {
        return;
    }
    cell_counts[id] = 0u;
    cell_scratch[id] = 0u;
}

void spawn_projectile_kernel(uint id) {
    if (id != 0u || push_constants.spawn_projectile == 0u) {
        return;
    }

    uint capacity = BODY_CAPACITY;
    if (capacity <= PHYS_PROJECTILE_START) {
        return;
    }

    uint pool = PROJECTILE_POOL;
    pool = min(pool, capacity - PHYS_PROJECTILE_START);
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
    uint active_current = spawn_state[0].active_projectiles;
    if (active_current >= MAX_ACTIVE_PROJECTILES) {
        return;
    }

    uint spawn_budget = min(SPAWN_BATCH, MAX_ACTIVE_PROJECTILES - active_current);
    if (spawn_budget == 0u) {
        return;
    }

    for (uint n = 0u; n < spawn_budget; ++n) {
        uint next_index;
        InterlockedAdd(spawn_state[0].next_projectile, 1u, next_index);
        uint slot = PHYS_PROJECTILE_START + (next_index % pool);
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
        float spawn_offset = PLAYER_RADIUS + PROJECTILE_RADIUS + 0.05f + jitter * 0.1f;
        float2 spawn_pos = root + rotated * spawn_offset;
        float2 velocity = rotated * (PROJECTILE_SPEED * spread);

        body_active[slot] = 1u;
        body_radius[slot] = PROJECTILE_RADIUS;
        body_inv_mass[slot] = 1.0f;
        body_pos[slot] = spawn_pos;
        body_pos_pred[slot] = spawn_pos;
        body_vel[slot] = velocity;
        store_body_delta(slot, float2(0.0f, 0.0f));
    }

    spawn_state[0].active_projectiles = active_current + spawn_budget;
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
            if (id >= PHYS_PROJECTILE_START) {
                trigger_projectile_explosion(id, circle_center, circle_radius, circle_energy);
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
    float max_shift = PROJECTILE_RADIUS * 2.0f + PLAYER_RADIUS;
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
    float damping = saturate(1.0f - PLAYER_DAMPING);
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

    if (id >= PHYS_PROJECTILE_START && inv_mass > 0.0f) {
        float dist_sq = dot(x1, x1);
        float limit = PROJECTILE_MAX_DISTANCE;
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
        circle.radius = PLAYER_RADIUS;
        circle.softness = circle.radius * 0.5f;
        circle.color = float3(0.85f, 0.90f, 0.98f);
        circle.energy = 0.65f;
        float dist = length(world - circle.center);
        float coverage = soft_circle(dist, circle.radius, circle.softness);
        color += circle.color * circle.energy * coverage;
        density = max(density, coverage);
    }

    // Explosion glow
    for (uint ei = 0u; ei < MAX_EXPLOSIONS; ++ei) {
        ExplosionEvent ev = spawn_state[0].events[ei];
        float born_time = ev.start_time;
        float age = push_constants.time - born_time;
        if (ev.processed == 0u) {
            if (age < 0.0f) {
                continue;
            }
        }
        if (age < 0.0f || age > EXPLOSION_LIFETIME) {
            continue;
        }

        float2 center = ev.center;
        float base_radius = ev.radius;
        float energy = max(ev.energy, 0.1f);

        float progress = saturate(age / EXPLOSION_LIFETIME);
        float expansion = lerp(0.35f, 1.05f + energy * 0.15f, progress);
        float current_radius = base_radius * expansion + age * (0.45f + energy * 0.18f);
        float thickness = max(base_radius * (0.1f + energy * 0.025f), 0.1f);

        float dist = length(world - center);
        float ring = saturate(1.0f - abs(dist - current_radius) / (thickness * 1.25f));
        float glow = saturate(1.0f - dist / (current_radius + thickness * 2.0f));
        float intensity = (1.0f - progress) * (0.35f + energy * 0.18f);

        if (ring <= 0.0f && glow <= 0.0f) {
            continue;
        }

        float3 inner_color = float3(1.25f, 0.65f, 0.35f);
        float3 outer_color = float3(0.5f, 0.22f, 1.1f);
        float3 explosion_color = lerp(inner_color, outer_color, progress);

        float contribution = min(ring * 0.45f + glow * 0.12f, 0.5f) * intensity;
        color = lerp(color, explosion_color, saturate(contribution));
        density = max(density, contribution * 0.5f);
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

    color *= push_constants.brightness;
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
        case DISPATCH_SPAWN_PROJECTILE: {
            spawn_projectile_kernel(tid.x);
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
