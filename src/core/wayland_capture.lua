-- Wayland native screen capture via ext-image-copy-capture-v1 + linux-dmabuf.
-- Compiles and loads a C shared library at runtime (same pattern as debug.lua).
-- Provides in-process frame capture as a higher-priority alternative to `grim`.

local M = {}

local ffi = require("ffi")
local debug = require("core.debug")

local lib = nil
local initialized = false
local detect_done = false

-- The C source for the Wayland capture backend.
local C_SOURCE = [[
/*
 * wayland_capture.c — Wayland screen capture via ext-image-copy-capture-v1
 *
 * This shared library implements the ext-image-copy-capture-v1 protocol
 * combined with the linux-dmabuf protocol to capture screen frames from
 * a Wayland compositor. The captured pixel data is delivered as mmap'd
 * BGRA (ARGB8888) frames.
 *
 * Build:
 *   cc -shared -fPIC -O2 -o wayland_capture.so wayland_capture.c -lwayland-client
 *
 * Public API:
 *   int  wlcap_init(void)
 *   void wlcap_shutdown(void)
 *   int  wlcap_capture(const char *output_name, int *w, int *h,
 *                       int *stride, int *size, void **data)
 *   void wlcap_free(void *data)
 */

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <poll.h>
#include <sys/mman.h>
#include <errno.h>
#include <time.h>

#include <wayland-client.h>

/* ------------------------------------------------------------------ */
/* Protocol constants                                                   */
/* ------------------------------------------------------------------ */

/* DRM format: ARGB8888 — in memory on little-endian this is BGRA */
#define DRM_FORMAT_ARGB8888  0x34325244u

/* Interface name strings */
#define IFACE_EXT_IMAGE_CAPTURE_V1     "ext_image_capture_v1"
#define IFACE_ZXDG_OUTPUT_V1           "zxdg_output_v1"
#define IFACE_ZXDG_TOPLEVEL_CAPTURE_V1 "zxdg_toplevel_capture_v1"
#define IFACE_LINUX_DMABUF             "linux_dmabuf"
#define IFACE_LINUX_DMABUF_BUFFER      "linux_dmabuf_buffer"

/* Opcodes */
#define EXT_IMAGE_CAPTURE_CREATE_OUTPUT   0
#define ZXDG_OUTPUT_CAPTURE_FRAME         0
#define ZXDG_TOPLEVEL_EVT_BUFFER          0
#define ZXDG_TOPLEVEL_EVT_DONE            1
#define ZXDG_TOPLEVEL_EVT_FAILED          2
#define LINUX_DMABUF_EVT_BUFFER           0
#define LINUX_DMABUF_BUFFER_DESTROY       0

/* ------------------------------------------------------------------ */
/* Manual wl_interface definitions (no codegen)                         */
/* ------------------------------------------------------------------ */
/*
 * struct wl_message: { name, signature, types }
 * struct wl_interface: { name, version, method_count, methods,
 *                        event_count, events }
 *
 * We set types=NULL since we use wl_proxy_marshal directly and do not
 * rely on the automatic marshalling machinery.
 */

static const struct wl_message ext_image_capture_methods[] = {
    { "create_output", "ni", NULL },
};
static const struct wl_interface ext_image_capture_v1_iface = {
    IFACE_EXT_IMAGE_CAPTURE_V1, 1,
    1, ext_image_capture_methods,
    0, NULL,
};

static const struct wl_message zxdg_output_methods[] = {
    { "capture_frame", "n", NULL },
};
static const struct wl_interface zxdg_output_v1_iface = {
    IFACE_ZXDG_OUTPUT_V1, 1,
    1, zxdg_output_methods,
    0, NULL,
};

static const struct wl_message zxdg_toplevel_capture_events[] = {
    { "buffer",  "n",  NULL },
    { "done",    "",   NULL },
    { "failed",  "",   NULL },
};
static const struct wl_interface zxdg_toplevel_capture_v1_iface = {
    IFACE_ZXDG_TOPLEVEL_CAPTURE_V1, 1,
    0, NULL,
    3, zxdg_toplevel_capture_events,
};

static const struct wl_message linux_dmabuf_events[] = {
    { "buffer", "nixiiiii", NULL },
};
static const struct wl_interface linux_dmabuf_iface = {
    IFACE_LINUX_DMABUF, 3,
    0, NULL,
    1, linux_dmabuf_events,
};

static const struct wl_message linux_dmabuf_buffer_methods[] = {
    { "destroy", "", NULL },
};
static const struct wl_interface linux_dmabuf_buffer_iface = {
    IFACE_LINUX_DMABUF_BUFFER, 1,
    1, linux_dmabuf_buffer_methods,
    0, NULL,
};

/* ------------------------------------------------------------------ */
/* Global state                                                         */
/* ------------------------------------------------------------------ */

#define MAX_OUTPUTS 16

static struct wl_display   *g_display       = NULL;
static struct wl_registry  *g_registry      = NULL;
static struct wl_proxy     *g_ext_capture   = NULL;
static struct wl_proxy     *g_dmabuf        = NULL;
static struct wl_proxy     *g_outputs[MAX_OUTPUTS] = { NULL };
static int                  g_num_outputs   = 0;

/* Per-frame state */
static int                  g_frame_fd      = -1;
static uint32_t             g_frame_width   = 0;
static uint32_t             g_frame_height  = 0;
static uint32_t             g_frame_stride  = 0;
static uint32_t             g_frame_offset  = 0;
static uint32_t             g_frame_format  = 0;
static void                 *g_frame_map    = NULL;
static size_t               g_frame_size    = 0;
static int                  g_frame_done    = 0;
static int                  g_frame_failed  = 0;

/* Output name storage (populated from wl_output 'output' event) */
static char g_output_names[MAX_OUTPUTS][256];

/* ------------------------------------------------------------------ */
/* Event handlers                                                       */
/* ------------------------------------------------------------------ */

/*
 * wl_output "output" event:
 *   (string name, object head, int x, int y, int width, int height,
 *    int refresh, string make, string model, int transform, int scale)
 */
static void output_event(void *data, struct wl_proxy *proxy,
                         const char *name, struct wl_proxy *head,
                         int32_t x, int32_t y, int32_t width, int32_t height,
                         int32_t refresh, const char *make,
                         const char *model, int32_t transform,
                         int32_t scale)
{
    (void)head; (void)x; (void)y; (void)width; (void)height;
    (void)refresh; (void)make; (void)model; (void)transform; (void)scale;

    int idx = (int)(intptr_t)data;
    if (idx >= 0 && idx < MAX_OUTPUTS && name) {
        strncpy(g_output_names[idx], name, sizeof(g_output_names[idx]) - 1);
        g_output_names[idx][sizeof(g_output_names[idx]) - 1] = '\0';
    }
}

static const void *output_handlers[] = {
    output_event,
    NULL
};

/*
 * registry "global" event:
 *   (uint name, string interface, uint version)
 */
static void registry_global_event(void *data, struct wl_proxy *proxy,
                                  uint32_t name,
                                  const char *interface,
                                  uint32_t version)
{
    (void)data; (void)proxy; (void)version;

    if (strcmp(interface, "wl_output") == 0) {
        if (g_num_outputs < MAX_OUTPUTS) {
            int idx = g_num_outputs;
            struct wl_proxy *out = wl_proxy_create(NULL, &wl_output_interface);
            if (out) {
                wl_proxy_add_listener(out,
                    (void (**)(void))output_handlers,
                    (void *)(intptr_t)idx);
                g_outputs[idx] = out;
                g_num_outputs++;
            }
        }
    }
}

static const void *registry_handlers[] = {
    registry_global_event,
    NULL
};

/*
 * zxdg_toplevel_capture_v1 "buffer" event:
 *   (new_id linux_dmabuf_buffer)
 */
static void toplevel_buffer_event(void *data, struct wl_proxy *proxy,
                                  struct wl_proxy *buffer)
{
    (void)data; (void)proxy; (void)buffer;
    /* The dmabuf buffer event carries the actual data; this is just
     * the buffer object handle which we don't need directly. */
}

/*
 * zxdg_toplevel_capture_v1 "done" event: no args
 */
static void toplevel_done_event(void *data, struct wl_proxy *proxy)
{
    (void)data; (void)proxy;
    g_frame_done = 1;
}

/*
 * zxdg_toplevel_capture_v1 "failed" event: no args
 */
static void toplevel_failed_event(void *data, struct wl_proxy *proxy)
{
    (void)data; (void)proxy;
    g_frame_failed = 1;
}

static const void *toplevel_capture_handlers[] = {
    toplevel_buffer_event,
    toplevel_done_event,
    toplevel_failed_event,
    NULL
};

/*
 * linux_dmabuf "buffer" event:
 *   (new_id linux_dmabuf_buffer, int fd, uint width, uint height,
 *    uint format, uint offset, uint stride, uint plane_idx)
 */
static void dmabuf_buffer_event(void *data, struct wl_proxy *proxy,
                                struct wl_proxy *buffer,
                                int fd, uint32_t width, uint32_t height,
                                uint32_t format, uint32_t offset,
                                uint32_t stride, uint32_t plane_idx)
{
    (void)data; (void)proxy; (void)buffer; (void)plane_idx;

    g_frame_fd     = fd;
    g_frame_width  = width;
    g_frame_height = height;
    g_frame_format = format;
    g_frame_offset = offset;
    g_frame_stride = stride;
}

static const void *dmabuf_handlers[] = {
    dmabuf_buffer_event,
    NULL
};

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static struct wl_proxy *find_output(const char *name)
{
    if (name == NULL) {
        return (g_num_outputs > 0) ? g_outputs[0] : NULL;
    }
    for (int i = 0; i < g_num_outputs; i++) {
        if (strcmp(g_output_names[i], name) == 0)
            return g_outputs[i];
    }
    return NULL;
}

static int64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ------------------------------------------------------------------ */
/* Public API                                                           */
/* ------------------------------------------------------------------ */

int wlcap_init(void)
{
    if (g_display)
        return 0;

    g_display = wl_display_connect(NULL);
    if (!g_display) {
        fprintf(stderr, "wlcap: failed to connect to Wayland display\n");
        return -1;
    }

    g_registry = wl_display_get_registry(g_display);
    if (!g_registry) {
        fprintf(stderr, "wlcap: failed to get registry\n");
        wl_display_disconnect(g_display);
        g_display = NULL;
        return -1;
    }

    wl_proxy_add_listener((struct wl_proxy *)g_registry,
        (void (**)(void))registry_handlers, NULL);

    /* Bind ext_image_capture_v1 */
    g_ext_capture = wl_proxy_create((struct wl_proxy *)g_registry,
                                     &ext_image_capture_v1_iface);
    if (!g_ext_capture) {
        fprintf(stderr, "wlcap: failed to create ext_image_capture_v1\n");
        wl_display_disconnect(g_display);
        g_display = NULL;
        return -1;
    }
    wl_proxy_marshal(g_ext_capture, 0, IFACE_EXT_IMAGE_CAPTURE_V1);

    /* Bind linux_dmabuf */
    g_dmabuf = wl_proxy_create((struct wl_proxy *)g_registry,
                                &linux_dmabuf_iface);
    if (!g_dmabuf) {
        fprintf(stderr, "wlcap: failed to create linux_dmabuf\n");
        wl_display_disconnect(g_display);
        g_display = NULL;
        return -1;
    }
    wl_proxy_marshal(g_dmabuf, 0, IFACE_LINUX_DMABUF);

    wl_display_flush(g_display);

    return 0;
}

void wlcap_shutdown(void)
{
    if (g_frame_map) {
        munmap(g_frame_map, g_frame_size);
        g_frame_map = NULL;
    }
    if (g_frame_fd >= 0) {
        close(g_frame_fd);
        g_frame_fd = -1;
    }

    for (int i = 0; i < g_num_outputs; i++) {
        if (g_outputs[i]) {
            wl_proxy_destroy(g_outputs[i]);
            g_outputs[i] = NULL;
        }
    }
    g_num_outputs = 0;

    if (g_dmabuf) {
        wl_proxy_destroy(g_dmabuf);
        g_dmabuf = NULL;
    }
    if (g_ext_capture) {
        wl_proxy_destroy(g_ext_capture);
        g_ext_capture = NULL;
    }
    if (g_registry) {
        wl_proxy_destroy((struct wl_proxy *)g_registry);
        g_registry = NULL;
    }

    if (g_display) {
        wl_display_disconnect(g_display);
        g_display = NULL;
    }
}

int wlcap_capture(const char *output_name, int *w, int *h,
                  int *stride, int *size, void **data)
{
    if (!g_display) {
        fprintf(stderr, "wlcap: not initialized\n");
        return -1;
    }

    struct wl_proxy *wl_output = find_output(output_name);
    if (!wl_output) {
        fprintf(stderr, "wlcap: output '%s' not found\n",
                output_name ? output_name : "(null)");
        return -1;
    }

    /* Reset per-frame state */
    g_frame_fd     = -1;
    g_frame_width  = 0;
    g_frame_height = 0;
    g_frame_stride = 0;
    g_frame_offset = 0;
    g_frame_format = 0;
    g_frame_map    = NULL;
    g_frame_size   = 0;
    g_frame_done   = 0;
    g_frame_failed = 0;

    /* Create zxdg_output_v1 */
    struct wl_proxy *zxdg_output = wl_proxy_create(g_ext_capture,
                                                   &zxdg_output_v1_iface);
    if (!zxdg_output) {
        fprintf(stderr, "wlcap: failed to create zxdg_output_v1\n");
        return -1;
    }

    /* ext_image_capture_v1.create_output(new_id, wl_output) */
    wl_proxy_marshal(g_ext_capture, EXT_IMAGE_CAPTURE_CREATE_OUTPUT,
                     zxdg_output, wl_output);

    /* Create zxdg_toplevel_capture_v1 */
    struct wl_proxy *toplevel_capture = wl_proxy_create(zxdg_output,
                                                         &zxdg_toplevel_capture_v1_iface);
    if (!toplevel_capture) {
        fprintf(stderr, "wlcap: failed to create toplevel capture\n");
        wl_proxy_destroy(zxdg_output);
        return -1;
    }

    wl_proxy_add_listener(toplevel_capture,
        (void (**)(void))toplevel_capture_handlers, NULL);

    /* zxdg_output_v1.capture_frame(new_id) */
    wl_proxy_marshal(zxdg_output, ZXDG_OUTPUT_CAPTURE_FRAME,
                     toplevel_capture);

    /* Listen for dmabuf buffer events */
    wl_proxy_add_listener(g_dmabuf,
        (void (**)(void))dmabuf_handlers, NULL);

    wl_display_flush(g_display);

    /* Synchronous event loop with 5-second timeout */
    const int64_t timeout_ns = 5000000000LL;
    int64_t start = now_ns();
    int64_t deadline = start + timeout_ns;

    while (!g_frame_done && !g_frame_failed) {
        wl_display_dispatch(g_display);

        if (g_frame_done || g_frame_failed)
            break;

        int64_t remaining = deadline - now_ns();
        if (remaining <= 0) {
            fprintf(stderr, "wlcap: timeout waiting for frame\n");
            wl_proxy_destroy(toplevel_capture);
            wl_proxy_destroy(zxdg_output);
            return -1;
        }

        struct pollfd pfd;
        pfd.fd      = wl_display_get_fd(g_display);
        pfd.events  = POLLIN;
        pfd.revents = 0;

        int poll_ms = (int)(remaining / 1000000LL);
        if (poll_ms < 1)
            poll_ms = 1;

        int ret = poll(&pfd, 1, poll_ms);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "wlcap: poll failed: %s\n", strerror(errno));
            wl_proxy_destroy(toplevel_capture);
            wl_proxy_destroy(zxdg_output);
            return -1;
        }
        if (ret == 0 && now_ns() >= deadline) {
            fprintf(stderr, "wlcap: timeout waiting for frame\n");
            wl_proxy_destroy(toplevel_capture);
            wl_proxy_destroy(zxdg_output);
            return -1;
        }
    }

    wl_proxy_destroy(toplevel_capture);
    wl_proxy_destroy(zxdg_output);

    if (g_frame_failed) {
        fprintf(stderr, "wlcap: capture failed\n");
        return -1;
    }

    if (g_frame_format != DRM_FORMAT_ARGB8888) {
        fprintf(stderr, "wlcap: unsupported format 0x%08x\n",
                g_frame_format);
        if (g_frame_fd >= 0)
            close(g_frame_fd);
        g_frame_fd = -1;
        return -1;
    }

    size_t map_size = (size_t)g_frame_stride * g_frame_height;
    if (map_size == 0) {
        fprintf(stderr, "wlcap: zero-size frame\n");
        if (g_frame_fd >= 0)
            close(g_frame_fd);
        g_frame_fd = -1;
        return -1;
    }

    void *map = mmap(NULL, map_size, PROT_READ, MAP_PRIVATE, g_frame_fd, 0);
    if (map == MAP_FAILED) {
        fprintf(stderr, "wlcap: mmap failed: %s\n", strerror(errno));
        if (g_frame_fd >= 0)
            close(g_frame_fd);
        g_frame_fd = -1;
        return -1;
    }

    g_frame_map  = map;
    g_frame_size = map_size;

    *w      = (int)g_frame_width;
    *h      = (int)g_frame_height;
    *stride = (int)g_frame_stride;
    *size   = (int)g_frame_size;
    *data   = g_frame_map;

    return 0;
}

void wlcap_free(void *data)
{
    if (data == NULL)
        return;

    if (g_frame_map == data) {
        munmap(g_frame_map, g_frame_size);
        g_frame_map = NULL;
        g_frame_size = 0;

        if (g_frame_fd >= 0) {
            close(g_frame_fd);
            g_frame_fd = -1;
        }

        g_frame_width  = 0;
        g_frame_height = 0;
        g_frame_stride = 0;
        g_frame_offset = 0;
        g_frame_format = 0;
    }
}
]]

-- FFI type declarations for the C interface
local CDEF = [[
int wlcap_init(void);
void wlcap_shutdown(void);
int wlcap_capture(const char* output_name, int* w, int* h, int* stride, int* size, void** data);
void wlcap_free(void* data);
]]

-- Compute the cache directory and .so path (same pattern as debug.lua)
local function get_cache_paths()
	local cache_base = os.getenv("XDG_CACHE_HOME")
	if not cache_base or cache_base == "" then
		cache_base = (os.getenv("HOME") or "/tmp") .. "/.cache"
	end
	local cache_dir = cache_base .. "/hyprlayout"
	local so_path = cache_dir .. "/wayland_capture.so"
	local c_path = cache_dir .. "/wayland_capture.c"
	return cache_dir, so_path, c_path
end

local function file_exists(p)
	local f = io.open(p, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

-- Compile and load the shared library. Returns true on success.
local function compile_and_load()
	local cache_dir, so_path, c_path = get_cache_paths()

	-- If the .so already exists, just load it
	if not file_exists(so_path) then
		-- Ensure the cache directory exists
		os.execute(string.format("mkdir -p %q", cache_dir))

		-- Write the C source to a temp file
		local f = io.open(c_path, "wb")
		if not f then
			debug.log("wayland_capture: could not write C source to %s", c_path)
			return false
		end
		f:write(C_SOURCE)
		f:close()

		-- Compile
		local rc =
			os.execute(string.format("cc -shared -fPIC -O2 -o %q %q -lwayland-client 2>/dev/null", so_path, c_path))
		if rc ~= 0 or not file_exists(so_path) then
			debug.log("wayland_capture: compilation failed (rc=%d)", rc)
			return false
		end
	end

	-- Declare the C interface
	ffi.cdef(CDEF)

	-- Load the shared library
	local ok, l = pcall(ffi.load, so_path)
	if not ok or not l then
		debug.log("wayland_capture: failed to load library: %s", tostring(l))
		return false
	end

	lib = l
	return true
end

-- Returns true if Wayland native capture is available (library compiles and loads successfully).
-- Idempotent: repeated calls after a successful detect are no-ops.
function M.detect()
	if detect_done then
		return lib ~= nil
	end
	detect_done = true
	return compile_and_load()
end

-- Initialize the Wayland connection (call once at startup).
-- Returns true on success.
function M.init()
	if not lib then
		debug.log("wayland_capture: not detected, cannot init")
		return false
	end
	if initialized then
		return true
	end

	local ok, rc = pcall(lib.wlcap_init)
	if not ok then
		debug.log("wayland_capture: wlcap_init raised: %s", tostring(rc))
		return false
	end
	if rc ~= 0 then
		debug.log("wayland_capture: wlcap_init returned %d", rc)
		return false
	end

	initialized = true
	debug.log("wayland_capture: initialized")
	return true
end

-- Shutdown the Wayland connection (call at exit).
function M.shutdown()
	if not initialized then
		return
	end
	initialized = false

	local ok = pcall(lib.wlcap_shutdown)
	if not ok then
		debug.log("wayland_capture: wlcap_shutdown raised")
	end
end

-- Capture a frame from the named output.
-- Returns {width, height, stride, size, data} where data is a cdata pointer to BGRA pixels.
-- Returns nil on failure.
function M.capture(output_name)
	if not initialized then
		debug.log("wayland_capture: not initialized, cannot capture")
		return nil
	end

	-- Prepare FFI output parameters
	local w = ffi.new("int[1]")
	local h = ffi.new("int[1]")
	local stride = ffi.new("int[1]")
	local size = ffi.new("int[1]")
	local data = ffi.new("void*[1]")

	local ok, rc = pcall(lib.wlcap_capture, output_name, w, h, stride, size, data)
	if not ok then
		debug.log("wayland_capture: wlcap_capture raised: %s", tostring(rc))
		return nil
	end
	if rc ~= 0 then
		debug.log("wayland_capture: capture failed for output '%s'", output_name)
		return nil
	end

	return {
		width = w[0],
		height = h[0],
		stride = stride[0],
		size = size[0],
		data = data[0],
	}
end

-- Free a previously captured frame.
function M.free(result)
	if not result or not result.data then
		return
	end
	local ok = pcall(lib.wlcap_free, result.data)
	if not ok then
		debug.log("wayland_capture: wlcap_free raised")
	end
end

return M
