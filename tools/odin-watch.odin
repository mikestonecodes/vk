package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Extremely small watcher: polls specified directory for .odin changes
last_times: map[string]time.Time
watch_dir: string

// Provide C's system(...) for spawning a shell command locally
foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}

scan_once :: proc() -> bool {
	handle, err := os.open(watch_dir)
	if err != nil {
		return false
	}
	files, read_err := os.read_dir(handle, -1)
	os.close(handle)
	if read_err != nil {
		return false
	}
	changed := false
	for file in files {
		if strings.has_suffix(file.name, ".odin") {
			if prev, ok := last_times[file.name]; !ok || prev != file.modification_time {
				last_times[strings.clone(file.name)] = file.modification_time
				fmt.printf("CHANGED: %s\n", file.name)
				changed = true
			}
		}
	}
	delete(files)
	return changed
}


build_and_run :: proc() {

	fmt.println("Starting new build...")

	// Kill old vk
	system("pkill -TERM vk 2>/dev/null || true")
	time.sleep(120 * time.Millisecond)
	system("pkill -KILL vk 2>/dev/null || true")

	// Reset log for new build output
	system("echo '' > odin-launcher.reload.log")

	// Build (capture stdout/stderr into reload log)
	build_result := system("odin build . >> odin-launcher.reload.log 2>&1")

	if build_result == 0 {
		system("echo '\nBuild succeeded, launching vk...' >> odin-launcher.reload.log")
		time.sleep(150 * time.Millisecond)
		system("nohup ./vk >> odin-launcher.reload.log 2>&1 &")
	} else {
		system("echo '\nBuild failed. See errors above.' >> odin-launcher.reload.log")
}
}


main :: proc() {
	// Clear odin-launcher.reload.log
	system("echo '' > odin-launcher.reload.log")

	// Get directory from command line arguments
	args := os.args
	if len(args) < 2 {
		fmt.println("Usage: odin-watch <directory>")
		fmt.println("Example: odin-watch .")
		return
	}

	watch_dir = args[1]
	fmt.printf("Watching .odin files in directory: %s\n", watch_dir)

	// Ensure the map is allocated before use
	last_times = make(map[string]time.Time)

	// Prime the map without triggering a build
	handle, err := os.open(watch_dir)
	if err == nil {
		files, read_err := os.read_dir(handle, -1)
		os.close(handle)
		if read_err == nil {
			for file in files {
				if strings.has_suffix(file.name, ".odin") {
					last_times[strings.clone(file.name)] = file.modification_time
				}
			}
			delete(files)
		}
	}

	// Initial build + run
	build_and_run()

	for {
		if scan_once() {
			build_and_run()
		}
		time.sleep(50 * time.Millisecond)
	}
}
