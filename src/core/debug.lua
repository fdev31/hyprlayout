-- Diagnostic logging + SIGFPE backtrace handler, gated by the HYPRDEBUG env var.
-- All output goes to stderr so it stays separable from normal stdout and survives a crash.
local M = {}

local ffi = require("ffi")

local enabled = os.getenv("HYPRDEBUG") ~= nil and os.getenv("HYPRDEBUG") ~= "0"
local seq = 0

local function now()
	if love and love.timer and love.timer.getTime then
		return love.timer.getTime()
	end
	return os.clock()
end

function M.enabled()
	return enabled
end

function M.log(fmt, ...)
	if not enabled then
		return
	end
	seq = seq + 1
	local msg
	if fmt ~= nil then
		msg = string.format(fmt, ...)
	else
		msg = ""
	end
	io.stderr:write(string.format("[hyprlayout][t=%.3f][%d] %s\n", now(), seq, msg))
end

local function monitor_desc(i)
	local ok, mon = pcall(function()
		return love.window.getMonitor(i)
	end)
	if not ok or not mon then
		return string.format("  monitor[%d] = <unavailable>", i)
	end
	local name, pos_x, pos_y, w, h, refresh = "?", 0, 0, 0, 0, 0
	pcall(function()
		name = mon:getName()
	end)
	pcall(function()
		pos_x, pos_y = mon:getPosition()
	end)
	pcall(function()
		w, h = mon:getSize()
	end)
	pcall(function()
		refresh = mon:getRefreshRate()
	end)
	return string.format("  monitor[%d] = %s @ (%d,%d) %dx%d @%.1fHz", i, tostring(name), pos_x, pos_y, w, h, refresh)
end

function M.dump_window_state(label)
	if not enabled then
		return
	end
	local parts = {}
	if label then
		parts[#parts + 1] = "window state (" .. label .. "):"
	end

	local ok, cw, ch = pcall(function()
		return love.graphics.getWidth(), love.graphics.getHeight()
	end)
	if ok then
		parts[#parts + 1] = string.format("  canvas = %dx%d", cw, ch)
	end

	local wok = pcall(function()
		local w, h = love.window.getSize()
		local x, y = love.window.getPosition()
		local m = love.window.getMonitor()
		parts[#parts + 1] = string.format("  window = %dx%d at (%d,%d) on monitor %s", w, h, x, y, tostring(m))
	end)
	if not wok then
		parts[#parts + 1] = "  window = <unavailable>"
	end

	local cok, count = pcall(function()
		return love.window.getMonitorCount()
	end)
	if cok and count then
		for i = 0, count - 1 do
			parts[#parts + 1] = monitor_desc(i)
		end
	end

	io.stderr:write(table.concat(parts, "\n") .. "\n")
end

local C_SOURCE = [[
#include <signal.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>

static void handler(int sig) {
    void *frames[128];
    int n = backtrace(frames, 128);
    fprintf(stderr, "[hyprlayout][sig] caught signal %d - native backtrace (%d frames):\n", sig, n);
    backtrace_symbols_fd(frames, n, 2);
    signal(sig, SIG_DFL);
    raise(sig);
}

int install_fatal_handlers(void) {
    struct sigaction sa;
    sa.sa_handler = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    int r = 0;
    r |= sigaction(SIGSEGV, &sa, NULL);
    r |= sigaction(SIGFPE, &sa, NULL);
    r |= sigaction(SIGBUS, &sa, NULL);
    r |= sigaction(SIGABRT, &sa, NULL);
    r |= sigaction(SIGTRAP, &sa, NULL);
    r |= sigaction(SIGILL, &sa, NULL);
    return r;
}
]]

local handler_installed = false

function M.install_sigfpe_handler()
	if not enabled or handler_installed then
		return
	end
	handler_installed = true

	local cache_base = os.getenv("XDG_CACHE_HOME")
	if not cache_base or cache_base == "" then
		cache_base = (os.getenv("HOME") or "/tmp") .. "/.cache"
	end
	local cache_dir = cache_base .. "/hyprlayout"
	local so_path = cache_dir .. "/sigfpe_handler.so"

	local function file_exists(p)
		local f = io.open(p, "rb")
		if f then
			f:close()
			return true
		end
		return false
	end

	if not file_exists(so_path) then
		os.execute(string.format("mkdir -p %q", cache_dir))
		local tmp_c = cache_dir .. "/sigfpe_handler.c"
		local f = io.open(tmp_c, "wb")
		if f then
			f:write(C_SOURCE)
			f:close()
			local cc = "cc"
			if os.execute("command -v gcc > /dev/null 2>&1") == 0 then
				cc = "gcc"
			end
			local rc = os.execute(string.format('%s -shared -fPIC -O0 -o %q %q 2>/dev/null', cc, so_path, tmp_c))
			if rc ~= 0 or not file_exists(so_path) then
				M.log("failed to compile SIGFPE handler (rc=%d); continuing without it", rc)
				return
			end
		else
			M.log("could not write SIGFPE handler source; continuing without it")
			return
		end
	end

	ffi.cdef[[int install_fatal_handlers(void);]]
	local ok, lib = pcall(ffi.load, so_path)
	if not ok or not lib then
		M.log("failed to load fatal-signal handler lib: %s", tostring(lib))
		return
	end
	local cok, rc = pcall(function()
		return lib.install_fatal_handlers()
	end)
	if not cok then
		M.log("failed to install fatal-signal handlers: %s", tostring(rc))
		return
	end
	M.log("fatal-signal handlers installed (rc=%d)", rc)
end

return M
