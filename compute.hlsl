// ============================================================================
// GLOBAL CONSTANTS
// ============================================================================

static const float COLOR_SCALE = 4096.0f;

static const float CAMERA_DEFAULT_ZOOM = 3.0f;
static const float CAMERA_MOVE_SPEED   = 40.0f;
static const float CAMERA_MIN_ZOOM     = 2.0f;
static const float CAMERA_MAX_ZOOM     = 5000.0f;
static const float CAMERA_ZOOM_RATE    = 2.2f;
static const float CAMERA_FAST_SCALE   = 2.4f;

static const float CELL_SIZE = 5.0f;

static const uint DYNAMIC_BODY_START     = 1u;
static const uint MAX_ACTIVE_DYNAMIC     = 25000u;
static const uint DYNAMIC_BODY_POOL      = 60000u;

static const uint BODY_CAPACITY = 512000u;
static const uint GRID_X        = 512u;
static const uint GRID_Y        = 512u;

static const float DYNAMIC_BODY_SPEED        = 42.0f;
static const float DYNAMIC_BODY_RADIUS       = 0.20f;
static const float DYNAMIC_BODY_MAX_DISTANCE = 99950.0f;
static const float BODY_DAMPING  = 0.02f;
static const float RELAXATION    = 1.0f;
static const float DT_CLAMP      = (1.0f / 30.0f);
static const uint  PHYS_SUBSTEPS = 1u;

static const float  DELTA_SCALE       = 332768.0f;
static const float2 GAME_START_CENTER = float2(float(GRID_X * CELL_SIZE) * 0.5f, float(GRID_Y * CELL_SIZE) * 0.5f);

// ============================================================================
// STRUCTS & BUFFERS
// ============================================================================

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
    uint  spawn_body;
    float mouse_ndc_x;
    float mouse_ndc_y;
    uint  pad0;
    uint  pad1;
};
[[vk::push_constant]] ComputePushConstants push_constants;

struct GlobalState {
    float2 camera_position;
    float  camera_zoom;
    float  _pad0;
    uint   spawn_next;
    uint   spawn_active;
    uint   _pad1;
    uint   _pad2;
};
struct WorldBody { float2 center; float radius; float softness; float3 color; float energy; };

[[vk::binding(0, 0)]]  RWStructuredBuffer<uint> accumulation_buffer;
[[vk::binding(3, 0)]]  RWStructuredBuffer<GlobalState> global_state;
[[vk::binding(20, 0)]] RWStructuredBuffer<float2> body_pos;
[[vk::binding(21, 0)]] RWStructuredBuffer<float2> body_pos_pred;
[[vk::binding(22, 0)]] RWStructuredBuffer<float2> body_vel;
[[vk::binding(23, 0)]] RWStructuredBuffer<float>  body_radius;
[[vk::binding(24, 0)]] RWStructuredBuffer<float>  body_inv_mass;
[[vk::binding(25, 0)]] RWStructuredBuffer<uint>   body_type;
[[vk::binding(26, 0)]] RWStructuredBuffer<int2>   body_delta_accum;
[[vk::binding(30, 0)]] RWStructuredBuffer<uint> cell_counts;
[[vk::binding(31, 0)]] RWStructuredBuffer<uint> cell_offsets;
[[vk::binding(32, 0)]] RWStructuredBuffer<uint> cell_scratch;
[[vk::binding(33, 0)]] RWStructuredBuffer<uint> sorted_indices;



// ============================================================================
// === UTILS ===
// ============================================================================

// --- Hash & Noise ---
float hash11(float n) {
    return frac(sin(n) * 1343758.5453123f);
}
float2 hash21(float2 p) {
    return float2(hash11(dot(p, float2(127.1f, 311.7f))),
                  hash11(dot(p, float2(269.5f, 183.3f))));
}
float3 hash31(float2 p) {
    return float3(hash11(dot(p, float2(12.9898f, 78.233f))),
                  hash11(dot(p, float2(93.9898f, 67.345f))),
                  hash11(dot(p, float2(45.332f, 11.135f))));
}

// --- Math helpers ---
float soft_circle(float distance, float radius, float softness) {
    float inner = max(radius - softness, 0.0001f);
    return saturate(1.0f - smoothstep(inner, radius, distance));
}
float2 safe_normalize(float2 v, float fallback_x) {
    float len_sq = dot(v, v);
    if (len_sq <= 1e-12f)
        return float2(fallback_x, sqrt(1.0f - fallback_x * fallback_x));
    return v * rsqrt(len_sq);
}
// --- Grid Helpers ---
uint wrap_int(int value, uint size_value) {
    return uint(clamp(value, 0, int(size_value - 1)));
}
uint2 world_to_cell(float2 p) {
    float inv_cell = 1.0f / CELL_SIZE;
    int gx = int(floor(p.x * inv_cell));
    int gy = int(floor(p.y * inv_cell));
    return uint2(wrap_int(gx, GRID_X), wrap_int(gy, GRID_Y));
}
uint cell_index(uint2 g) { return g.y * GRID_X + g.x; }
uint grid_cell_count() { return GRID_X * GRID_Y; }


// --- Delta Encoding ---
int float_to_delta(float value) { return int(clamp(value * DELTA_SCALE, -214748000.0f, 214748000.0f)); }
float delta_to_float(int value) { return float(value) / DELTA_SCALE; }

void store_body_delta(uint id, float2 v) {
    body_delta_accum[id] = int2(float_to_delta(v.x), float_to_delta(v.y));
}
float2 load_body_delta(uint id) {
    int2 p = body_delta_accum[id];
    return float2(delta_to_float(p.x), delta_to_float(p.y));
}
void atomic_add_body_delta(uint id, float2 v) {
    int ix = float_to_delta(v.x), iy = float_to_delta(v.y);
    if (ix != 0) InterlockedAdd(body_delta_accum[id].x, ix);
    if (iy != 0) InterlockedAdd(body_delta_accum[id].y, iy);
}

// Shared helper for setting up body state for spawns and resets.
void init_body(uint slot, uint type, float radius, float inv_mass, float2 position, float2 velocity) {
    body_type[slot] = type;
    body_radius[slot] = radius;
    body_inv_mass[slot] = inv_mass;
    body_pos[slot] = position;
    body_pos_pred[slot] = position;
    body_vel[slot] = velocity;
    store_body_delta(slot, float2(0.0f, 0.0f));
}

float2 camera_pos()  { return global_state[0].camera_position; }
float  camera_zoom() { return global_state[0].camera_zoom; }

// Camera-space helpers shared by gameplay and rendering code.
float safe_camera_zoom() { return max(camera_zoom(), CAMERA_MIN_ZOOM); }

float2 screen_resolution() {
    return float2(max(float(push_constants.screen_width), 1.0f),
                  max(float(push_constants.screen_height), 1.0f));
}

float aspect_ratio() {
    float2 resolution = screen_resolution();
    return resolution.x / resolution.y;
}

float2 view_from_uv(float2 uv) {
    float2 view = uv * 2.0f - 1.0f;
    view.x *= aspect_ratio();
    return view;
}

float2 uv_to_world(float2 uv) {
    return camera_pos() + view_from_uv(uv) * safe_camera_zoom();
}

float2 pixel_center_uv(uint id, uint width, uint height) {
    uint safe_width = max(width, 1u);
    uint safe_height = max(height, 1u);
    float2 dims = float2(float(safe_width), float(safe_height));
    float2 pixel = float2(float(id % safe_width), float(id / safe_width));
    return (pixel + 0.5f) / dims;
}

#include "game.hlsl"

bool spawn(uint type, float2 position, float2 velocity) {
    if (type == 0u) return false;

    uint capacity = BODY_CAPACITY;
    if (capacity <= DYNAMIC_BODY_START) return false;

    GlobalState state = global_state[0];

    uint pool = min(DYNAMIC_BODY_POOL, capacity - DYNAMIC_BODY_START);
    if (pool == 0u) return false;
    if (state.spawn_active >= MAX_ACTIVE_DYNAMIC) return false;

    uint next_index = state.spawn_next;
    uint slot = DYNAMIC_BODY_START + (next_index % pool);
    if (slot >= capacity) slot = capacity - 1u;

    BodyInitData config = init(type);
    if (config.inv_mass <= 0.0f) return false;

    bool was_inactive = (body_type[slot] == 0u);

    init_body(slot, type, config.radius, config.inv_mass, position, velocity);

    state.spawn_next = next_index + 1u;
    if (was_inactive && state.spawn_active < MAX_ACTIVE_DYNAMIC) {
        state.spawn_active += 1u;
    }
    global_state[0] = state;

    return true;
}

// ============================================================================
// === DISPATCH KERNELS ===
// ============================================================================


// (0) INIT FRAME / CAMERA UPDATE + SPAWN

void update_camera_state(float delta_time) {
    if (delta_time <= 0.0f) delta_time = 0.0f;

    GlobalState state = global_state[0];

    if (state.camera_zoom <= 0.0f) {
        state.camera_position = GAME_START_CENTER;
        state.camera_zoom = CAMERA_DEFAULT_ZOOM;
    }

    if (push_constants.reset_camera != 0u) {
        state.camera_position = GAME_START_CENTER;
        state.camera_zoom = CAMERA_DEFAULT_ZOOM;
        global_state[0] = state;
        return;
    }

    float2 move = float2(0.0f, 0.0f);
    if (push_constants.move_forward != 0u)  move.y += 1.0f;
    if (push_constants.move_backward != 0u) move.y -= 1.0f;
    if (push_constants.move_right != 0u)    move.x += 1.0f;
    if (push_constants.move_left != 0u)     move.x -= 1.0f;

    if (dot(move, move) > 0.0f) move = normalize(move);

    float zoom_ratio = clamp(state.camera_zoom / CAMERA_DEFAULT_ZOOM, 0.25f, 12.0f);
    float move_speed = CAMERA_MOVE_SPEED * zoom_ratio;
    bool fast = (push_constants.speed != 0u);
    if (fast) move_speed *= CAMERA_FAST_SCALE;

    state.camera_position += move * move_speed * delta_time;

    float zoom_rate = CAMERA_ZOOM_RATE;
    if (fast) zoom_rate *= CAMERA_FAST_SCALE;

    if (push_constants.zoom_out != 0u)
        state.camera_zoom -= state.camera_zoom * zoom_rate * delta_time;
    if (push_constants.zoom_in != 0u)
        state.camera_zoom += state.camera_zoom * zoom_rate * delta_time;

    state.camera_zoom = clamp(state.camera_zoom, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM);
    global_state[0] = state;
}


void begin_frame(uint id) {
    if (id != 0u) return;
    begin();
    update_camera_state(push_constants.delta_time);
}


// (1) INITIALIZE BODIES
void initialize_bodies(uint id) {
    if (id == 0u) {
        GlobalState state = global_state[0];
        state.spawn_next = 0u;
        state.spawn_active = 0u;
        global_state[0] = state;
    }
    init_body(id, 0u, DYNAMIC_BODY_RADIUS, 1.0f, float2(0.0f, 0.0f), float2(0.0f, 0.0f));
}


// (2) CLEAR GRID
void clear_grid(uint id) {
    cell_counts[id] = 0u;
    cell_scratch[id] = 0u;
}


// (3) INTEGRATE PREDICT
void integrate_predict(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;

    float dt = min(push_constants.delta_time, DT_CLAMP);
    dt = max(dt, 0.0f);
    if (PHYS_SUBSTEPS > 1u) dt /= float(PHYS_SUBSTEPS);

    update(id, dt);

    if (body_type[id] == 0u) return;

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


// (4) HISTOGRAM
void histogram_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;
    if (body_type[id] == 0u) return;

    float2 pos = body_pos_pred[id];
    if (!all(isfinite(pos))) return;

    uint2 cell = world_to_cell(pos);
    uint index = cell_index(cell);
    InterlockedAdd(cell_counts[index], 1u);
}


// (5) PREFIX COPY
void prefix_copy_kernel(uint id) {
    uint cells = grid_cell_count();
    if (id >= cells) return;
    uint count = cell_counts[id];
    cell_offsets[id] = count;
    cell_scratch[id] = 0u;
    if (id == 0u) {
        cell_offsets[cells] = 0u;
    }
}


// (6) PREFIX SCAN STEP
void prefix_scan_step(uint id, uint source, uint offset) {
    if (offset == 0u) return;
    uint cells = grid_cell_count();
    if (id >= cells) return;

    bool src_is_offsets = (source == 0u);
    uint value = src_is_offsets ? cell_offsets[id] : cell_scratch[id];
    if (id >= offset) {
        uint addend = src_is_offsets ? cell_offsets[id - offset] : cell_scratch[id - offset];
        value += addend;
    }

    if (src_is_offsets) cell_scratch[id] = value;
    else cell_offsets[id] = value;
}


// (7) PREFIX COPY SOURCE
void prefix_copy_source(uint id) {
    uint cells = grid_cell_count();
    if (id >= cells) return;
    cell_scratch[id] = cell_offsets[id];
}


// (8) PREFIX FINALIZE
void prefix_finalize_kernel(uint id, uint source) {
    uint cells = grid_cell_count();
    if (cells == 0u) return;

    bool src_is_offsets = (source == 0u);

    if (id < cells) {
        uint inclusive_prev = (id == 0u)
            ? 0u
            : (src_is_offsets ? cell_offsets[id - 1u] : cell_scratch[id - 1u]);
        cell_offsets[id] = inclusive_prev;
        cell_scratch[id] = 0u;
    }

    if (id == 0u) {
        uint last_inclusive = src_is_offsets
            ? cell_offsets[cells - 1u]
            : cell_scratch[cells - 1u];
        cell_offsets[cells] = last_inclusive;
    }
}


// (9) SCATTER
void scatter_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;
    if (body_type[id] == 0u) return;

    float2 pos = body_pos_pred[id];
    if (!all(isfinite(pos))) return;

    uint2 cell = world_to_cell(pos);
    uint idx = cell_index(cell);
    uint base = cell_offsets[idx];
    uint offset;
    InterlockedAdd(cell_scratch[idx], 1u, offset);
    uint write_index = base + offset;

    if (write_index < capacity) sorted_indices[write_index] = id;
}


// (10) ZERO DELTAS
void zero_deltas(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;
    if (body_type[id] == 0u) return;
    store_body_delta(id, float2(0.0f, 0.0f));
}


// (11) CONSTRAINTS

// --- World collision query (against static cells) ---

void constraints_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;
    uint type_i = body_type[id];
    if (type_i == 0u) return;

    uint mask_i = collision_mask(type_i);
    if (mask_i == 0u) return;

    float2 xi = body_pos_pred[id];
    float  ri = body_radius[id];
    float  wi = body_inv_mass[id];

    if (!all(isfinite(xi))) return;

    uint2 gi = world_to_cell(xi);
    uint cells = grid_cell_count();

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            uint nx = wrap_int(int(gi.x) + ox, GRID_X);
            uint ny = wrap_int(int(gi.y) + oy, GRID_Y);
            uint2 neighbor = uint2(nx, ny);
            uint c = cell_index(neighbor);
            if (c >= cells) continue;
            uint begin = cell_offsets[c];
            uint end = cell_offsets[c + 1u];
            for (uint k = begin; k < end; ++k) {
                uint j = sorted_indices[k];
                if (j <= id || j >= capacity) continue;
                uint type_j = body_type[j];
                if (type_j == 0u) continue;
                uint mask_j = collision_mask(type_j);
                if ((mask_i & mask_j) == 0u) continue;

                float2 xj = body_pos_pred[j];
                float  rj = body_radius[j];
                float  wj = body_inv_mass[j];

                float2 delta = xj - xi;
                float dist_sq = dot(delta, delta);
                float target = ri + rj;
                if (dist_sq >= target * target || dist_sq <= 1e-12f) continue;

                float dist = sqrt(dist_sq);
                float2 n = delta / max(dist, 1e-6f);
                float penetration = target - dist;
                float wsum = wi + wj;
                if (wsum <= 0.0f) continue;

                float2 corr_i = -(wi / wsum) * penetration * n;
                float2 corr_j =  (wj / wsum) * penetration * n;

                atomic_add_body_delta(id, corr_i);
                atomic_add_body_delta(j, corr_j);

                collision_callback(id, j, n, penetration);
            }
        }
    }
}


// (12) APPLY DELTAS
void apply_deltas(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;
    if (body_type[id] == 0u) return;

    float2 dp = load_body_delta(id) * RELAXATION;
    float mag = length(dp);
    float max_shift = DYNAMIC_BODY_RADIUS * 2.0f;
    if (mag > max_shift) dp *= (max_shift / max(mag, 1e-4f));

    if (body_inv_mass[id] > 0.0f) {
        body_pos_pred[id] += dp;
    }
}


// (13) FINALIZE

void deactivate_body(uint id) {
    if (id >= BODY_CAPACITY) return;
    uint state = body_type[id];
    if (state == 0u) return;

    if (id >= DYNAMIC_BODY_START) {
        uint active = global_state[0].spawn_active;
        if (active > 0u)
            InterlockedAdd(global_state[0].spawn_active, -1);
    }

    float2 current = body_pos_pred[id];
    body_type[id] = 0u;
    body_pos[id] = current;
    body_pos_pred[id] = current;
    body_vel[id] = float2(0.0f, 0.0f);
    store_body_delta(id, float2(0.0f, 0.0f));
}

void finalize_kernel(uint id) {
    uint capacity = BODY_CAPACITY;
    if (id >= capacity) return;
    if (body_type[id] == 0u) return;

    float dt = min(push_constants.delta_time, DT_CLAMP);
    dt = max(dt, 1e-4f);
    if (PHYS_SUBSTEPS > 1u) dt /= float(PHYS_SUBSTEPS);

    float2 x0 = body_pos[id];
    float2 x1 = body_pos_pred[id];
    float inv_mass = body_inv_mass[id];

    if (inv_mass <= 0.0f)
        x1 = x0;

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
        float2 to_center = x1 - GAME_START_CENTER;
        float dist_sq = dot(to_center, to_center);
        float limit = DYNAMIC_BODY_MAX_DISTANCE;
        if (dist_sq > limit * limit) {
            body_vel[id] = float2(0.0f, 0.0f);
            deactivate_body(id);
            return;
        }
    }
}

// (14) RENDER
void render_kernel(uint id) {
	uint width = push_constants.screen_width;
	uint height = push_constants.screen_height;
	uint total_pixels = width * height;
	if (id >= total_pixels || width == 0u || height == 0u) return;

	float2 uv = pixel_center_uv(id, width, height);
	float2 world = uv_to_world(uv);

	float3 color = float3(0.016f, 0.018f, 0.020f);
	float density = 0.001f;

	uint cells = grid_cell_count();
	uint2 gi = world_to_cell(world);
	for (int oy = -1; oy <= 1; ++oy) {
		for (int ox = -1; ox <= 1; ++ox) {

			uint nx = wrap_int(int(gi.x) + ox, GRID_X);
			uint ny = wrap_int(int(gi.y) + oy, GRID_Y);

			uint2 neighbor = uint2(nx, ny);
			uint c = cell_index(neighbor);
			if (c >= cells) continue;
			uint begin = cell_offsets[c];
			uint end = cell_offsets[c + 1u];
			for (uint k = begin; k < end; ++k) {
				uint j = sorted_indices[k];
				float2 pos = body_pos[j];
				float radius = body_radius[j];
				uint type = body_type[j];
				float render_radius = radius;
				float render_softness = max(radius * 0.6f, 0.05f);
				if (type == 2u) {
					// Slightly dilate clustered type-2 bodies so their halos blend without visible seams.
					float expand = radius * 0.4f;
					render_radius += expand;
					render_softness = max(render_softness, render_radius * 0.55f);
				}
				float dist = length(world - pos);
				float coverage = soft_circle(dist, render_radius, render_softness);
				BodyRenderData info = render(j, type);
				if (info.intensity > 0.0f) {
					color += info.color * coverage * info.intensity;
				}
				density = max(density, coverage);
			}
		}
	}
	color = saturate(color);
	density = saturate(density);

	uint accum_idx = id * 4u;
	accumulation_buffer[accum_idx] = (uint)(color.r * COLOR_SCALE);
	accumulation_buffer[accum_idx + 1u] = (uint)(color.g * COLOR_SCALE);
	accumulation_buffer[accum_idx + 2u] = (uint)(color.b * COLOR_SCALE);
	accumulation_buffer[accum_idx + 3u] = (uint)(density * COLOR_SCALE);


}

// ============================================================================
// MAIN ENTRY (DISPATCH 0–14)
// ============================================================================

[numthreads(128, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
	uint id = tid.x;
	switch (push_constants.dispatch_mode) {
		case 0u: begin_frame(id); break; // CAMERA UPDATE / INIT
		case 1u: initialize_bodies(id); break;
		case 2u: clear_grid(id); break;
		case 3u: integrate_predict(id); break;
		case 4u: histogram_kernel(id); break;
		case 5u: prefix_copy_kernel(id); break;
		case 6u: prefix_scan_step(id, push_constants.scan_source, push_constants.scan_offset); break;
		case 7u: prefix_copy_source(id); break;
		case 8u: prefix_finalize_kernel(id, push_constants.scan_source); break;
		case 9u: scatter_kernel(id); break;
		case 10u: zero_deltas(id); break;
		case 11u: constraints_kernel(id); break;
		case 12u: apply_deltas(id); break;
		case 13u: finalize_kernel(id); break;
		case 14u: render_kernel(id); break;
	}
}
