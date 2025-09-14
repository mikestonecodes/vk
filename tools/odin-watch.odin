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

	build_result := system("odin build . ")
	if build_result == 0 {
		system("echo '' > odin-launcher.reload.log")
		// Only run if build succeeded
		system("nohup ./vk > odin-launcher.reload.log 2>&1 &")
	}

	for {
		if scan_once() {
			fmt.println("Starting new build...")

			// Kill existing process
			system("killall vk")

			// Build the project
			build_result := system("odin build . ")

			if build_result == 0 {
				// Only run if build succeeded
				system("nohup ./vk > odin-launcher.reload.log 2>&1 &")
			}
		}
		time.sleep(500 * time.Millisecond)
	}
}
