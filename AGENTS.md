# AGENTS.md
- When odin files get saved, it automatically recompiles and shows the code
- Read the logs to see what happened by looking in odin-launcher.reload.log
- Don't ever *complete* task without making sure there are no validation errors from odin-launcher.reload.log, just check at the end that the changes you did worked. You can ignore this for the tools directory
- Unless you are working on something, try to undo changes that didn't work and keep the codebase clean
- Make small code changes if you can

- NO NEED TO RUN vk, odin run, odin build, dxc or compile shaders. Don't ever do that. I am running another process that auto-compiles everything. Just read odin-launcher.reload.log. Assume it's always working. It clears the log every time it rebuilds automatically from file change



