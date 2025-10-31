// Gameplay-specific body initialization, rendering colors, and per-tick updates.

bool spawn(uint type, float2 position, float2 velocity);
float2 load_body_delta(uint id);

struct BodyInitData {
    float radius;
    float inv_mass;
};

static const float BODY_RADIUS_BY_TYPE[3] = {
    0.20f,
    0.20f,
    0.20f * 0.9f
};

static const float BODY_INV_MASS_BY_TYPE[3] = {
    0.0f,
    1.0f,
    1.0f
};

static const float BODY_MOVE_SPEED_BY_TYPE[3] = {
    0.0f,
    92.0f,
    42.0f * 0.65f
};

static const float BODY_ATTRACTION_BY_TYPE[3] = {
    0.0f,
    0.0f,
    42.0f * 0.5f
};

static const float BODY_MAX_SPEED_BY_TYPE[3] = {
    0.0f,
    42.0f,
    42.0f * 1.3f
};

uint clamp_body_type(uint type) { return (type < 3u) ? type : 0u; }

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
    if (push_constants.spawn_body == 0u) return;

    GlobalState state = global_state[0];
    float seed = float(state.spawn_next) * 41.239f + push_constants.time * 13.73f;
    uint spawn_type = (hash11(seed) > 0.5f) ? 1u : 2u;
    uint spawn_idx = clamp_body_type(spawn_type);

    float speed = BODY_MOVE_SPEED_BY_TYPE[spawn_idx];
    float2 spawn_position = GAME_START_CENTER;
    float2 uv = float2(push_constants.mouse_ndc_x, push_constants.mouse_ndc_y);
    float2 pointer_world = uv_to_world(uv);
    float2 aim_dir = safe_normalize(pointer_world - spawn_position, 1.0f);

    spawn(spawn_type, spawn_position, aim_dir * speed);
}

void update(uint id, float dt) {

    uint type = body_type[id];
    if (type == 0u) return;

    float2 vel = body_vel[id];
    switch (type) {
        case 1u: {
            float speed = length(vel);
            float target_speed = BODY_MOVE_SPEED_BY_TYPE[1u];
            if (speed > 1e-5f) {
                float blend = saturate(dt * 2.5f);
                float new_speed = lerp(speed, target_speed, blend);
                vel *= new_speed / max(speed, 1e-5f);
            } else {
                vel = float2(target_speed, 0.0f);
            }
            body_vel[id] = vel;
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
