#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

// Global variables
static struct wl_display *display = NULL;
static struct wl_registry *registry = NULL;
static struct wl_compositor *compositor = NULL;
static struct wl_surface *surface = NULL;
static struct xdg_wm_base *shell = NULL;
static struct xdg_surface *shell_surface = NULL;
static struct xdg_toplevel *toplevel = NULL;
static int quit = 0;

// XDG Shell listeners
static void shell_ping(void *data, struct xdg_wm_base *shell, uint32_t serial) {
    xdg_wm_base_pong(shell, serial);
}

static const struct xdg_wm_base_listener shell_listener = {
    shell_ping,
};

static void shell_surface_configure(void *data, struct xdg_surface *shell_surface, uint32_t serial) {
    xdg_surface_ack_configure(shell_surface, serial);
}

static const struct xdg_surface_listener shell_surface_listener = {
    shell_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                              int32_t width, int32_t height, struct wl_array *states) {
    // Handle resize
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    quit = 1;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure,
    toplevel_close,
};

// Registry handler
static void registry_global(void *data, struct wl_registry *registry,
                          uint32_t id, const char *interface, uint32_t version) {
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 1);
        printf("Found compositor\n");
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        shell = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(shell, &shell_listener, NULL);
        printf("Found xdg_wm_base\n");
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    // Handle removal
}

static const struct wl_registry_listener registry_listener = {
    registry_global,
    registry_global_remove,
};

// Public interface
int wayland_init(void) {
    printf("Initializing Wayland with XDG shell...\n");
    
    display = wl_display_connect(NULL);
    if (!display) {
        printf("Failed to connect to Wayland display\n");
        return 0;
    }
    printf("Connected to Wayland display\n");

    registry = wl_display_get_registry(display);
    if (!registry) {
        printf("Failed to get registry\n");
        return 0;
    }
    
    wl_registry_add_listener(registry, &registry_listener, NULL);
    
    wl_display_dispatch(display);
    wl_display_roundtrip(display);

    if (!compositor || !shell) {
        printf("Missing compositor: %p or shell: %p\n", (void*)compositor, (void*)shell);
        return 0;
    }

    surface = wl_compositor_create_surface(compositor);
    if (!surface) {
        printf("Failed to create surface\n");
        return 0;
    }
    printf("Created surface\n");

    shell_surface = xdg_wm_base_get_xdg_surface(shell, surface);
    if (!shell_surface) {
        printf("Failed to create shell surface\n");
        return 0;
    }
    
    xdg_surface_add_listener(shell_surface, &shell_surface_listener, NULL);

    toplevel = xdg_surface_get_toplevel(shell_surface);
    if (!toplevel) {
        printf("Failed to create toplevel\n");
        return 0;
    }
    
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    
    xdg_toplevel_set_title(toplevel, "Vulkan Triangle");
    xdg_toplevel_set_app_id(toplevel, "vulkan-triangle");
    
    wl_surface_commit(surface);
    wl_display_roundtrip(display);
    wl_surface_commit(surface);

    printf("XDG shell initialization complete\n");
    return 1;
}

void wayland_cleanup(void) {
    printf("Cleaning up Wayland...\n");
    
    if (toplevel) {
        xdg_toplevel_destroy(toplevel);
        toplevel = NULL;
    }
    if (shell_surface) {
        xdg_surface_destroy(shell_surface);
        shell_surface = NULL;
    }
    if (surface) {
        wl_surface_destroy(surface);
        surface = NULL;
    }
    if (shell) {
        xdg_wm_base_destroy(shell);
        shell = NULL;
    }
    if (compositor) {
        wl_compositor_destroy(compositor);
        compositor = NULL;
    }
    if (registry) {
        wl_registry_destroy(registry);
        registry = NULL;
    }
    if (display) {
        wl_display_disconnect(display);
        display = NULL;
    }
}

struct wl_display* get_wayland_display(void) {
    return display;
}

struct wl_surface* get_wayland_surface(void) {
    return surface;
}

int wayland_should_quit(void) {
    return quit;
}

void wayland_poll_events(void) {
    if (display) {
        wl_display_dispatch_pending(display);
        wl_display_roundtrip(display);
    }
}