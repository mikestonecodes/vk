// Gameplay-specific body initialization, rendering colors, and per-tick updates.

bool spawn(uint type, float2 position, float2 velocity);
float2 load_body_delta(uint id);

struct BodyInitData {
    float radius;
    float inv_mass;
};

uint collision_mask(uint type) {
    return (type == 2u) ? 1u : 0u;
}

bool can_collide(uint type_a, uint type_b) {
    return (collision_mask(type_a) & collision_mask(type_b)) != 0u;
}

BodyInitData init(uint type) {
    BodyInitData data;
    switch (type) {
        case 1u: {
            data.radius = DYNAMIC_BODY_RADIUS;
            data.inv_mass = 1.0f;
            break;
        }
        case 2u: {
            data.radius = DYNAMIC_BODY_RADIUS * 0.9f;
            data.inv_mass = 1.0f;
            break;
        }
        default: {
            data.radius = DYNAMIC_BODY_RADIUS;
            data.inv_mass = 0.0f;
            break;
        }
    }
    return data;
}

struct BodyRenderData {
    float3 color;
    float intensity;
};

BodyRenderData render(uint id, uint type) {
    BodyRenderData data;
    switch (type) {
        case 1u: {
            data.color = float3(0.65f, 0.55f, 0.25f);
            data.intensity = 0.9f;
            break;
        }
        case 2u: {
            data.color = float3(0.85f, 0.15f, 3.15f);
            data.intensity = 0.1f;
            break;
        }
        default: {
            data.color = float3(0.40f, 0.45f, 0.55f);
            data.intensity = 0.0f;
            break;
        }
    }

    float2 delta = load_body_delta(id);
    float signal = length(delta);
    if (signal > 0.0f) {
        float flash = saturate(signal * 10.0f);
        float3 collision_color = float3(3.0f, 0.2f, 0.2f);
        data.color = lerp(data.color, collision_color, flash);
        data.intensity = max(data.intensity, flash);
    }
    return data;
}

void begin(){
	if (push_constants.spawn_body != 0u) {
		GlobalState state = global_state[0];
		float seed = float(state.spawn_next) * 41.239f + push_constants.time * 13.73f;
		float type_choice = hash11(seed);
		uint spawn_type = (type_choice > 0.5f) ? 1u : 2u;

		float angle_rand = hash11(seed + 37.342f);
		float angle = angle_rand * 6.2831853f;
		float2 dir = float2(cos(angle), sin(angle));

		float base_speed = DYNAMIC_BODY_SPEED;
		float speed = (spawn_type == 1u) ? base_speed : base_speed * 0.65f;
		float2 spawn_velocity = dir * speed;

		float2 spawn_position = camera_pos();
		spawn(spawn_type, spawn_position, spawn_velocity);
	}
}

void update(uint id, float dt) {

    uint type = body_type[id];
    if (type == 0u) return;

    float2 vel = body_vel[id];
    switch (type) {
        case 1u: {
            float speed = length(vel);
            float target_speed = DYNAMIC_BODY_SPEED;
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
            float2 cam = camera_pos();
            float2 to_camera = cam - body_pos[id];
            float2 accel_dir = safe_normalize(to_camera, 1.0f);
            float attraction = DYNAMIC_BODY_SPEED * 0.5f;
            vel += accel_dir * (attraction * dt);
            float max_speed = DYNAMIC_BODY_SPEED * 1.3f;
            float speed = length(vel);
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
    if (penetration <= 0.0f) return;
    if (a >= BODY_CAPACITY || b >= BODY_CAPACITY) return;

    uint type_a = body_type[a];
    uint type_b = body_type[b];
    if (type_a == 0u || type_b == 0u) return;
    if (!can_collide(type_a, type_b)) return;

    float weight_a = body_inv_mass[a];
    float weight_b = body_inv_mass[b];
    if (weight_a <= 0.0f && weight_b <= 0.0f) return;

    float2 impulse = normal * penetration * 0.5f;

    if (weight_a > 0.0f) {
 //       atomic_add_body_delta(a, -impulse);
    }
    if (weight_b > 0.0f) {
  //      atomic_add_body_delta(b, impulse);
    }
}
