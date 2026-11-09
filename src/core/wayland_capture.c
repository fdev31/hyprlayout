/* wayland_capture.c - Wayland screen capture
 *
 * Implements ext-image-copy-capture-v1 with wlr-screencopy as a fallback
 * protocol, and ext-foreign-toplevel capture for compositors that do not
 * advertise a wl_output global (e.g. Umbriel).  The client allocates the
 * capture buffer via wl_shm (memfd + mmap), which is the path proven to work
 * on NVIDIA GPUs where the gbm/dmabuf path segfaults.
 *
 * Built as a standalone executable (child process).
 *
 * Protocol (stdin/stdout):
 *   child -> parent:  PROTOCOL <name>\n
 *   child -> parent:  READY\n
 *   parent -> child:  CAPTURE <output_name> [scale]\n
 *   child -> parent:  OK <w> <h> <stride>\n<raw BGRA bytes>
 *   child -> parent:  ERR <reason>\n
 *   parent -> child:  QUIT\n
 *
 * If the child segfaults, the parent detects the broken pipe and falls back
 * to the grim subprocess.  The next capture respawns a fresh child.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <linux/memfd.h>
#include <wayland-client.h>
#include <libdrm/drm_fourcc.h>

#include "protocol/ext-image-copy-capture.h"
#include "protocol/ext-image-capture-source.h"
#include "protocol/wlr-screencopy.h"
#include "protocol/ext-foreign-toplevel-list.h"

/* ---------------------------------------------------------------------------
 * Globals
 * ------------------------------------------------------------------------- */

static struct wl_display *display = NULL;
static struct wl_shm *shm = NULL;

static struct ext_image_copy_capture_manager_v1 *capture_manager = NULL;
static struct ext_output_image_capture_source_manager_v1 *source_manager = NULL;
static struct zwlr_screencopy_manager_v1 *wlr_manager = NULL;

static int use_ext = 0;
static int use_wlr = 0;
static int use_toplevel = 0;

#define MAX_OUTPUTS 16

struct output_info {
	struct wl_output *output;
	char name[256];
	int name_set;
};

static struct output_info outputs[MAX_OUTPUTS];
static int output_count = 0;

/* Foreign toplevel capture (no wl_output required). */
static struct ext_foreign_toplevel_list_v1 *toplevel_list = NULL;
static struct ext_foreign_toplevel_image_capture_source_manager_v1 *toplevel_source_manager = NULL;

#define MAX_TOPLEVELS 64
static struct ext_foreign_toplevel_handle_v1 *toplevels[MAX_TOPLEVELS];
static int toplevel_count = 0;

/* Capture state (shared between listener callbacks and the capture flow). */
struct cap_state {
	int session_done;
	int frame_ready;
	int frame_failed;
	uint32_t format;      /* dmabuf format (DRM fourcc), from dmabuf-format event */
	uint32_t shm_format;  /* wl_shm.format value, from shm-format / buffer event */
	int shm_format_set;
	uint32_t width, height;
	int32_t stride;
	struct wl_buffer *buffer;
	void *map;            /* mmap'd SHM pixels */
	size_t map_size;
	int fd;
	char err[256];
};

static struct cap_state cap;

/* Forward declaration. */
static int dispatch_timeout(int ms);

/* ---------------------------------------------------------------------------
 * Listener callbacks
 * ------------------------------------------------------------------------- */

static void output_geometry(void *data, struct wl_output *output,
			    int32_t x, int32_t y,
			    int32_t physical_width, int32_t physical_height,
			    int32_t subpixel, const char *make,
			    const char *model, int32_t transform)
{
	(void)data; (void)output; (void)x; (void)y;
	(void)physical_width; (void)physical_height;
	(void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *data, struct wl_output *output,
			uint32_t flags, int32_t width, int32_t height,
			int32_t refresh)
{
	(void)data; (void)output; (void)flags;
	(void)width; (void)height; (void)refresh;
}

static void output_done(void *data, struct wl_output *output)
{
	(void)data; (void)output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor)
{
	(void)data; (void)output; (void)factor;
}

static void output_name(void *data, struct wl_output *output, const char *name)
{
	struct output_info *info = data;
	(void)output;
	if (name) {
		strncpy(info->name, name, sizeof(info->name) - 1);
		info->name_set = 1;
	}
}

static void output_description(void *data, struct wl_output *output,
			       const char *description)
{
	(void)data; (void)output; (void)description;
}

/* libwayland asserts if any listener entry is NULL, so every field
 * must be populated even when the event is unused. */
static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

/* --- ext-foreign-toplevel-list listener --- */

static void toplevel_new(void *data,
			 struct ext_foreign_toplevel_list_v1 *list,
			 struct ext_foreign_toplevel_handle_v1 *toplevel)
{
	(void)data; (void)list;
	if (toplevel_count < MAX_TOPLEVELS)
		toplevels[toplevel_count++] = toplevel;
}

static void toplevel_list_finished(void *data,
				   struct ext_foreign_toplevel_list_v1 *list)
{
	(void)data; (void)list;
}

static const struct ext_foreign_toplevel_list_v1_listener toplevel_list_listener = {
	.toplevel = toplevel_new,
	.finished = toplevel_list_finished,
};

/* --- ext-image-copy-capture session listener ---
 *
 * The session advertises both dmabuf and shm constraints.  We use the shm
 * path; the shm-format event carries a wl_shm.format value (0 = ARGB8888,
 * 1 = XRGB8888, otherwise a DRM fourcc).
 */

static void session_buffer_size(void *data,
				struct ext_image_copy_capture_session_v1 *session,
				uint32_t width, uint32_t height)
{
	(void)data; (void)session;
	cap.width = width;
	cap.height = height;
}

static void session_dmabuf_format(void *data,
				  struct ext_image_copy_capture_session_v1 *session,
				  uint32_t format, struct wl_array *modifiers)
{
	(void)data; (void)session; (void)modifiers;
	cap.format = format;
}

static void session_shm_format(void *data,
			       struct ext_image_copy_capture_session_v1 *session,
			       uint32_t format)
{
	(void)data; (void)session;
	cap.shm_format = format;
	cap.shm_format_set = 1;
}

static void session_dmabuf_device(void *data,
				  struct ext_image_copy_capture_session_v1 *session,
				  struct wl_array *device)
{
	(void)data; (void)session; (void)device;
}

static void session_done(void *data,
			 struct ext_image_copy_capture_session_v1 *session)
{
	(void)data; (void)session;
	cap.session_done = 1;
}

static void session_stopped(void *data,
			    struct ext_image_copy_capture_session_v1 *session)
{
	(void)data; (void)session;
	cap.frame_failed = 1;
	snprintf(cap.err, sizeof(cap.err), "session stopped");
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
	.buffer_size = session_buffer_size,
	.shm_format = session_shm_format,
	.dmabuf_device = session_dmabuf_device,
	.dmabuf_format = session_dmabuf_format,
	.done = session_done,
	.stopped = session_stopped,
};

/* --- ext-image-copy-capture frame listener --- */

static void frame_transform(void *data,
			    struct ext_image_copy_capture_frame_v1 *frame,
			    uint32_t transform)
{
	(void)data; (void)frame; (void)transform;
}

static void frame_damage(void *data,
			 struct ext_image_copy_capture_frame_v1 *frame,
			 int32_t x, int32_t y, int32_t width, int32_t height)
{
	(void)data; (void)frame; (void)x; (void)y; (void)width; (void)height;
}

static void frame_presentation_time(void *data,
				    struct ext_image_copy_capture_frame_v1 *frame,
				    uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec)
{
	(void)data; (void)frame; (void)tv_sec_hi; (void)tv_sec_lo; (void)tv_nsec;
}

static void frame_ready(void *data,
			struct ext_image_copy_capture_frame_v1 *frame)
{
	(void)data; (void)frame;
	cap.frame_ready = 1;
}

static void frame_failed(void *data,
			 struct ext_image_copy_capture_frame_v1 *frame,
			 uint32_t reason)
{
	(void)data; (void)frame; (void)reason;
	cap.frame_failed = 1;
	snprintf(cap.err, sizeof(cap.err), "frame capture failed");
}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
	.transform = frame_transform,
	.damage = frame_damage,
	.presentation_time = frame_presentation_time,
	.ready = frame_ready,
	.failed = frame_failed,
};

/* --- wlr-screencopy frame listener ---
 *
 * The compositor sends either linux_dmabuf (dmabuf path) or buffer (shm path).
 * We use the shm path; the buffer event carries a wl_shm.format value plus
 * the stride.
 */

static void wlr_frame_linux_dmabuf(void *data,
				   struct zwlr_screencopy_frame_v1 *frame,
				   uint32_t format,
				   uint32_t width, uint32_t height)
{
	(void)data; (void)frame;
	cap.format = format;
	cap.width = width;
	cap.height = height;
	cap.session_done = 1;
}

static void wlr_frame_buffer(void *data,
			     struct zwlr_screencopy_frame_v1 *frame,
			     uint32_t format,
			     uint32_t width, uint32_t height,
			     uint32_t stride)
{
	(void)data; (void)frame;
	cap.shm_format = format;
	cap.shm_format_set = 1;
	cap.width = width;
	cap.height = height;
	cap.stride = (int32_t)stride;
	cap.session_done = 1;
}

static void wlr_frame_flags(void *data,
			    struct zwlr_screencopy_frame_v1 *frame,
			    uint32_t flags)
{
	(void)data; (void)frame; (void)flags;
}

static void wlr_frame_damage(void *data,
			     struct zwlr_screencopy_frame_v1 *frame,
			     uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
	(void)data; (void)frame; (void)x; (void)y; (void)width; (void)height;
}

static void wlr_frame_buffer_done(void *data,
				   struct zwlr_screencopy_frame_v1 *frame)
{
	(void)data; (void)frame;
}

static void wlr_frame_ready(void *data,
			    struct zwlr_screencopy_frame_v1 *frame,
			    uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec)
{
	(void)data; (void)frame; (void)tv_sec_hi; (void)tv_sec_lo; (void)tv_nsec;
	cap.frame_ready = 1;
}

static void wlr_frame_failed(void *data,
			     struct zwlr_screencopy_frame_v1 *frame)
{
	(void)data; (void)frame;
	cap.frame_failed = 1;
	snprintf(cap.err, sizeof(cap.err), "wlr frame capture failed");
}

static const struct zwlr_screencopy_frame_v1_listener wlr_frame_listener = {
	.buffer = wlr_frame_buffer,
	.flags = wlr_frame_flags,
	.ready = wlr_frame_ready,
	.failed = wlr_frame_failed,
	.damage = wlr_frame_damage,
	.linux_dmabuf = wlr_frame_linux_dmabuf,
	.buffer_done = wlr_frame_buffer_done,
};

/* --- registry listener --- */

static void registry_handle_global(void *data,
				   struct wl_registry *registry,
				   uint32_t name,
				   const char *interface,
				   uint32_t version)
{
	(void)data;

	if (strcmp(interface, "wl_shm") == 0) {
		shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, "wl_output") == 0) {
		if (output_count < MAX_OUTPUTS) {
			struct wl_output *output =
				wl_registry_bind(registry, name,
					&wl_output_interface, 4);
			int idx = output_count++;
			outputs[idx].output = output;
			outputs[idx].name[0] = '\0';
			outputs[idx].name_set = 0;
			wl_output_add_listener(output, &output_listener, &outputs[idx]);
		}
	} else if (strcmp(interface, "ext_image_copy_capture_manager_v1") == 0) {
		capture_manager = wl_registry_bind(registry, name,
			&ext_image_copy_capture_manager_v1_interface, 1);
		use_ext = 1;
	} else if (strcmp(interface, "ext_output_image_capture_source_manager_v1") == 0) {
		source_manager = wl_registry_bind(registry, name,
			&ext_output_image_capture_source_manager_v1_interface, 1);
	} else if (strcmp(interface, "zwlr_screencopy_manager_v1") == 0) {
		wlr_manager = wl_registry_bind(registry, name,
			&zwlr_screencopy_manager_v1_interface, 3);
		use_wlr = 1;
	} else if (strcmp(interface, "ext_foreign_toplevel_list_v1") == 0) {
		toplevel_list = wl_registry_bind(registry, name,
			&ext_foreign_toplevel_list_v1_interface, 1);
		ext_foreign_toplevel_list_v1_add_listener(toplevel_list,
			&toplevel_list_listener, NULL);
	} else if (strcmp(interface, "ext_foreign_toplevel_image_capture_source_manager_v1") == 0) {
		toplevel_source_manager = wl_registry_bind(registry, name,
			&ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1);
		use_toplevel = 1;
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_handle_global,
};

/* ---------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */

static struct output_info *find_output(const char *name)
{
	for (int i = 0; i < output_count; i++) {
		if (outputs[i].name_set && strcmp(outputs[i].name, name) == 0)
			return &outputs[i];
	}
	return NULL;
}

static void shm_cleanup(void)
{
	if (cap.buffer) {
		wl_buffer_destroy(cap.buffer);
		cap.buffer = NULL;
	}
	if (cap.map) {
		munmap(cap.map, cap.map_size);
		cap.map = NULL;
	}
	if (cap.fd >= 0) {
		close(cap.fd);
		cap.fd = -1;
	}
}

/*
 * Allocate a wl_shm buffer backed by a memfd.  The compositor fills the
 * mmap'd region with pixels in the given wl_shm.format.  Returns 0 on
 * success, -1 on failure.  On success, cap.buffer / cap.map / cap.fd /
 * cap.stride are set.
 */
static int shm_alloc(uint32_t format, uint32_t width, uint32_t height, int32_t stride)
{
	if (!shm)
		return -1;

	if (stride <= 0)
		stride = (int32_t)width * 4;

	int32_t size = stride * (int32_t)height;

	int fd = memfd_create("hyprlayout-screenshot", MFD_CLOEXEC | MFD_ALLOW_SEALING);
	if (fd < 0)
		return -1;

	if (ftruncate(fd, size) != 0) {
		close(fd);
		return -1;
	}

	void *map = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE,
			   MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		close(fd);
		return -1;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(
		pool, 0, (int32_t)width, (int32_t)height, stride, format);
	wl_shm_pool_destroy(pool);

	if (!buffer) {
		munmap(map, (size_t)size);
		close(fd);
		return -1;
	}

	cap.buffer = buffer;
	cap.map = map;
	cap.map_size = (size_t)size;
	cap.fd = fd;
	cap.stride = stride;

	return 0;
}

/*
 * Convert the source buffer (top-down, stride-padded) to tightly packed
 * bottom-up BGRA rows (as expected by the 32-bit BMP body).  `format` is the
 * wl_shm.format the compositor filled the buffer with.
 *
 *  - wl_shm ARGB8888 (0) / XRGB8888 (1): memory is B,G,R,A/x -> no swap.
 *  - DRM ARGB8888 / XRGB8888 fourcc:    memory is B,G,R,A/x -> no swap.
 *  - DRM XBGR8888 / ABGR8888 fourcc:    memory is R,G,B,A/x -> swap R and B.
 */
static void convert_to_bgra(const uint8_t *src, uint32_t format,
			    uint32_t width, uint32_t height,
			    int32_t stride, uint8_t *dst)
{
	int swap = (format == DRM_FORMAT_XBGR8888 || format == DRM_FORMAT_ABGR8888);

	for (uint32_t y = 0; y < height; y++) {
		const uint8_t *s = src + y * (size_t)stride;
		uint8_t *d = dst + (height - 1 - y) * width * 4;

		if (swap) {
			for (uint32_t x = 0; x < width; x++) {
				d[x * 4 + 0] = s[x * 4 + 2]; /* B */
				d[x * 4 + 1] = s[x * 4 + 1]; /* G */
				d[x * 4 + 2] = s[x * 4 + 0]; /* R */
				d[x * 4 + 3] = s[x * 4 + 3]; /* A */
			}
		} else {
			memcpy(d, s, width * 4);
		}
	}
}

/* Box-filter downscale of a BGRA image by an integer factor.
 * Returns a newly malloc'd buffer, or NULL on failure. */
static uint8_t *downscale_bgra(const uint8_t *src, uint32_t sw, uint32_t sh,
                                uint32_t factor,
                                uint32_t *out_w, uint32_t *out_h)
{
	if (factor <= 1)
		return NULL;
	uint32_t dw = sw / factor;
	uint32_t dh = sh / factor;
	if (dw == 0 || dh == 0)
		return NULL;

	uint8_t *dst = malloc((size_t)dw * dh * 4);
	if (!dst)
		return NULL;

	uint32_t count = factor * factor;
	for (uint32_t y = 0; y < dh; y++) {
		for (uint32_t x = 0; x < dw; x++) {
			uint32_t sr = 0, sg = 0, sb = 0, sa = 0;
			for (uint32_t dy = 0; dy < factor; dy++) {
				for (uint32_t dx = 0; dx < factor; dx++) {
					uint32_t sx = x * factor + dx;
					uint32_t sy = y * factor + dy;
					if (sx < sw && sy < sh) {
						const uint8_t *p = src + (size_t)(sy * sw + sx) * 4;
						sr += p[0];
						sg += p[1];
						sb += p[2];
						sa += p[3];
					}
				}
			}
			uint8_t *d = dst + (size_t)(y * dw + x) * 4;
			d[0] = (uint8_t)(sr / count);
			d[1] = (uint8_t)(sg / count);
			d[2] = (uint8_t)(sb / count);
			d[3] = (uint8_t)(sa / count);
		}
	}

	*out_w = dw;
	*out_h = dh;
	return dst;
}

static void emit_ok(uint32_t w, uint32_t h, const uint8_t *pixels, size_t len)
{
	printf("OK %u %u %zu\n", w, h, (size_t)w * 4);
	fwrite(pixels, 1, len, stdout);
	fflush(stdout);
}

static void emit_err(const char *reason)
{
	printf("ERR %s\n", reason);
	fflush(stdout);
}

/* ---------------------------------------------------------------------------
 * ext-image-copy-capture-v1 flow (full output)
 * ------------------------------------------------------------------------- */

static int run_capture_ext(const char *output_name, uint32_t downscale)
{
	struct output_info *oi = find_output(output_name);
	if (!oi) {
		char msg[256];
		snprintf(msg, sizeof(msg), "output not found: %s", output_name);
		emit_err(msg);
		return -1;
	}

	memset(&cap, 0, sizeof(cap));
	cap.fd = -1;

	/* 1. Create source and session. */
	struct ext_image_capture_source_v1 *source =
		ext_output_image_capture_source_manager_v1_create_source(
			source_manager, oi->output);

	struct ext_image_copy_capture_session_v1 *session =
		ext_image_copy_capture_manager_v1_create_session(
			capture_manager, source, 0);
	ext_image_copy_capture_session_v1_add_listener(session, &session_listener, NULL);

	/* 2. Dispatch until session constraints are received. */
	for (int i = 0; i < 50 && !cap.session_done && !cap.frame_failed; i++)
		if (dispatch_timeout(100) < 0)
			break;

	if (cap.frame_failed) {
		emit_err(cap.err);
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	if (cap.width == 0 || cap.height == 0) {
		emit_err("no buffer constraints received");
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	/* 3. Allocate SHM buffer (use the shm-format the compositor advertised). */
	uint32_t format = cap.shm_format_set ? cap.shm_format : cap.format;
	if (shm_alloc(format, cap.width, cap.height, 0) != 0) {
		emit_err("shm buffer allocation failed");
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	/* 4. Create frame, attach buffer, capture. */
	struct ext_image_copy_capture_frame_v1 *frame =
		ext_image_copy_capture_session_v1_create_frame(session);
	ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener, NULL);

	ext_image_copy_capture_frame_v1_attach_buffer(frame, cap.buffer);
	ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0,
		cap.width, cap.height);
	ext_image_copy_capture_frame_v1_capture(frame);

	for (int i = 0; i < 100 && !cap.frame_ready && !cap.frame_failed; i++)
		if (dispatch_timeout(100) < 0)
			break;

	if (cap.frame_failed) {
		emit_err(cap.err);
		shm_cleanup();
		ext_image_copy_capture_frame_v1_destroy(frame);
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	/* 5. Read pixels from the mmap'd SHM buffer. */
	size_t pixel_bytes = (size_t)cap.width * cap.height * 4;
	uint8_t *pixels = malloc(pixel_bytes);
	if (!pixels) {
		emit_err("malloc failed");
		shm_cleanup();
		ext_image_copy_capture_frame_v1_destroy(frame);
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	convert_to_bgra(cap.map, format, cap.width, cap.height,
			cap.stride, pixels);

	uint32_t out_w = cap.width, out_h = cap.height;
	uint8_t *out_pixels = pixels;
	size_t out_len = pixel_bytes;
	if (downscale > 1) {
		uint8_t *ds = downscale_bgra(pixels, cap.width, cap.height,
			downscale, &out_w, &out_h);
		if (ds) {
			free(pixels);
			out_pixels = ds;
			out_len = (size_t)out_w * out_h * 4;
		}
	}
	emit_ok(out_w, out_h, out_pixels, out_len);
	free(out_pixels);
	shm_cleanup();
	ext_image_copy_capture_frame_v1_destroy(frame);
	ext_image_copy_capture_session_v1_destroy(session);
	ext_image_capture_source_v1_destroy(source);

	return 0;
}

/* ---------------------------------------------------------------------------
 * wlr-screencopy flow (fallback, full output)
 * ------------------------------------------------------------------------- */

static int run_capture_wlr(const char *output_name, uint32_t downscale)
{
	struct output_info *oi = find_output(output_name);
	if (!oi) {
		char msg[256];
		snprintf(msg, sizeof(msg), "output not found: %s", output_name);
		emit_err(msg);
		return -1;
	}

	memset(&cap, 0, sizeof(cap));
	cap.fd = -1;

	/* 1. Create frame. */
	struct zwlr_screencopy_frame_v1 *frame =
		zwlr_screencopy_manager_v1_capture_output(
			wlr_manager, 1, oi->output);
	zwlr_screencopy_frame_v1_add_listener(frame, &wlr_frame_listener, NULL);

	/* 2. Dispatch until the buffer (shm) or linux_dmabuf event arrives. */
	for (int i = 0; i < 50 && !cap.session_done && !cap.frame_failed; i++)
		if (dispatch_timeout(100) < 0)
			break;

	if (cap.frame_failed) {
		emit_err(cap.err);
		zwlr_screencopy_frame_v1_destroy(frame);
		return -1;
	}

	if (cap.width == 0 || cap.height == 0) {
		emit_err("no buffer constraints received");
		zwlr_screencopy_frame_v1_destroy(frame);
		return -1;
	}

	/* 3. Allocate SHM buffer (the buffer event carries the wl_shm.format). */
	if (!cap.shm_format_set) {
		emit_err("wlr compositor did not offer an shm buffer");
		zwlr_screencopy_frame_v1_destroy(frame);
		return -1;
	}
	if (shm_alloc(cap.shm_format, cap.width, cap.height, cap.stride) != 0) {
		emit_err("shm buffer allocation failed");
		zwlr_screencopy_frame_v1_destroy(frame);
		return -1;
	}

	/* 4. Copy into the buffer. */
	zwlr_screencopy_frame_v1_copy(frame, cap.buffer);

	for (int i = 0; i < 100 && !cap.frame_ready && !cap.frame_failed; i++)
		if (dispatch_timeout(100) < 0)
			break;

	if (cap.frame_failed) {
		emit_err(cap.err);
		shm_cleanup();
		zwlr_screencopy_frame_v1_destroy(frame);
		return -1;
	}

	/* 5. Read pixels from the mmap'd SHM buffer. */
	size_t pixel_bytes = (size_t)cap.width * cap.height * 4;
	uint8_t *pixels = malloc(pixel_bytes);
	if (!pixels) {
		emit_err("malloc failed");
		shm_cleanup();
		zwlr_screencopy_frame_v1_destroy(frame);
		return -1;
	}

	convert_to_bgra(cap.map, cap.shm_format, cap.width, cap.height,
			cap.stride, pixels);

	uint32_t out_w = cap.width, out_h = cap.height;
	uint8_t *out_pixels = pixels;
	size_t out_len = pixel_bytes;
	if (downscale > 1) {
		uint8_t *ds = downscale_bgra(pixels, cap.width, cap.height,
			downscale, &out_w, &out_h);
		if (ds) {
			free(pixels);
			out_pixels = ds;
			out_len = (size_t)out_w * out_h * 4;
		}
	}
	emit_ok(out_w, out_h, out_pixels, out_len);
	free(out_pixels);
	shm_cleanup();
	zwlr_screencopy_frame_v1_destroy(frame);

	return 0;
}

/* ---------------------------------------------------------------------------
 * ext-foreign-toplevel capture flow (no wl_output required)
 * ------------------------------------------------------------------------- */

static int run_capture_toplevel(uint32_t downscale)
{
	if (toplevel_count == 0) {
		emit_err("no toplevels available");
		return -1;
	}

	struct ext_foreign_toplevel_handle_v1 *toplevel = toplevels[0];

	memset(&cap, 0, sizeof(cap));
	cap.fd = -1;

	/* 1. Create source from the toplevel handle. */
	struct ext_image_capture_source_v1 *source =
		ext_foreign_toplevel_image_capture_source_manager_v1_create_source(
			toplevel_source_manager, toplevel);

	struct ext_image_copy_capture_session_v1 *session =
		ext_image_copy_capture_manager_v1_create_session(
			capture_manager, source, 0);
	ext_image_copy_capture_session_v1_add_listener(session, &session_listener, NULL);

	/* 2. Dispatch until session constraints are received. */
	for (int i = 0; i < 50 && !cap.session_done && !cap.frame_failed; i++)
		if (dispatch_timeout(100) < 0)
			break;

	if (cap.frame_failed) {
		emit_err(cap.err);
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	if (cap.width == 0 || cap.height == 0) {
		emit_err("no buffer constraints received");
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	/* 3. Allocate SHM buffer (use the shm-format the compositor advertised). */
	uint32_t format = cap.shm_format_set ? cap.shm_format : cap.format;
	if (shm_alloc(format, cap.width, cap.height, 0) != 0) {
		emit_err("shm buffer allocation failed");
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	/* 4. Create frame, attach buffer, capture. */
	struct ext_image_copy_capture_frame_v1 *frame =
		ext_image_copy_capture_session_v1_create_frame(session);
	ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener, NULL);

	ext_image_copy_capture_frame_v1_attach_buffer(frame, cap.buffer);
	ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0,
		cap.width, cap.height);
	ext_image_copy_capture_frame_v1_capture(frame);

	for (int i = 0; i < 100 && !cap.frame_ready && !cap.frame_failed; i++)
		if (dispatch_timeout(100) < 0)
			break;

	if (cap.frame_failed) {
		emit_err(cap.err);
		shm_cleanup();
		ext_image_copy_capture_frame_v1_destroy(frame);
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	/* 5. Read pixels from the mmap'd SHM buffer. */
	size_t pixel_bytes = (size_t)cap.width * cap.height * 4;
	uint8_t *pixels = malloc(pixel_bytes);
	if (!pixels) {
		emit_err("malloc failed");
		shm_cleanup();
		ext_image_copy_capture_frame_v1_destroy(frame);
		ext_image_copy_capture_session_v1_destroy(session);
		ext_image_capture_source_v1_destroy(source);
		return -1;
	}

	convert_to_bgra(cap.map, format, cap.width, cap.height,
			cap.stride, pixels);

	uint32_t out_w = cap.width, out_h = cap.height;
	uint8_t *out_pixels = pixels;
	size_t out_len = pixel_bytes;
	if (downscale > 1) {
		uint8_t *ds = downscale_bgra(pixels, cap.width, cap.height,
			downscale, &out_w, &out_h);
		if (ds) {
			free(pixels);
			out_pixels = ds;
			out_len = (size_t)out_w * out_h * 4;
		}
	}
	emit_ok(out_w, out_h, out_pixels, out_len);
	free(out_pixels);
	shm_cleanup();

	return 0;
}

/* ---------------------------------------------------------------------------
 * Init and main
 * ------------------------------------------------------------------------- */

/* Dispatch with a timeout (ms). Returns 0 on success, -1 on timeout.
 *
 * Uses the built-in wl_display_dispatch_timeout, which correctly performs
 * the prepare-read / read-events / dispatch-pending dance internally and
 * waits up to the timeout without blocking forever. */
static int dispatch_timeout(int ms)
{
	struct timespec ts = {
		.tv_sec = ms / 1000,
		.tv_nsec = (long)(ms % 1000) * 1000000L,
	};
	return wl_display_dispatch_timeout(display, &ts);
}

static int init_display(void)
{
	display = wl_display_connect(NULL);
	if (!display)
		return -1;

	/* Non-blocking socket so wl_display_flush (write) can never block. */
	int fd = wl_display_get_fd(display);
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);

	/* Dispatch to receive globals and initial events. */
	wl_display_dispatch(display);

	/* Dispatch again to receive wl_output name / toplevel events (with timeout). */
	for (int i = 0; i < 10; i++) {
		dispatch_timeout(200);
	}

	if (!shm)
		return -1;
	if (!use_ext && !use_wlr && !use_toplevel)
		return -1;

	return 0;
}

int main(void)
{
	if (init_display() != 0) {
		printf("ERR no capture protocol available\n");
		fflush(stdout);
		return 1;
	}

	/*
	 * Choose the capture protocol.  Full-output protocols (ext-image-copy-
	 * capture and wlr-screencopy) require a wl_output global, which some
	 * compositors (e.g. Umbriel) do not advertise.  The foreign-toplevel
	 * protocol captures a toplevel window and needs no wl_output.
	 */
	int protocol = 0; /* 1=ext, 2=wlr, 3=toplevel */
	if (use_ext && output_count > 0)
		protocol = 1;
	else if (use_wlr && output_count > 0)
		protocol = 2;
	else if (use_toplevel && toplevel_list != NULL && capture_manager != NULL)
		protocol = 3;

	if (protocol == 0) {
		printf("ERR no usable capture protocol\n");
		fflush(stdout);
		return 1;
	}

	/* Print which protocol is active (visible without HYPRDEBUG). */
	if (protocol == 1)
		printf("PROTOCOL ext-image-copy-capture-v1\n");
	else if (protocol == 2)
		printf("PROTOCOL wlr-screencopy\n");
	else
		printf("PROTOCOL ext-foreign-toplevel\n");
	fflush(stdout);

	printf("READY\n");
	fflush(stdout);

	char line[1024];
	while (fgets(line, sizeof(line), stdin)) {
		/* Strip trailing newline. */
		size_t len = strlen(line);
		while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
			line[--len] = '\0';

		if (strncmp(line, "CAPTURE ", 8) == 0) {
			char output_name[256] = {0};
			double scale = 1.0;
			uint32_t downscale = 1;
			if (sscanf(line + 8, "%255s %lf %u", output_name, &scale, &downscale) >= 1) {
				if (protocol == 1)
					run_capture_ext(output_name, downscale);
				else if (protocol == 2)
					run_capture_wlr(output_name, downscale);
				else if (protocol == 3)
					run_capture_toplevel(downscale);
				else
					emit_err("no capture protocol available");
			}
		} else if (strncmp(line, "QUIT", 4) == 0) {
			break;
		}
	}

	wl_display_disconnect(display);
	return 0;
}
