struct PushConstants {
    time: f32,
    quad_count: u32,
}

var<push_constant> push_constants: PushConstants;

struct Quad {
    position: vec2<f32>,
    size: vec2<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<storage, read_write> quads: array<Quad>;

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let quad_id = global_id.x;
    if quad_id >= push_constants.quad_count {
        return;
    }

    // decode hierarchy
    var id = quad_id;
    var nodeType: u32 = 0u; // start at A
    var depth: u32 = 0u;

    var pos = vec2<f32>(0.0, 0.0);
    var scale = 1.0;
    scale *= 1.4 ; // Static zoom with time-based variation

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

    // assign quad
    quads[quad_id].position = pos;
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
