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
}

struct CameraState {
    x: f32,
    y: f32,
    zoom: f32,
    _padding: f32,
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
        
        // Zoom with q/e - faster but controllable  
        if push_constants.key_e != 0u { 
            camera.zoom += zoom_speed * dt * 5.0;  // Faster linear zoom in
        }
        if push_constants.key_q != 0u { 
            camera.zoom -= zoom_speed * dt * 5.0;  // Faster linear zoom out
        }
        camera.zoom = max(0.1, camera.zoom);
    }
    
    // Ensure camera updates are visible to all threads
    workgroupBarrier();

    // decode hierarchy
    var id = quad_id;
    var nodeType: u32 = 0u; // start at A
    var depth: u32 = 0u;

    var pos = vec2<f32>(0.0, 0.0);
    var scale = 1.4;

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

        // transform rules
        if nodeType == 0u { // A spawns Bs in a circle
            let angle = f32(childIndex) * 3.14159 / 4.0 ;
            pos += vec2<f32>(cos(angle), sin(angle)) * 0.5 * scale;
            scale *= 0.7;
        } else if nodeType == 1u { // B spawns Cs around
            let angle = f32(childIndex) * 2.0 * 3.14159 / 3.0 ;
            pos += vec2<f32>(cos(angle), sin(angle)) * 0.3 * scale;
            scale *= 0.6;
        } else { // C spawns As
            pos += vec2<f32>(0.0, 0.5) * scale;
            scale *= 0.5;
        }

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

    // assign quad with camera offset - original approach
    quads[quad_id].position = pos + vec2<f32>(camera.x, camera.y);
    quads[quad_id].size = vec2<f32>(0.1 * scale);

    // color depends on type & depth
    let hue = f32(nodeType) * 2.0 + f32(depth) * 0.3 + push_constants.time * 0.5;
    quads[quad_id].color = vec4<f32>(
        0.5 + 0.5 * cos(hue),
        0.5 + 0.5 * cos(hue + 2.094),
        0.5 + 0.5 * cos(hue + 4.188),
        1.0
    );
}
