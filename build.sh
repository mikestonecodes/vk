#!/bin/bash

# Fast WGSL compilation script
echo "Compiling WGSL shaders..."
# Compile fragment shader
./naga fragment.wgsl fragment.spv --output-format spv || {
    echo "Failed to compile fragment shader"
    exit 1
}

echo "Shaders compiled successfully!"

# Optional: Build Odin project
if [ "$1" = "run" ]; then
    echo "Building and running Odin project..."
    odin run main.odin -file
fi
