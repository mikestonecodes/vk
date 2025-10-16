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
    uint  key_h, key_j, key_k, key_l;
    uint  key_w, key_a, key_s, key_d;
    uint  key_q, key_e;
};
[[vk::push_constant]] PushConstants push_constants;

[[vk::binding(0, 0)]] RWStructuredBuffer<uint> buffers[];

struct GameStateEntry {
    float4 data0;
    float4 data1;
};
[[vk::binding(3, 0)]] RWStructuredBuffer<GameStateEntry> game_state;

static const float COLOR_SCALE      = 4096.0f;
static const uint  HEADER_INDEX     = 0u;
static const float PLAYER_RADIUS    = 7.0f;
static const float PLAYER_ACCEL     = 260.0f;
static const float PLAYER_MAX_SPEED = 420.0f;

float wrap_component(float v, float limit) {
    if (v < 0.0f) v += limit;
    if (v >= limit) v -= limit;
    return v;
}
float2 wrap_position(float2 p, float2 b) {
    p.x = wrap_component(p.x, b.x);
    p.y = wrap_component(p.y, b.y);
    return p;
}
float2 shortest_delta(float2 a, float2 b, float2 lim) {
    float2 d = b - a;
    if (d.x > lim.x * 0.5f) d.x -= lim.x;
    if (d.x < -lim.x * 0.5f) d.x += lim.x;
    if (d.y > lim.y * 0.5f) d.y -= lim.y;
    if (d.y < -lim.y * 0.5f) d.y += lim.y;
    return d;
}
uint encode(float v) { return (uint)(saturate(v) * COLOR_SCALE); }

[numthreads(128,1,1)]
void main(uint3 tid: SV_DispatchThreadID) {
    uint id = tid.x;
    uint w = push_constants.screen_width;
    uint h = push_constants.screen_height;
    if (w == 0 || h == 0) return;

    RWStructuredBuffer<uint> out_buf = buffers[0];
    uint pixel_count = w * h;
    float2 bounds = float2(w, h);

    // --- Init once ---
    if (asuint(game_state[HEADER_INDEX].data1.y) == 0u) {
        if (id == 0u) {
            GameStateEntry header;
            header.data0 = float4(bounds * 0.5f, 0, 0);
            header.data1 = float4(asfloat(1u), asfloat(1u), 0, 0);
            game_state[HEADER_INDEX] = header;
            DeviceMemoryBarrier();
        }
        return;
    }

    GameStateEntry header = game_state[HEADER_INDEX];
    uint ready = asuint(header.data1.x) + 1u;
    if (id == 0u) {
        float2 player_pos = header.data0.xy;
        float2 player_vel = header.data0.zw;
        float dt = max(min(push_constants.delta_time, 0.05f), 1.0f / 60.0f);

        float2 input = float2(
            (push_constants.key_d != 0u) - (push_constants.key_a != 0u),
            (push_constants.key_s != 0u) - (push_constants.key_w != 0u)
        );
        if (dot(input, input) > 0.0f) input = normalize(input);
        player_vel += input * PLAYER_ACCEL * dt;
        player_vel *= pow(0.8f, dt * 60.0f);
        if (length(player_vel) > PLAYER_MAX_SPEED)
            player_vel = normalize(player_vel) * PLAYER_MAX_SPEED;
        player_pos = wrap_position(player_pos + player_vel * dt, bounds);

        header.data0 = float4(player_pos, player_vel);
        header.data1 = float4(asfloat(ready), asfloat(1u), 0, 0);
        game_state[HEADER_INDEX] = header;
        DeviceMemoryBarrier();
    }

    [loop] while (asuint(game_state[HEADER_INDEX].data1.x) != ready) {}

    if (id >= pixel_count) return;

    uint px = id % w, py = id / w;
    float2 frag = float2(px + 0.5f, py + 0.5f);
    float3 col = float3(0.02f, 0.025f, 0.03f);
    float dens = 0.0f;

    GameStateEntry header_state = game_state[HEADER_INDEX];
    float2 player = header_state.data0.xy;

    float2 ship_d = shortest_delta(player, frag, bounds);
    float ship_core = saturate(1.0f - length(ship_d) / PLAYER_RADIUS);
    col += ship_core * float3(0.9f, 0.95f, 1.0f);
    dens = max(dens, ship_core);

    float3 fcol = saturate(col * max(push_constants.brightness, 0.2f));
    uint base = id * 4;
    out_buf[base+0]=encode(fcol.r);
    out_buf[base+1]=encode(fcol.g);
    out_buf[base+2]=encode(fcol.b);
    out_buf[base+3]=encode(saturate(0.3f + dens));
}

