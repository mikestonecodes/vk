struct PushConstants {
    time: f32,
    quad_count: u32,
    delta_time: f32,
    // Input state
    mouse_x: f32,
    mouse_y: f32,
    mouse_left: u32,
    mouse_right: u32,
    // Keyboard state (vim keys + common keys)
    key_h: u32,
    key_j: u32,
    key_k: u32,
    key_l: u32,
    key_w: u32,
    key_a: u32,
    key_s: u32,
    key_d: u32,
    key_q: u32,
    key_e: u32,
}

var<push_constant> push_constants: PushConstants;

struct Quad {
    position: vec2<f32>,
    size: vec2<f32>,
    color: vec4<f32>,
    rotation: f32,
    _padding: vec3<f32>, // Align to 16-byte boundary
}

struct CameraState {
    x: f32,
    y: f32,
    zoom: f32,
    _padding: f32,
}

struct Line {
    start_pos: vec2<f32>,
    end_pos: vec2<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<storage, read_write> quads: array<Quad>;
@group(0) @binding(1) var<storage, read_write> camera: CameraState;

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let quad_id = global_id.x;
    if quad_id >= push_constants.quad_count {
        return;
    }

    // Update camera state only for first thread to avoid race conditions
    if quad_id == 0u {
        let move_speed = 2.0;
        let zoom_speed = 0.1;
        let dt = push_constants.delta_time;

        // Update camera based on input (WASD)
        if push_constants.key_a != 0u { camera.x -= move_speed * dt; }
        if push_constants.key_d != 0u { camera.x += move_speed * dt; }
        if push_constants.key_w != 0u { camera.y += move_speed * dt; }
        if push_constants.key_s != 0u { camera.y -= move_speed * dt; }

        // Zoom with q/e - multiplicative zoom for smooth "through" feeling
        if push_constants.key_e != 0u {
            camera.zoom *= 1.0 + zoom_speed * dt * 5.0; // zoom in multiplicatively
        }
        if push_constants.key_q != 0u {
            camera.zoom /= 1.0 + zoom_speed * dt * 5.0; // zoom out multiplicatively
        }
        camera.zoom = max(0.01, camera.zoom);
    }

    // Ensure camera updates are visible to all threads
    workgroupBarrier();

    // decode hierarchy
    var id = quad_id;
    var nodeType: u32 = 0u; // start at A
    var depth: u32 = 0u;

    var pos = vec2<f32>(0.0, 0.0);
    var parent_pos = vec2<f32>(0.0, 0.0); // track parent position for line connections
    var scale = 1.4;
    let base_size: f32 = 0.12;
    var has_parent = false;

    loop {

        // branching factor per nodeType
        var factor: u32;
        switch nodeType {
            case 0u: { factor = 2u; } // A → 2 Bs
            case 1u: { factor = 3u; } // B → 3 Cs
            case 2u: { factor = 1u; } // C → 1 A
            default: { factor = 0u; }
        }

        if factor == 0u { break; }

        let childIndex = id % factor;
        id = id / factor;

        // Store current position as parent before transformation
        if id != 0u {
            parent_pos = pos;
            has_parent = true;
        }

        // compute child scale (less aggressive shrink so fractal stays denser)
        var shrink: f32;
        if nodeType == 0u {
            shrink = 0.9; // A→B
        } else if nodeType == 1u {
            shrink = 0.8; // B→C
        } else {
            shrink = 0.56;  // C→A
        }
        let child_scale = scale * shrink;

        // transform rules with touching spiral/finger patterns
        if nodeType == 0u { // A spawns Bs opposite each other
            let angle = f32(childIndex) * 3.14159;
            let dir = vec2<f32>(cos(angle), sin(angle));
            let offset = (base_size * (scale + child_scale)) * 0.5;
            pos += dir * offset;
        } else if nodeType == 1u { // B spawns Cs around
            let angle = f32(childIndex) * 2.0 * 3.14159 / 3.0;
            let dir = vec2<f32>(cos(angle), sin(angle));
            let offset = (base_size * (scale + child_scale)) * 0.5;
            pos += dir * offset;
        } else { // C spawns As (upwards)
            let dir = vec2<f32>(0.0, 1.0);
            let offset = (base_size * (scale + child_scale)) * 0.5;
            pos += dir * offset;
        }

        scale = child_scale;

        // advance type
        switch nodeType {
            case 0u: { nodeType = 1u; } // A→B
            case 1u: { nodeType = 2u; } // B→C
            case 2u: { nodeType = 0u; } // C→A
            default: { }
        }

        if id == 0u { break; }
        depth += 1u;
    }

    // apply camera zoom: scale positions and sizes so we "zoom through" the hierarchy
    let world_pos = pos * camera.zoom;
    quads[quad_id].position = world_pos + vec2<f32>(camera.x, camera.y);
    quads[quad_id].size = vec2<f32>(base_size * scale * camera.zoom);

    // rotation based on time, node type, and depth for interesting visual variety
    let rotation_speed = f32(nodeType + 1u) * 0.5 + f32(depth) * 0.2;
    quads[quad_id].rotation = push_constants.time * rotation_speed + f32(quad_id) * 0.1;

    // color depends on type & depth
    let hue = f32(nodeType) * 2.0 + f32(depth) * 0.3 + push_constants.time * 0.5;
    quads[quad_id].color = vec4<f32>(
        0.5 + 0.5 * cos(hue),
        0.5 + 0.5 * cos(hue + 2.094),
        0.5 + 0.5 * cos(hue + 4.188),
        1.0
    );

}
