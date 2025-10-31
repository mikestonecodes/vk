// Gameplay-specific body initialization, rendering colors, and per-tick updates.

bool spawn(uint type, float2 position, float2 velocity);
float2 load_body_delta(uint id);
void deactivate_body(uint id);

struct BodyInitData {
    float radius;
    float inv_mass;
};

static const uint BODY_TYPE_COUNT = 3u;

static const float BODY_RADIUS_BY_TYPE[BODY_TYPE_COUNT] = {
    0.0f,            // 0: inactive
    0.20f,           // 1: type-1
    0.20f * 0.9f     // 2: type-2
};

static const float BODY_INV_MASS_BY_TYPE[BODY_TYPE_COUNT] = {
    0.0f,
    1.0f,
    1.0f
};

static const float BODY_MOVE_SPEED_BY_TYPE[BODY_TYPE_COUNT] = {
    0.0f,
    42.0f,           // shooter
    42.0f * 0.65f    // collector drift
};

static const float BODY_ATTRACTION_BY_TYPE[BODY_TYPE_COUNT] = {
    0.0f,
    0.0f,
    42.0f * 0.5f
};

static const float BODY_MAX_SPEED_BY_TYPE[BODY_TYPE_COUNT] = {
    0.0f,
    42.0f,
    42.0f * 1.3f
};

static const uint  START_TYPE2_COUNT      = 500u;
static const uint  MIN_TYPE2_COUNT        = 500u;
static const float TYPE2_READY_DISTANCE   = 6.0f;
static const float TYPE2_SPAWN_RADIUS     = 15.0f;
static const float TYPE1_DESTROY_DISTANCE = 60.0f;

uint clamp_body_type(uint type) { return (type < BODY_TYPE_COUNT) ? type : 0u; }

uint collision_mask(uint type) { return (type == 2u) ? 1u : 0u; }

bool can_collide(uint type_a, uint type_b) {
    return (collision_mask(type_a) & collision_mask(type_b)) != 0u;
}

BodyInitData init(uint type) {
    uint idx = clamp_body_type(type);
    BodyInitData data;
    data.radius = BODY_RADIUS_BY_TYPE[idx];
    data.inv_mass = BODY_INV_MASS_BY_TYPE[idx];
    return data;
}

void apply_body_type(uint id, uint type) {
    BodyInitData config = init(type);
    body_type[id] = type;
    body_radius[id] = config.radius;
    body_inv_mass[id] = config.inv_mass;
}

void ensure_type2_population() {
    GlobalState state = global_state[0];
    uint target = (state.spawn_active == 0u) ? START_TYPE2_COUNT : MIN_TYPE2_COUNT;
    target = max(target, MIN_TYPE2_COUNT);
    if (target == 0u) return;

    uint count = 0u;
    uint capacity = BODY_CAPACITY;
    uint start = DYNAMIC_BODY_START;
    for (uint i = start; i < capacity && count < target; ++i) {
        if (body_type[i] == 2u) ++count;
    }

    if (count >= target) return;

    uint needed = target - count;
    uint seed_base = state.spawn_next;
    for (uint n = 0u; n < needed; ++n) {
        float seed = float(seed_base + n) * 37.137f + push_constants.time;
        float2 random = hash21(float2(seed, seed * 1.37f)) * 2.0f - 1.0f;
        float2 dir = safe_normalize(random, 1.0f);
        float2 position = GAME_START_CENTER + dir * TYPE2_SPAWN_RADIUS;
        float speed = BODY_MOVE_SPEED_BY_TYPE[2u];
        float2 velocity = -dir * speed;
        if (!spawn(2u, position, velocity)) break;
    }
}

bool fire_collector(float2 aim_dir) {
    uint capacity = BODY_CAPACITY;
    uint start = DYNAMIC_BODY_START;
    float ready_radius_sq = TYPE2_READY_DISTANCE * TYPE2_READY_DISTANCE;
    float2 dir = safe_normalize(aim_dir, 1.0f);
    float speed = BODY_MOVE_SPEED_BY_TYPE[1u];

    bool found = false;
    uint candidate = capacity;
    float best_dist_sq = ready_radius_sq;

    for (uint i = start; i < capacity; ++i) {
        if (body_type[i] != 2u) continue;

        float2 offset = body_pos[i] - GAME_START_CENTER;
        float dist_sq = dot(offset, offset);
        if (dist_sq > ready_radius_sq) continue;

        if (!found || dist_sq < best_dist_sq) {
            found = true;
            candidate = i;
            best_dist_sq = dist_sq;
        }
    }

    if (!found || candidate >= capacity) return false;

    apply_body_type(candidate, 1u);
    body_pos[candidate] = GAME_START_CENTER;
    body_pos_pred[candidate] = GAME_START_CENTER;
    body_vel[candidate] = dir * speed;
    store_body_delta(candidate, float2(0.0f, 0.0f));

    return true;
}

struct BodyRenderData {
    float3 color;
    float intensity;
};

BodyRenderData render(uint id, uint type) {
    BodyRenderData data;
    data.color = float3(0.40f, 0.45f, 0.55f);
    data.intensity = 0.0f;
    if (type == 1u) {
        data.color = float3(0.65f, 0.55f, 0.25f);
        data.intensity = 0.9f;
    } else if (type == 2u) {
        data.color = float3(0.85f, 0.15f, 3.15f);
        data.intensity = 0.1f;
    }

    float signal = length(load_body_delta(id));
    if (signal > 0.0f) {
        float flash = saturate(signal * 10.0f);
        const float3 collision_color = float3(3.0f, 0.2f, 0.2f);
        data.color = lerp(data.color, collision_color, flash);
        data.intensity = max(data.intensity, flash);
    }
    return data;
}

void begin() {
    ensure_type2_population();

    GlobalState state = global_state[0];
    bool pressed = (push_constants.spawn_body != 0u);
    if (pressed) {
        float2 spawn_position = GAME_START_CENTER;
        float2 uv = float2(push_constants.mouse_ndc_x, push_constants.mouse_ndc_y);
        float2 pointer_world = uv_to_world(uv);
        float2 aim_dir = safe_normalize(pointer_world - spawn_position, 1.0f);

        fire_collector(aim_dir);
    }

    state.fire_button_prev = pressed ? 1u : 0u;
    global_state[0] = state;
}

void update(uint id, float dt) {

    uint type = body_type[id];
    if (type == 0u) return;

    float2 vel = body_vel[id];
    switch (type) {
        case 1u: {
            uint idx = clamp_body_type(type);
            float speed = length(vel);
            float target_speed = BODY_MOVE_SPEED_BY_TYPE[idx];
            if (speed > 1e-5f) {
                float blend = saturate(dt * 2.5f);
                float new_speed = lerp(speed, target_speed, blend);
                vel *= new_speed / max(speed, 1e-5f);
            } else {
                vel = float2(target_speed, 0.0f);
            }
            body_vel[id] = vel;

            float dist = length(body_pos[id] - GAME_START_CENTER);
            if (dist > TYPE1_DESTROY_DISTANCE) {
                deactivate_body(id);
                return;
            }
            break;
        }
        case 2u: {
            float2 to_target = GAME_START_CENTER - body_pos[id];
            float2 accel_dir = safe_normalize(to_target, 1.0f);
            vel += accel_dir * (BODY_ATTRACTION_BY_TYPE[2u] * dt);
            float speed = length(vel);
            float max_speed = BODY_MAX_SPEED_BY_TYPE[2u];
            if (speed > max_speed) {
                vel *= max_speed / max(speed, 1e-5f);
            }

            float dist = length(to_target);
            if (dist < TYPE2_READY_DISTANCE) {
                float blend = saturate(dt * 4.0f);
                body_pos[id] = lerp(body_pos[id], GAME_START_CENTER, blend);
                vel *= 0.25f;
            }

            body_vel[id] = vel;
            break;
        }
        default:
            break;
    }
}

void collision_callback(uint a, uint b, float2 normal, float penetration) {
    if (penetration <= 0.0f || a >= BODY_CAPACITY || b >= BODY_CAPACITY) return;

    uint type_a = body_type[a];
    uint type_b = body_type[b];
    if (type_a == 0u || type_b == 0u) return;
    if (!can_collide(type_a, type_b)) return;

    if (body_inv_mass[a] <= 0.0f && body_inv_mass[b] <= 0.0f) return;
}
