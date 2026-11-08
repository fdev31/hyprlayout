-- Wayland native in-process screen capture via FFI.
-- Compiles core/wayland_capture.c at runtime (single source of truth).
-- Eliminates the grim subprocess by speaking ext-image-copy-capture-v1 directly.
local M = {}

local ffi = require("ffi")
local debug = require("core.debug")

local lib = nil
local initialized = false

local C_SOURCE_PATH
do
	local src_dir = love.filesystem.getSourceDirectory()
	C_SOURCE_PATH = src_dir .. "/core/wayland_capture.c"
end

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

		local cc = "cc"
		if os.execute("command -v gcc > /dev/null 2>&1") == 0 then
			cc = "gcc"
		end
		local rc = os.execute(
			string.format("%s -shared -fPIC -O2 -o %q %q -lwayland-client -lpthread 2>&1", cc, so_path, C_SOURCE_PATH)
		)
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
