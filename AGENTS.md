# AGENTS.md
- This container does not run the local odin-watch helper. Before finishing any task, run `odin build .` to make sure the project still builds.
- Manually compile the shaders with `dxc` so syntax errors are caught:
  - `dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T cs_6_0 -E main -Fo compute.spv compute.hlsl`
  - `dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T vs_6_0 -E vs_main -Fo graphics_vs.spv graphics.hlsl`
  - `dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T ps_6_0 -E fs_main -Fo graphics_fs.spv graphics.hlsl`
  - `dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T vs_6_0 -E vs_main -Fo post_process_vs.spv post_process.hlsl`
  - `dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T ps_6_0 -E fs_main -Fo post_process_fs.spv post_process.hlsl`
- If you touch additional shaders, compile them with matching profiles and entry points so their SPIR-V stays in sync.
- Keep the repo tidy by reverting experiments that do not ship and preferring small, reviewable changes.
