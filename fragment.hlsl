// ===========================================================
// Vulkan Mesh/Task Shader Example – Dynamic Pulsating Wave Grid
// ===========================================================

// Payload structure for communication between task and mesh shaders
struct TaskPayload {
    uint meshletCount;
};

// Output structure from mesh shader to fragment shader
struct MeshOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float3 color    : COLOR0;
    float3 worldPos : TEXCOORD1;
};

// Push constant for time-based animation
struct PushConstants {
    float time;
};
[[vk::push_constant]] PushConstants pushConstants;

// ===========================================================
// Task Shader (Amplification Shader)
// ===========================================================
groupshared TaskPayload payload;

[numthreads(1,1,1)]
[shader("amplification")]
void task_main(uint3 groupID : SV_GroupID) {
    const uint gridSize = 16;

    // Compute total meshlets (1 per grid cell)
    payload.meshletCount = gridSize * gridSize;

    // Dispatch all meshlets from a single task
    DispatchMesh(payload.meshletCount, 1, 1, payload);
}

// ===========================================================
// Mesh Shader
// ===========================================================
[numthreads(1,1,1)]
[shader("mesh")]
[OutputTopology("triangle")]
void mesh_main(
    uint3 groupID : SV_GroupID,
    uint3 threadID : SV_GroupThreadID,
    in payload TaskPayload payload,
    out vertices MeshOutput verts[4],
    out indices uint3 tris[2]
) {
    const uint gridSize = 16;

    // Each mesh shader handles 1 meshlet (1 cell)
    uint cellIndex = groupID.x;
    if (cellIndex >= gridSize * gridSize) return;

    uint x = cellIndex % gridSize;
    uint y = cellIndex / gridSize;

    float cellSize = 2.0 / float(gridSize);
    float2 cellPos = float2(-1.0 + float(x) * cellSize, -1.0 + float(y) * cellSize);

    float time = pushConstants.time;

    // Dynamic wave animation
    float dist = length(cellPos);
    float wave = sin(dist * 3.0 - time * 2.0) * 0.3 * exp(-dist * 0.5);

    // Color based on wave height and position
    float3 color = saturate(float3(
        0.5 + 0.5*sin(time + x),
        0.5 + 0.5*cos(time + y),
        1.0 - wave
    ));

    // Quad vertices
    verts[0].position = float4(cellPos.x, cellPos.y, wave, 1.0);
    verts[0].uv = float2(0,0); verts[0].color = color; verts[0].worldPos = float3(cellPos.x, cellPos.y, wave);

    verts[1].position = float4(cellPos.x + cellSize, cellPos.y, wave, 1.0);
    verts[1].uv = float2(1,0); verts[1].color = color; verts[1].worldPos = float3(cellPos.x + cellSize, cellPos.y, wave);

    verts[2].position = float4(cellPos.x, cellPos.y + cellSize, wave, 1.0);
    verts[2].uv = float2(0,1); verts[2].color = color; verts[2].worldPos = float3(cellPos.x, cellPos.y + cellSize, wave);

    verts[3].position = float4(cellPos.x + cellSize, cellPos.y + cellSize, wave, 1.0);
    verts[3].uv = float2(1,1); verts[3].color = color; verts[3].worldPos = float3(cellPos.x + cellSize, cellPos.y + cellSize, wave);

    // Two triangles per quad
    tris[0].xyz = uint3(0,1,2);
    tris[1].xyz = uint3(1,3,2);

    SetMeshOutputCounts(4, 2);
}

// ===========================================================
// Fragment Shader
// ===========================================================
[shader("pixel")]
float4 fs_main(MeshOutput input) : SV_Target0 {
    return float4(input.color, 1.0);
}
