#!/bin/bash

# DXC HLSL compilation script
echo "Compiling HLSL shaders with DXC..."

# Compile task shader
dxc -T as_6_5 -E task_main fragment.hlsl -Fo task.spv -spirv || {
    echo "Failed to compile task shader"
    exit 1
}

# Compile mesh shader  
dxc -T ms_6_5 -E mesh_main fragment.hlsl -Fo mesh.spv -spirv || {
    echo "Failed to compile mesh shader"
    exit 1
}

# Compile fragment shader
dxc -T ps_6_0 -E fs_main fragment.hlsl -Fo fragment.spv -spirv || {
    echo "Failed to compile fragment shader"
    exit 1
}

echo "Shaders compiled successfully!"

# Optional: Build Odin project
if [ "$1" = "run" ]; then
    echo "Building and running Odin project..."
    odin run main.odin -file
fi
