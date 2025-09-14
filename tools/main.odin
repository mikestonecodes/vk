package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:strconv"
import "core:path/filepath"
import "core:c"
import posix "core:sys/posix"
import linux "core:sys/linux"

// Config: no flags; immediate reload on change

// Simple extension filter; by default only watch .odin files
should_watch_file :: proc(path: string) -> bool {
    // Ignore hidden files and our own artifacts
    base := path
    // crude basename: find last '/'
    if i := strings.last_index(path, "/"); i >= 0 {
        base = path[i+1:]
    }
    if strings.has_prefix(base, ".") {
        return false
    }
    if strings.has_suffix(base, "~") {
        return false
    }
    if strings.has_suffix(path, ".odin") {
        return true
    }
    return false
}

is_ignored_dir :: proc(name: string) -> bool {
    return name == ".git" || name == ".hg" || name == ".svn" || name == "build" || name == "odin-out" || name == ".cache"
}

// (poll snapshot code removed; using inotify only on Linux)

// ------------------ Lightweight content hashing ------------------
// FNV-1a 64-bit for quick content-change detection
fnv1a64_update :: proc(h: u64, b: []byte) -> u64 {
    prime: u64 = 1099511628211
    hh := h
    for v in b {
        hh = hh * prime + u64(v) + u64(0x9E3779B97F4A7C15)
        // rotate-left by 13 bits
        hh = (hh << 13) | (hh >> u64(64-13))
    }
    return hh
}

fnv1a64 :: proc(b: []byte) -> u64 {
    offset: u64 = 1469598103934665603
    return fnv1a64_update(offset, b)
}

file_hash64 :: proc(path: string) -> (h: u64, ok: bool) {
    data, read_ok := os.read_entire_file(path)
    if !read_ok {
        return 0, false
    }
    defer delete(data)
    return fnv1a64(data), true
}

// Execute a shell command. Returns exit code.
// Run a shell command and print its output to console while returning exit code.
run_and_tee :: proc(cmd: string, log_path: string) -> int {
    ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
    mode := strings.clone_to_cstring("r", context.temp_allocator)
    fp := posix.popen(ccmd, mode)
    if fp == nil {
        return -1
    }
    // open log file for append
    fd, _ := os.open(log_path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
    defer if fd != os.INVALID_HANDLE { _ = os.close(fd) }

    buf: [4096]byte
    for posix.fgets(&buf[0], len(buf), fp) != nil {
        line := string(cstring(&buf[0]))
        // Print to console
        fmt.print(line)
        // Append to log
        if fd != os.INVALID_HANDLE {
            _, _ = os.write(fd, transmute([]byte)line)
        }
    }
    status := posix.pclose(fp)
    if posix.WIFEXITED(status) {
        return int(posix.WEXITSTATUS(status))
    }
    return -1
}

// Run a shell command quietly and return exit code
sh_quiet :: proc(cmd: string) -> int {
    ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
    mode := strings.clone_to_cstring("r", context.temp_allocator)
    fp := posix.popen(ccmd, mode)
    if fp == nil { return -1 }
    // Drain output to avoid blocking
    buf: [1024]byte
    for posix.fgets(&buf[0], len(buf), fp) != nil { /**/ }
    status := posix.pclose(fp)
    if posix.WIFEXITED(status) { return int(posix.WEXITSTATUS(status)) }
    return -1
}

// Spawn a command in the background (detached from this process). Returns child pid on success.
spawn_background :: proc(cmd: string) -> (pid: int, ok: bool) {
    // Use sh to background and echo the pid so we know it launched.
    wrapped := fmt.tprintf("%s & echo $!", cmd)
    sh := fmt.tprintf("sh -lc %s", shell_escape(wrapped))
    ccmd := strings.clone_to_cstring(sh, context.temp_allocator)
    mode := strings.clone_to_cstring("r", context.temp_allocator)
    fp := posix.popen(ccmd, mode)
    if fp == nil { return 0, false }
    buf: [128]byte
    if posix.fgets(&buf[0], len(buf), fp) != nil {
        pid_str := strings.trim_space(string(cstring(&buf[0])))
        if val, parsed := strconv.parse_i64(pid_str); parsed {
            _ = posix.pclose(fp)
            return int(val), true
        }
    }
    _ = posix.pclose(fp)
    return 0, false
}

kill_pid :: proc(pid: int) {
    // best-effort terminate, then kill -9
    _ = sh_quiet(fmt.tprintf("sh -lc 'kill -TERM %d 2>/dev/null || true'", pid))
    // give it a moment
    time.sleep(200 * time.Millisecond)
    _ = sh_quiet(fmt.tprintf("sh -lc 'kill -KILL %d 2>/dev/null || true'", pid))
}

launch_background :: proc(binary: string, log_path: string) -> (pid: int, ok: bool) {
    // Run in background, append stdout/stderr to log; capture PID from stdout
    cmd := fmt.tprintf("sh -lc '%s >> %s 2>&1 & echo $!'", shell_escape(binary), shell_escape(log_path))
    ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
    mode := strings.clone_to_cstring("r", context.temp_allocator)
    fp := posix.popen(ccmd, mode)
    if fp == nil { return 0, false }

    buf: [128]byte
    if posix.fgets(&buf[0], len(buf), fp) != nil {
        pid_str := strings.trim_space(string(cstring(&buf[0])))
        _ = posix.pclose(fp)
        val, ok := strconv.parse_i64(pid_str)
        if ok { return int(val), true }
    }
    _ = posix.pclose(fp)
    return 0, false
}

// Launch a background process with a specified working directory so relative assets resolve.
launch_background_cwd :: proc(binary: string, log_path: string, cwd: string) -> (pid: int, ok: bool) {
    cmd := fmt.tprintf("sh -lc 'cd %s && %s >> %s 2>&1 & echo $!'",
        shell_escape(cwd), shell_escape(binary), shell_escape(log_path))
    ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
    mode := strings.clone_to_cstring("r", context.temp_allocator)
    fp := posix.popen(ccmd, mode)
    if fp == nil { return 0, false }

    buf: [128]byte
    if posix.fgets(&buf[0], len(buf), fp) != nil {
        pid_str := strings.trim_space(string(cstring(&buf[0])))
        _ = posix.pclose(fp)
        val, ok := strconv.parse_i64(pid_str)
        if ok { return int(val), true }
    }
    _ = posix.pclose(fp)
    return 0, false
}

shell_escape :: proc(s: string) -> string {
    // naive single-quote escape for POSIX sh
    // ' -> '\''
    r, _ := strings.replace_all(s, "'", "'\\''")
    return fmt.tprintf("'%s'", r)
}

usage :: proc() {
    fmt.println("Odin Launcher + Watcher")
    fmt.println("Usage: odin run . -- <project_dir>")
}

// ------------------ Single-instance lock (PID file) ------------------
pid_is_alive :: proc(pid: int) -> bool {
    if pid <= 0 { return false }
    code := sh_quiet(fmt.tprintf("sh -lc 'kill -0 %d 2>/dev/null'", pid))
    return code == 0
}

read_pidfile :: proc(path: string) -> (pid: int, ok: bool) {
    data, rok := os.read_entire_file(path)
    if !rok { return 0, false }
    defer delete(data)
    s := strings.trim_space(string(data))
    if s == "" { return 0, false }
    val, parsed := strconv.parse_i64(s)
    if !parsed { return 0, false }
    return int(val), true
}

write_pidfile :: proc(path: string, pid: int) -> bool {
    fd, _ := os.open(path, os.O_WRONLY|os.O_TRUNC|os.O_CREATE, 0o644)
    if fd == os.INVALID_HANDLE { return false }
    defer _ = os.close(fd)
    s := fmt.tprintf("%d\n", pid)
    _, _ = os.write(fd, transmute([]byte)s)
    return true
}

acquire_lock :: proc(lock_path: string) -> bool {
    // If an existing PID is alive, terminate it so the new watcher takes over
    if old_pid, ok := read_pidfile(lock_path); ok {
        if pid_is_alive(old_pid) {
            fmt.println("[odin-launcher] Previous watcher detected (pid:", old_pid, "). Stopping it...")
            kill_pid(old_pid)
            // Wait briefly for the old process to exit
            for i := 0; i < 30; i += 1 {
                if !pid_is_alive(old_pid) { break }
                time.sleep(100 * time.Millisecond)
            }
        }
        // Remove stale/old lock file before writing ours
        _ = os.remove(lock_path)
    }
    // Write our PID
    my_pid := int(posix.getpid())
    if !write_pidfile(lock_path, my_pid) {
        fmt.println("[odin-launcher] Failed to write lock file:", lock_path)
        return false
    }
    return true
}

release_lock :: proc(lock_path: string) {
    // Only remove if file still points to us
    my_pid := int(posix.getpid())
    pid, ok := read_pidfile(lock_path)
    if ok && pid == my_pid {
        _ = os.remove(lock_path)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        usage()
        return
    }

    // Parse args after a standalone "--" if present
    args := os.args[1:]
    if args[0] == "--" {
        args = args[1:]
    }
    if len(args) < 1 {
        usage()
        return
    }

    target_dir := args[0]

    // Normalize target dir a bit: remove trailing slash
    if len(target_dir) > 1 && strings.has_suffix(target_dir, "/") {
        target_dir = target_dir[:len(target_dir)-1]
    }

    log_path := fmt.tprintf("%s/odin-launcher.log", target_dir)
    // Per-reload log: cleared on each rebuild/reload
    reload_log_path := fmt.tprintf("%s/odin-launcher.reload.log", target_dir)
    out_bin := fmt.tprintf("%s/.odin_launcher_bin", target_dir)
    lock_path := fmt.tprintf("%s/.odin_watcher.pid", target_dir)

    fmt.println("[odin-launcher] watching:", target_dir)
    fmt.println("[odin-launcher] log:", log_path)
    fmt.println("[odin-launcher] reload log (clears on reload):", reload_log_path)
    // No debounce; immediate reload on change

    // Ensure single instance per target directory
    if !acquire_lock(lock_path) {
        return
    }
    defer release_lock(lock_path)

    // Initial build
    running_pid := 0
    // Duplicator (tail) pid which mirrors reload_log -> log_path
    dup_pid := 0
    defer {
        if running_pid > 0 { kill_pid(running_pid) }
        if dup_pid > 0 { kill_pid(dup_pid) }
    }
    build_and_maybe_run(target_dir, out_bin, log_path, reload_log_path, &running_pid, &dup_pid)

    when ODIN_OS == .Linux {
        watch_loop_inotify(target_dir, out_bin, log_path, reload_log_path, &running_pid, &dup_pid)
    } else {
        fmt.println("[odin-launcher] Non-Linux OS detected; inotify watcher is Linux-only.")
    }
}

// Try to open a terminal window showing recent build errors, waiting for user input.
show_build_errors :: proc(log_path: string) -> bool {
    // Show last 400 lines (fallback to full file), then wait for ENTER
    payload_shell := fmt.tprintf("(tail -n 400 %s || cat %s); printf \'\\n\\n[build failed] Press ENTER to close\\n\'; read _",
        shell_escape(log_path), shell_escape(log_path))
    payload := fmt.tprintf("sh -lc %s", shell_escape(payload_shell))

    // Try common terminal emulators; stop at first success
    templates := []string{
        "x-terminal-emulator -e %s",
        "xterm -e %s",
        "konsole -e %s",
        "gnome-terminal -- %s",
        "kitty %s",
        "alacritty -e %s",
        "xfce4-terminal -e %s",
        "mate-terminal -e %s",
        "lxterminal -e %s",
        "tilix -e %s",
        "urxvt -e %s",
    }
    for tmpl in templates {
        cmd := fmt.tprintf(tmpl, payload)
        if _, ok := spawn_background(cmd); ok {
            return true
        }
    }
    // Fallback: try default file opener
    if _, ok := spawn_background(fmt.tprintf("xdg-open %s", shell_escape(log_path))); ok {
        return true
    }
    // Last resort: desktop notification
    _, _ = spawn_background(fmt.tprintf("notify-send %s %s", shell_escape("Odin build failed"), shell_escape(fmt.tprintf("See %s", log_path))))
    return false
}

build_and_maybe_run :: proc(target_dir: string, out_bin: string, log_path: string, reload_log_path: string, running_pid: ^int, dup_pid: ^int) {
    // Ensure any existing duplicator is stopped
    if dup_pid^ > 0 {
        kill_pid(dup_pid^)
        dup_pid^ = 0
    }

    // Clear per-reload log
    do_trunc := proc(path: string) {
        fd, _ := os.open(path, os.O_WRONLY|os.O_TRUNC|os.O_CREATE, 0o644)
        if fd != os.INVALID_HANDLE { _ = os.close(fd) }
    }
    do_trunc(reload_log_path)

    // Start duplicating reload_log -> main log for subsequent output
    // Use tail -n 0 to only mirror new content written after this point
    dup_cmd := fmt.tprintf("sh -lc 'tail -n 0 -F %s >> %s 2>/dev/null & echo $!'",
        shell_escape(reload_log_path), shell_escape(log_path))
    {
        ccmd := strings.clone_to_cstring(dup_cmd, context.temp_allocator)
        mode := strings.clone_to_cstring("r", context.temp_allocator)
        fp := posix.popen(ccmd, mode)
        if fp != nil {
            buf: [128]byte
            if posix.fgets(&buf[0], len(buf), fp) != nil {
                pid_str := strings.trim_space(string(cstring(&buf[0])))
                _ = posix.pclose(fp)
                if val, ok := strconv.parse_i64(pid_str); ok { dup_pid^ = int(val) }
            } else {
                _ = posix.pclose(fp)
            }
        }
    }

    // Build and tee output to terminal and reload log
    build_cmd := fmt.tprintf(
        "sh -lc 'set -o pipefail; odin build %s -out:%s 2>&1'",
        shell_escape(target_dir), shell_escape(out_bin),
    )
    code := run_and_tee(build_cmd, reload_log_path)
    if code == 0 {
        fmt.println("[odin-launcher] build OK. launching app...")
        // If already running, stop it before launching new
        if running_pid^ > 0 {
            kill_pid(running_pid^)
            running_pid^ = 0
        }
        // Launch app, direct its output to the per-reload log
        pid, ok := launch_background(out_bin, reload_log_path)
        if ok {
            running_pid^ = pid
            fmt.println("[odin-launcher] app pid:", pid)
        } else {
            fmt.println("[odin-launcher] failed to launch app.")
        }
    } else {
        fmt.println("[odin-launcher] build failed. Stopping app and showing errors...")
        // Stop any running app so state is consistent on failure
        if running_pid^ > 0 {
            kill_pid(running_pid^)
            running_pid^ = 0
        }
        _ = show_build_errors(log_path)
    }
}

// ------------------ Inotify-based watcher (Linux) ------------------
when ODIN_OS == .Linux {
    Watcher_Ctx :: struct {
        fd: linux.Fd,
        mask: linux.Inotify_Event_Mask,
        wd_to_path: ^map[linux.Wd]string,
        path_to_wd: ^map[string]linux.Wd,
        // Track last known content hash for watched files
        hashes: ^map[string]u64,
    }

    add_watch_for_dir :: proc(ctx: ^Watcher_Ctx, path: string) {
        if is_ignored_dir(filepath.base(path)) { return }
        if w := ctx.path_to_wd^[path]; int(w) > 0 { return }
        cpath := strings.clone_to_cstring(path, context.temp_allocator)
        wd, werr := linux.inotify_add_watch(ctx.fd, cpath, ctx.mask)
        if werr == linux.Errno(0) && int(wd) >= 0 {
            ctx.wd_to_path^[wd] = path
            ctx.path_to_wd^[path] = wd
        }
    }

    remove_watch_for_dir :: proc(ctx: ^Watcher_Ctx, path: string) {
        if path == "" { return }
        wd := ctx.path_to_wd^[path]
        if int(wd) <= 0 { return }
        _ = linux.inotify_rm_watch(ctx.fd, wd)
        _, _ = delete_key(ctx.wd_to_path, wd)
        _, _ = delete_key(ctx.path_to_wd, path)
    }

    watch_loop_inotify :: proc(target_dir: string, out_bin: string, log_path: string, reload_log_path: string, running_pid: ^int, dup_pid: ^int) {
        // Create inotify instance (blocking)
        fd, err := linux.inotify_init1(linux.Inotify_Init_Flags{})
        if err != linux.Errno(0) {
            fmt.println("[odin-launcher] inotify_init1 failed.")
            return
        }
        defer _ = linux.close(fd)

        // maps for watches
        wd_to_path: map[linux.Wd]string
        path_to_wd: map[string]linux.Wd
        hashes: map[string]u64
        wd_to_path = make(map[linux.Wd]string)
        path_to_wd = make(map[string]linux.Wd)
        hashes = make(map[string]u64)

        // prepare mask: only save-like events for rebuild; keep dir lifecycle
        mask := linux.Inotify_Event_Mask{}
        // Keep .CREATE to add watches for new directories; it will not trigger rebuilds
        mask |= {.CLOSE_WRITE, .MOVED_TO, .CREATE, .DELETE_SELF, .MOVE_SELF}
        ctx := Watcher_Ctx{ fd=fd, mask=mask, wd_to_path=&wd_to_path, path_to_wd=&path_to_wd, hashes=&hashes }

        // initial recursive add
        _ = filepath.walk(target_dir, proc(info: os.File_Info, in_err: os.Error, _user: rawptr) -> (err: os.Error, skip_dir: bool) {
            if in_err != nil { return in_err, false }
            if info.is_dir {
                if is_ignored_dir(info.name) { return nil, true }
                ctxp := (^Watcher_Ctx)(_user)
                add_watch_for_dir(ctxp, info.fullpath)
            } else {
                // Seed initial hashes so identical rewrites don't trigger rebuild
                if should_watch_file(info.fullpath) {
                    if h, ok := file_hash64(info.fullpath); ok {
                        ctxp := (^Watcher_Ctx)(_user)
                        ctxp.hashes^[info.fullpath] = h
                    }
                }
            }
            return nil, false
        }, &ctx)

        // event processing loop
        buf: [64 << 10]u8
        for {
            n, rerr := linux.read(fd, buf[:])
            if n <= 0 {
                if rerr != linux.Errno(0) { time.sleep(20 * time.Millisecond) }
                continue
            }
            off := 0
            should_rebuild := false
            for off + int(size_of(linux.Inotify_Event)) <= n {
                ev := (^linux.Inotify_Event)(&buf[off])
                name_str := ""
                if ev.len > 0 {
                    name_ptr := cstring(&buf[off + int(size_of(linux.Inotify_Event))])
                    name_str = string(name_ptr)
                }
                parent := wd_to_path[ev.wd]
                if parent == "" { parent = target_dir }

                // directory lifecycle
                if .IGNORED in ev.mask {
                    _, _ = delete_key(&wd_to_path, ev.wd)
                    if parent != "" { _, _ = delete_key(&path_to_wd, parent) }
                }
                if .CREATE in ev.mask && .ISDIR in ev.mask {
                    new_dir := fmt.tprintf("%s/%s", parent, name_str)
                    if !is_ignored_dir(filepath.base(new_dir)) { add_watch_for_dir(&ctx, new_dir) }
                }
                if .DELETE_SELF in ev.mask || .MOVE_SELF in ev.mask {
                    remove_watch_for_dir(&ctx, parent)
                }

                // file changes
                full := parent
                if name_str != "" { full = fmt.tprintf("%s/%s", parent, name_str) }
                // Rebuild only when file contents actually changed.
                if (.CLOSE_WRITE in ev.mask) || (.MOVED_TO in ev.mask) {
                    if name_str != "" && should_watch_file(full) {
                        if h, ok := file_hash64(full); ok {
                            prev := ctx.hashes^[full]
                            if prev != h {
                                ctx.hashes^[full] = h
                                should_rebuild = true
                            } else {
                                // identical rewrite; skip rebuild
                            }
                        }
                    }
                }

                off += int(size_of(linux.Inotify_Event)) + int(ev.len)
            }

            if should_rebuild {
                fmt.println("[odin-launcher] change detected (inotify). rebuilding...")
                build_and_maybe_run(target_dir, out_bin, log_path, reload_log_path, running_pid, dup_pid)
            }
        }
    }
}
