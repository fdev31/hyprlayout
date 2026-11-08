-- Wayland native in-process screen capture via FFI.
-- Embeds C source, compiles at runtime (same pattern as debug.lua).
-- Eliminates the grim subprocess by speaking ext-image-copy-capture-v1 directly.
local M = {}

local ffi = require("ffi")
local debug = require("core.debug")

local lib = nil
local initialized = false

local C_SOURCE = [[
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
 *
 * The types field in struct wl_message is `const struct wl_interface **`.
 * For each argument in the signature, there is a corresponding entry in
 * the types array: a pointer to the wl_interface for `o`/`n` args, or
 * NULL for primitive types (i, u, f, s, a, h).
 * ------------------------------------------------------------------ */

/* linux_dmabuf_buffer (no object dependencies) */
static const struct wl_interface *dmabuf_parameters_types[] = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL  /* h u u u u u u */
};
static const struct wl_message linux_dmabuf_buffer_events[] = {
    { "parameters", "huiiuuu", dmabuf_parameters_types },
};
static const struct wl_interface linux_dmabuf_buffer_interface = {
    "linux_dmabuf_buffer", 1, 0, NULL, 1, linux_dmabuf_buffer_events
};

/* zxdg_toplevel_capture_v1 (depends on linux_dmabuf_buffer) */
static const struct wl_interface *frame_buffer_types[] = {
    &linux_dmabuf_buffer_interface,
    NULL
};
static const struct wl_message zxdg_toplevel_capture_v1_events[] = {
    { "buffer", "o", frame_buffer_types },
    { "done", "", NULL },
};
static const struct wl_interface zxdg_toplevel_capture_v1_interface = {
    "zxdg_toplevel_capture_v1", 1, 0, NULL, 2, zxdg_toplevel_capture_v1_events
};

/* zxdg_output_v1 (depends on zxdg_toplevel_capture_v1) */
static const struct wl_interface *capture_frame_types[] = {
    &zxdg_toplevel_capture_v1_interface,
    NULL
};
static const struct wl_message zxdg_output_v1_methods[] = {
    { "capture_frame", "n", capture_frame_types },
    { "destroy", "", NULL },
};
static const struct wl_interface zxdg_output_v1_interface = {
    "zxdg_output_v1", 1, 2, zxdg_output_v1_methods, 0, NULL
};

/* ext_image_capture_v1 (depends on wl_output and zxdg_output_v1) */
static const struct wl_interface *create_output_types[] = {
    &wl_output_interface,
    &zxdg_output_v1_interface,
    NULL
};
static const struct wl_message ext_image_capture_v1_methods[] = {
    { "create_output", "on", create_output_types },
};
static const struct wl_interface ext_image_capture_v1_interface = {
    "ext_image_capture_v1", 1, 1, ext_image_capture_v1_methods, 0, NULL
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
    (void)data; (void)version;
    if (strcmp(interface, "ext_image_capture_v1") == 0) {
        g_capture_v1 = (struct wl_proxy *)wl_registry_bind(reg, name,
                                         &ext_image_capture_v1_interface, 1);
    } else if (strcmp(interface, "wl_output") == 0) {
        if (!g_output) {
            g_output = (struct wl_output *)wl_registry_bind(reg, name,
                                                              &wl_output_interface, 2);
        }
    }
}

static const struct wl_registry_listener registry_listener = {
    .global        = registry_global,
    .global_remove = NULL,
};

static void output_geometry(void *data, struct wl_output *out,
                            int32_t x, int32_t y, int32_t w, int32_t h,
                            int32_t subpixel, const char *make, const char *model,
                            int32_t transform)
{
    (void)data; (void)out; (void)x; (void)y; (void)w; (void)h;
    (void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *data, struct wl_output *out,
                        uint32_t flags, int32_t w, int32_t h,
                        int32_t refresh)
{
    (void)data; (void)out; (void)flags; (void)w; (void)h;
    (void)refresh;
}

static void output_done(void *data, struct wl_output *out)
{
    (void)data; (void)out;
}

static const struct wl_output_listener output_listener = {
    .geometry    = output_geometry,
    .mode        = output_mode,
    .done        = output_done,
    .scale       = NULL,
    .name        = NULL,
    .description = NULL,
};

/* Custom listener structs for our protocol objects.
 * wl_proxy_add_listener expects `void (**)(void)` as the implementation
 * array, so we cast our listener structs to that type (same pattern
 * used by the generated protocol wrappers). */
struct frame_listener {
    void (*buffer)(void *data, struct wl_proxy *frame, struct wl_proxy *buffer);
    void (*done)(void *data, struct wl_proxy *frame);
};

struct dmabuf_listener {
    void (*parameters)(void *data, struct wl_proxy *buffer,
                        int32_t fd, uint32_t width, uint32_t height,
                        uint32_t format, uint32_t offset,
                        uint32_t stride, uint32_t plane_idx);
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

static const struct dmabuf_listener dmabuf_buffer_listener = {
    .parameters = dmabuf_parameters,
};

static void frame_buffer(void *data, struct wl_proxy *frame,
                          struct wl_proxy *buffer)
{
    (void)data; (void)frame;
    wl_proxy_add_listener(buffer, (void (**)(void)) &dmabuf_buffer_listener, NULL);
}

static void frame_done(void *data, struct wl_proxy *frame)
{
    (void)data; (void)frame;
    g_frame_done = 1;
}

static const struct frame_listener frame_listener = {
    .buffer = frame_buffer,
    .done   = frame_done,
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
        g_display  = NULL;
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
    struct wl_proxy *zxdg_output = wl_proxy_marshal_constructor(
        g_capture_v1, 0, &zxdg_output_v1_interface, g_output);
    if (!zxdg_output)
        return -1;

    /* Request a frame capture */
    struct wl_proxy *frame = wl_proxy_marshal_constructor(
        zxdg_output, 0, &zxdg_toplevel_capture_v1_interface);
    if (!frame) {
        wl_proxy_destroy(zxdg_output);
        return -1;
    }

    /* Set up listener on the frame */
    wl_proxy_add_listener(frame, (void (**)(void)) &frame_listener, NULL);

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
]]

local function file_exists(p)
	local f = io.open(p, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

local function get_cache_dir()
	local base = os.getenv("XDG_CACHE_HOME")
	if not base or base == "" then
		base = (os.getenv("HOME") or "/tmp") .. "/.cache"
	end
	return base .. "/hyprlayout"
end

local function compile_and_load()
	local cache_dir = get_cache_dir()
	local so_path = cache_dir .. "/wayland_capture.so"

	if not file_exists(so_path) then
		os.execute(string.format("mkdir -p %q", cache_dir))
		local tmp_c = cache_dir .. "/wayland_capture.c"
		local f = io.open(tmp_c, "wb")
		if not f then
			debug.log("wayland_capture: could not write C source")
			return nil
		end
		f:write(C_SOURCE)
		f:close()

		local cc = "cc"
		if os.execute("command -v gcc > /dev/null 2>&1") == 0 then
			cc = "gcc"
		end
		local rc = os.execute(string.format("%s -shared -fPIC -O2 -o %q %q -lwayland-client 2>&1", cc, so_path, tmp_c))
		if rc ~= 0 or not file_exists(so_path) then
			debug.log("wayland_capture: compile failed (rc=%d)", rc)
			return nil
		end
	end

	local ok, loaded_lib = pcall(ffi.load, so_path)
	if not ok then
		debug.log("wayland_capture: ffi.load failed: %s", tostring(loaded_lib))
		return nil
	end
	return loaded_lib
end

function M.detect()
	if lib then
		return true
	end
	lib = compile_and_load()
	if not lib then
		debug.log("wayland_capture: NOT available")
		return false
	end

	ffi.cdef([[
		int  wlcap_init(void);
		void wlcap_shutdown(void);
		int  wlcap_capture(const char *output_name, int *w, int *h,
		                    int *stride, int *size, void **data);
		void wlcap_free(void *data);
	]])

	local ok, rc = pcall(function()
		return lib.wlcap_init()
	end)
	if not ok or rc ~= 0 then
		debug.log("wayland_capture: init failed (rc=%s)", tostring(rc))
		lib = nil
		return false
	end

	initialized = true
	debug.log("wayland_capture: initialized (in-process, zero-copy)")
	return true
end

function M.capture(output_name)
	if not initialized or not lib then
		return nil
	end

	local w = ffi.new("int[1]")
	local h = ffi.new("int[1]")
	local stride = ffi.new("int[1]")
	local size = ffi.new("int[1]")
	local data = ffi.new("void*[1]")

	local ok, rc = pcall(function()
		return lib.wlcap_capture(output_name, w, h, stride, size, data)
	end)

	if not ok or rc ~= 0 then
		debug.log("wayland_capture: capture failed for %s (rc=%s)", output_name, tostring(rc))
		return nil
	end

	local ptr = data[0]
	if not ptr then
		return nil
	end

	local bytes = ffi.string(ptr, size[0])
	lib.wlcap_free(ptr)

	debug.log("wayland_capture: ok %s %dx%d stride=%d (%d bytes)", output_name, w[0], h[0], stride[0], size[0])

	return {
		width = w[0],
		height = h[0],
		stride = stride[0],
		size = size[0],
		data = bytes,
		format = "bgra",
	}
end

function M.shutdown()
	if initialized and lib then
		pcall(function()
			lib.wlcap_shutdown()
		end)
		initialized = false
	end
end

return M
