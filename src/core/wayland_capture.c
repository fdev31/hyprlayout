/* wayland_capture.c - In-process Wayland screen capture
 *
 * Implements ext-image-copy-capture-v1 + linux-dmabuf for zero-copy frame capture.
 * Compiled as a shared library, loaded via LuaJIT FFI.
 *
 * Build: cc -shared -fPIC -O2 -o wayland_capture.so wayland_capture.c -lwayland-client
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <sys/mman.h>
#include <wayland-client.h>

/* ------------------------------------------------------------------
 * Protocol interface definitions (manual, no code generation)
 * ------------------------------------------------------------------ */

static const struct wl_message ext_image_capture_v1_methods[] = {
    { "create_output", "o&", 1 },
};
static const struct wl_interface ext_image_capture_v1_interface = {
    "ext_image_capture_v1", 1, 1, ext_image_capture_v1_methods, 0, NULL
};

static const struct wl_message zxdg_output_v1_methods[] = {
    { "capture_frame", "&", 0 },
    { "destroy", "", 0 },
};
static const struct wl_interface zxdg_output_v1_interface = {
    "zxdg_output_v1", 1, 2, zxdg_output_v1_methods, 0, NULL
};

static const struct wl_message zxdg_toplevel_capture_v1_events[] = {
    { "buffer", "n", 1 },
    { "done", "", 0 },
};
static const struct wl_interface zxdg_toplevel_capture_v1_interface = {
    "zxdg_toplevel_capture_v1", 1, 0, NULL, 2, zxdg_toplevel_capture_v1_events
};

static const struct wl_message linux_dmabuf_buffer_events[] = {
    { "parameters", "iuiiiiu", 7 },
};
static const struct wl_interface linux_dmabuf_buffer_interface = {
    "linux_dmabuf_buffer", 1, 0, NULL, 1, linux_dmabuf_buffer_events
};

/* ------------------------------------------------------------------
 * Global state
 * ------------------------------------------------------------------ */

static struct wl_display  *g_display     = NULL;
static struct wl_registry  *g_registry    = NULL;
static struct wl_proxy     *g_capture_v1  = NULL;
static struct wl_output    *g_output      = NULL;
static int                  g_initialized = 0;

/* Per-capture frame state */
static int    g_fd         = -1;
static int    g_width      = 0;
static int    g_height     = 0;
static int    g_stride     = 0;
static int    g_format     = 0;
static void  *g_map        = NULL;
static size_t g_map_size   = 0;
static int    g_frame_done = 0;

/* ------------------------------------------------------------------
 * Wayland event listeners
 * ------------------------------------------------------------------ */

static void registry_global(void *data, struct wl_registry *reg,
                             uint32_t name, const char *interface, uint32_t version)
{
    (void)data; (void)name; (void)version;
    if (strcmp(interface, "ext_image_capture_v1") == 0) {
        g_capture_v1 = wl_registry_bind(reg, name,
                                         &ext_image_capture_v1_interface, 1);
    } else if (strcmp(interface, "wl_output") == 0) {
        if (!g_output) {
            g_output = wl_registry_bind(reg, name, &wl_output_interface, 2);
        }
    }
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
};

static void output_geometry(void *data, struct wl_output *out,
                            int32_t x, int32_t y, int32_t w, int32_t h,
                            int32_t subpixel, const char *make, const char *model,
                            const char *type, int32_t mm_w, int32_t mm_h,
                            int32_t refresh, int32_t scale)
{
    (void)data; (void)out; (void)x; (void)y; (void)w; (void)h;
    (void)subpixel; (void)make; (void)model; (void)type;
    (void)mm_w; (void)mm_h; (void)refresh; (void)scale;
}

static void output_mode(void *data, struct wl_output *out,
                        int32_t flags, int32_t w, int32_t h,
                        int32_t refresh, int32_t current)
{
    (void)data; (void)out; (void)flags; (void)w; (void)h;
    (void)refresh; (void)current;
}

static void output_done(void *data, struct wl_output *out)
{
    (void)data; (void)out;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode     = output_mode,
    .done     = output_done,
};

/* Forward declaration */
static const struct wl_listener dmabuf_buffer_listener;

static void frame_buffer(void *data, struct wl_proxy *frame,
                          struct wl_proxy *buffer)
{
    (void)data; (void)frame;
    wl_proxy_add_listener(buffer, &dmabuf_buffer_listener, NULL);
}

static void frame_done(void *data, struct wl_proxy *frame)
{
    (void)data; (void)frame;
    g_frame_done = 1;
}

static const struct wl_listener frame_listener = {
    .buffer = frame_buffer,
    .done   = frame_done,
};

static void dmabuf_parameters(void *data, struct wl_proxy *buffer,
                               int32_t fd, uint32_t width, uint32_t height,
                               uint32_t format, uint32_t offset,
                               uint32_t stride, uint32_t plane_idx)
{
    (void)data; (void)buffer; (void)offset; (void)plane_idx;
    g_fd     = fd;
    g_width  = (int)width;
    g_height = (int)height;
    g_stride = (int)stride;
    g_format = (int)format;
}

static const struct wl_listener dmabuf_buffer_listener = {
    .parameters = dmabuf_parameters,
};

/* ------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------ */

int wlcap_init(void)
{
    if (g_initialized)
        return 0;

    g_display = wl_display_connect(NULL);
    if (!g_display)
        return -1;

    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);

    /* Dispatch to receive all globals */
    wl_display_dispatch(g_display);
    wl_display_flush(g_display);

    /* Add output listener for the first output we found */
    if (g_output) {
        wl_output_add_listener(g_output, &output_listener, NULL);
    }

    if (!g_capture_v1) {
        wl_display_disconnect(g_display);
        g_display = NULL;
        g_registry = NULL;
        return -1;
    }

    g_initialized = 1;
    return 0;
}

void wlcap_shutdown(void)
{
    if (!g_initialized)
        return;

    if (g_output)
        wl_output_destroy(g_output);
    if (g_capture_v1)
        wl_proxy_destroy(g_capture_v1);
    if (g_registry)
        wl_registry_destroy(g_registry);
    if (g_display)
        wl_display_disconnect(g_display);

    g_display     = NULL;
    g_registry    = NULL;
    g_capture_v1  = NULL;
    g_output      = NULL;
    g_initialized = 0;
}

int wlcap_capture(const char *output_name, int *w, int *h,
                   int *stride, int *size, void **data)
{
    if (!g_initialized || !g_output)
        return -1;

    (void)output_name; /* TODO: multi-monitor selection */

    /* Reset frame state */
    g_fd         = -1;
    g_width      = 0;
    g_height     = 0;
    g_stride     = 0;
    g_format     = 0;
    g_map        = NULL;
    g_map_size   = 0;
    g_frame_done = 0;

    /* Create the zxdg_output for capture */
    struct wl_proxy *zxdg_output = wl_proxy_marshal(g_capture_v1, 0, g_output);
    if (!zxdg_output)
        return -1;

    /* Request a frame capture */
    struct wl_proxy *frame = wl_proxy_marshal(zxdg_output, 0);
    if (!frame) {
        wl_proxy_destroy(zxdg_output);
        return -1;
    }

    /* Set up listener on the frame */
    wl_proxy_add_listener(frame, &frame_listener, NULL);

    /* Flush and dispatch until we get the frame */
    wl_display_flush(g_display);

    /* Event loop with timeout (~5 seconds) */
    struct pollfd pfd = { .fd = wl_display_get_fd(g_display), .events = POLLIN };
    int max_iter = 500;

    while (!g_frame_done && max_iter-- > 0) {
        int ret = poll(&pfd, 1, 10);
        if (ret > 0) {
            wl_display_dispatch(g_display);
        }
        if (g_frame_done)
            break;
    }

    if (!g_frame_done || g_fd < 0) {
        wl_proxy_destroy(frame);
        wl_proxy_destroy(zxdg_output);
        return -1;
    }

    /* Map the dmabuf into our address space (zero-copy) */
    g_map_size = (size_t)g_stride * g_height;
    g_map = mmap(NULL, g_map_size, PROT_READ, MAP_PRIVATE, g_fd, 0);
    if (g_map == MAP_FAILED) {
        close(g_fd);
        g_fd = -1;
        wl_proxy_destroy(frame);
        wl_proxy_destroy(zxdg_output);
        return -1;
    }

    close(g_fd);
    g_fd = -1;

    wl_proxy_destroy(frame);
    wl_proxy_destroy(zxdg_output);

    /* Output results */
    *w = g_width;
    *h = g_height;
    *stride = g_stride;
    *size = (int)g_map_size;
    *data = g_map;

    return 0;
}

void wlcap_free(void *data)
{
    if (data && data != MAP_FAILED) {
        munmap(data, g_map_size);
    }
    g_map      = NULL;
    g_map_size = 0;
}
