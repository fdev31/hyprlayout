-- Wayland native screen capture via a long-lived child process.
--
-- Compiles core/wayland_capture.c at runtime into a standalone executable,
-- then spawns it as a child process (via shell) that maintains a single
-- Wayland connection.  Capture requests are sent over a stdin FIFO; frame
-- data is read back from a stdout FIFO.
--
-- If the child segfaults (compositor bug, buffer corruption, etc.) the
-- parent detects the closed FIFO, cleans up, and returns nil.  The caller
-- (grim.lua) then falls back to the grim PNG subprocess.  The next capture
-- respawns a fresh child.
--
-- Protocol (stdin/stdout):
--   child → parent:  PROTOCOL <name>\n
--   child → parent:  READY\n
--   parent → child:  CAPTURE <output_name> [scale]\n
--   child → parent:  OK <w> <h> <stride>\n<raw BGRA bytes>
--   child → parent:  ERR <reason>\n
--   parent → child:  QUIT\n

local M = {}

local debug = require("core.debug")

local C_SOURCE_PATH
do
	-- Prefer the path passed from the main thread (works in worker threads
	-- where love.filesystem and debug are nil).
	C_SOURCE_PATH = _G.HYPR_C_SOURCE_PATH
	if not C_SOURCE_PATH then
		-- Fallback: derive from this file's own location (main thread only).
		-- Use _G.debug because the local 'debug' variable below shadows
		-- the global debug library.
		local dbg = _G.debug
		if dbg and dbg.getinfo then
			local src_file = dbg.getinfo(1, "S").source
			src_file = src_file:sub(2)
			if src_file:sub(1, 1) == "/" and src_file:match("%.lua$") then
				local src_dir = src_file:match("^(.*)/core/wayland_capture%.lua$")
				if src_dir then
					C_SOURCE_PATH = src_dir .. "/core/wayland_capture.c"
				end
			end
		end
	end
end

--[[ ------------------------------------------------------------------
 State
 ------------------------------------------------------------------ ]]

local child_pid = nil
local write_file = nil -- io.open handle for writing to child stdin
local read_file = nil -- io.open handle for reading from child stdout
local exe_path = nil
local running = false
local fifo_in = nil
local fifo_out = nil
local spawn_id = 0
local native_available = nil -- cached detect() result
local native_protocol = nil -- protocol name from the child's PROTOCOL line

--[[ ------------------------------------------------------------------
 Helpers
 ------------------------------------------------------------------ ]]

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

local function compile_exe()
	local cache_dir = get_cache_dir()
	local exe = cache_dir .. "/wayland_capture_bin"

	-- Rebuild if the source is newer than the cached binary.
	local need_build = not file_exists(exe)
	if not need_build then
		need_build = os.execute(string.format("test %q -nt %q", C_SOURCE_PATH, exe)) == 0
	end

	if need_build then
		os.execute(string.format("mkdir -p %q", cache_dir))

		local cc = "cc"
		if os.execute("command -v gcc > /dev/null 2>&1") == 0 then
			cc = "gcc"
		end
		local src_dir = C_SOURCE_PATH:match("^(.*)/[^/]*$")
		local protocol_dir = src_dir .. "/protocol"
		local rc = os.execute(
			string.format(
				"%s -O2 -o %q %q %q/ext-image-copy-capture.c %q/ext-image-capture-source.c %q/ext-foreign-toplevel-list.c %q/wlr-screencopy.c -lwayland-client -lpthread 2>&1",
				cc,
				exe,
				C_SOURCE_PATH,
				protocol_dir,
				protocol_dir,
				protocol_dir,
				protocol_dir
			)
		)
		if rc ~= 0 or not file_exists(exe) then
			debug.log("wayland_capture: compile failed (rc=%d)", rc)
			return nil
		end
	end

	return exe
end

-- Close file handles, kill the child, and remove the FIFOs.
local function cleanup_child()
	if write_file then
		write_file:close()
		write_file = nil
	end
	if read_file then
		read_file:close()
		read_file = nil
	end
	if child_pid then
		os.execute("kill " .. child_pid .. " 2>/dev/null")
		child_pid = nil
	end
	if fifo_in then
		os.execute("rm -f " .. fifo_in .. " " .. fifo_out)
		fifo_in = nil
		fifo_out = nil
	end
	running = false
end

-- Spawn the child process.  Returns true on success.
-- Uses a shell-spawned child with named pipes (FIFOs) for communication.
-- This avoids FFI process management (posix_spawn/fork) which can crash
-- the LÖVE process when called from worker threads.
local function spawn_child()
	if running then
		return true
	end

	exe_path = compile_exe()
	if not exe_path then
		return false
	end

	-- Create unique FIFO names (per-thread module instance).
	-- Use a random component to avoid collisions between threads.
	spawn_id = spawn_id + 1
	local tag = string.format("%d_%d", spawn_id, math.random(100000, 999999))
	fifo_in = "/tmp/wlcap_in_" .. tag
	fifo_out = "/tmp/wlcap_out_" .. tag

	-- Clean up any stale FIFOs from a previous crashed instance.
	os.execute("rm -f " .. fifo_in .. " " .. fifo_out)
	os.execute("mkfifo " .. fifo_in .. " " .. fifo_out)

	-- Spawn the child in the background via the shell.
	-- The shell opens the FIFOs (stdin=read, stdout=write) before exec,
	-- so our subsequent io.open calls won't block.
	-- We write the PID to a file because io.popen with & blocks
	-- (the pipe stays open until the backgrounded child exits).
	local pidfile = "/tmp/wlcap_pid_" .. tag
	os.execute(string.format("%s < %s > %s 2>/dev/null & echo $! > %s", exe_path, fifo_in, fifo_out, pidfile))

	local pf = io.open(pidfile, "r")
	local pid_str = pf and pf:read("*l") or nil
	if pf then
		pf:close()
	end
	os.execute("rm -f " .. pidfile)

	if not pid_str or not pid_str:match("^%d+$") then
		debug.log("wayland_capture: failed to spawn child")
		os.execute("rm -f " .. fifo_in .. " " .. fifo_out)
		fifo_in = nil
		fifo_out = nil
		return false
	end

	child_pid = tonumber(pid_str)

	-- The child prints "PROTOCOL <name>" then "READY" once it has
	-- connected to Wayland and selected a usable capture protocol.
	-- Read both lines with a timeout so we never block forever if the
	-- child is stuck.
	local h = io.popen("timeout 6 head -2 " .. fifo_out .. " 2>/dev/null")
	local protocol = h:read("*l")
	local ready = h:read("*l")
	h:close()
	if ready ~= "READY" then
		debug.log(
			"wayland_capture: child did not send READY (protocol=%s ready=%s)",
			tostring(protocol),
			tostring(ready)
		)
		cleanup_child()
		return false
	end
	native_protocol = protocol
	print("wayland_capture: backend=" .. tostring(protocol))

	-- Open the FIFOs for subsequent reads/writes.  The child is alive
	-- and has the FIFOs open, so these should not block.
	read_file = io.open(fifo_out, "r")
	if not read_file then
		debug.log("wayland_capture: failed to open stdout FIFO")
		cleanup_child()
		return false
	end
	write_file = io.open(fifo_in, "w")
	if not write_file then
		debug.log("wayland_capture: failed to open stdin FIFO")
		cleanup_child()
		return false
	end

	running = true
	debug.log("wayland_capture: child spawned (pid=%d)", child_pid)
	return true
end

--[[ ------------------------------------------------------------------
 Public API (matches the interface expected by grim.lua)
 ------------------------------------------------------------------ ]]

-- Check whether the native backend can be compiled AND the compositor
-- supports the ext_image_copy_capture_v1 protocol.
-- Does NOT spawn the child; that happens in init().
function M.detect()
	if native_available ~= nil then
		return native_available
	end

	local exe = compile_exe()
	if not exe then
		debug.log("wayland_capture: NOT available (compile failed)")
		native_available = false
		return false
	end

	-- Probe the compositor by running the binary with stdin closed
	-- (immediate EOF).  It connects to Wayland, prints "PROTOCOL <name>"
	-- then "READY" when a usable capture protocol is available, and
	-- exits 0; it exits 1 when no protocol is usable.
	local h = io.popen(string.format("timeout 5 %s < /dev/null 2>/dev/null; echo $?", exe))
	local out = h:read("*a")
	h:close()

	local lines = {}
	for line in out:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	local rc = lines[#lines]
	local protocol = nil
	local ready = false
	for _, line in ipairs(lines) do
		local name = line:match("^PROTOCOL (.+)$")
		if name then
			protocol = name
		elseif line == "READY" then
			ready = true
		end
	end

	if rc ~= "0" or not protocol or not ready then
		debug.log(
			"wayland_capture: NOT available (rc=%s protocol=%s ready=%s)",
			tostring(rc),
			tostring(protocol),
			tostring(ready)
		)
		native_available = false
		return false
	end

	native_protocol = protocol
	native_available = true
	debug.log("wayland_capture: available (%s)", protocol)
	return true
end

-- Return the name of the capture protocol the compositor selected
-- (set by detect() or spawn_child()).  nil if unknown.
function M.protocol()
	return native_protocol
end

-- Spawn the child process (idempotent – safe to call repeatedly).
function M.init()
	return spawn_child()
end

-- Capture a frame.  Returns:
--   { width=..., height=..., stride=..., size=..., data=<lua string>, format="bgra" }
--   nil  on any failure (child crashed, timeout, protocol error).
function M.capture(output_name, scale)
	if not running then
		if not spawn_child() then
			return nil
		end
	end

	-- Build the command: "CAPTURE <output_name> [scale]\n"
	-- Scale is always passed when available (the C child treats it as an
	-- integer factor; software downsample is a TODO, so it is ignored for now).
	local cmd
	if scale then
		cmd = "CAPTURE " .. (output_name or "") .. " " .. scale .. "\n"
	else
		cmd = "CAPTURE " .. (output_name or "") .. "\n"
	end

	local ok = write_file:write(cmd)
	if not ok then
		debug.log("wayland_capture: write failed (child crashed?)")
		cleanup_child()
		return nil
	end
	write_file:flush()

	-- Read the header line.  Returns nil if the child died.
	local header = read_file:read("*l")
	if not header then
		debug.log("wayland_capture: read failed (child crashed?)")
		cleanup_child()
		return nil
	end

	if header:sub(1, 3) == "ERR" then
		debug.log("wayland_capture: capture failed: %s", header:sub(5))
		return nil
	end

	if header:sub(1, 2) ~= "OK" then
		debug.log("wayland_capture: unexpected response: %s", header)
		return nil
	end

	-- Parse: "OK <w> <h> <stride>"
	local w_s, h_s, stride_s = header:match("^OK (%d+) (%d+) (%d+)$")
	if not w_s then
		debug.log("wayland_capture: bad header: %s", header)
		return nil
	end
	local w, h, stride = tonumber(w_s), tonumber(h_s), tonumber(stride_s)

	-- Read the raw BGRA payload.
	local size = stride * h
	local data = read_file:read(size)
	if not data or #data ~= size then
		debug.log("wayland_capture: data read failed (child crashed?)")
		cleanup_child()
		return nil
	end

	debug.log("wayland_capture: ok %s %dx%d stride=%d (%d bytes)", output_name, w, h, stride, size)

	return {
		width = w,
		height = h,
		stride = stride,
		size = size,
		data = data,
		format = "bgra",
	}
end

-- Shut down the child process.
function M.shutdown()
	if not running then
		return
	end
	write_file:write("QUIT\n")
	write_file:flush()
	-- Give the child a moment to exit cleanly before we kill it.
	cleanup_child()
	debug.log("wayland_capture: shutdown")
end

return M
