-- Wayland native screen capture via a long-lived child process.
--
-- Compiles core/wayland_capture.c at runtime into a standalone executable,
-- then fork/exec's it as a child process that maintains a single Wayland
-- connection.  Capture requests are sent over a stdin pipe; frame data is
-- read back from a stdout pipe.
--
-- If the child segfaults (compositor bug, buffer corruption, etc.) the
-- parent detects the broken pipe, cleans up, and returns nil.  The caller
-- (grim.lua) then falls back to the grim PPM subprocess.  The next capture
-- respawns a fresh child.
--
-- Protocol (stdin/stdout):
--   child → parent:  READY\n
--   parent → child:  CAPTURE <output_name> [scale]\n
--   child → parent:  OK <w> <h> <stride>\n<raw BGRA bytes>
--   child → parent:  ERR <reason>\n
--   parent → child:  QUIT\n

local M = {}

local ffi = require("ffi")
local debug = require("core.debug")

--[[ ------------------------------------------------------------------
 FFI declarations for POSIX process / pipe management
 ------------------------------------------------------------------ ]]

ffi.cdef([[
typedef int pid_t;
int    pipe(int fds[2]);
pid_t  fork(void);
int    dup2(int oldfd, int newfd);
int    execvp(const char *file, char *const argv[]);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int    close(int fd);
int    waitpid(pid_t pid, int *status);
int    poll(struct pollfd *fds, unsigned int nfds, int timeout);
void   _exit(int status);
void   pthread_mutex_lock(pthread_mutex_t *mutex);
void   pthread_mutex_unlock(pthread_mutex_t *mutex);
int    pthread_mutex_init(pthread_mutex_t *mutex, const void *attr);
struct pollfd { int fd; short events; short revents; };
]])

local C_SOURCE_PATH
do
	local src_dir = love.filesystem.getSourceDirectory()
	C_SOURCE_PATH = src_dir .. "/core/wayland_capture.c"
end

--[[ ------------------------------------------------------------------
 State
 ------------------------------------------------------------------ ]]

local child_pid = nil
local write_fd = nil -- parent writes to child stdin
local read_fd = nil -- parent reads from child stdout
local exe_path = nil
local running = false

-- Serialises pipe access across LÖVE threads (one per monitor).
local capture_mutex = ffi.new("pthread_mutex_t[1]")
ffi.C.pthread_mutex_init(capture_mutex, nil)

-- Reusable 1-byte read buffer (avoids per-byte allocation).
local read_byte_buf = ffi.new("char[1]")

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

	if not file_exists(exe) then
		os.execute(string.format("mkdir -p %q", cache_dir))

		local cc = "cc"
		if os.execute("command -v gcc > /dev/null 2>&1") == 0 then
			cc = "gcc"
		end
		local rc = os.execute(string.format("%s -O2 -o %q %q -lwayland-client -lpthread 2>&1", cc, exe, C_SOURCE_PATH))
		if rc ~= 0 or not file_exists(exe) then
			debug.log("wayland_capture: compile failed (rc=%d)", rc)
			return nil
		end
	end

	return exe
end

-- Read one line (up to and including \n) from a raw fd.
-- Returns the line without the trailing newline, or nil on EOF/error.
local function read_line(fd)
	local buf = {}
	while true do
		local n = ffi.C.read(fd, read_byte_buf, 1)
		if n <= 0 then
			return nil
		end
		if read_byte_buf[0] == "\n" then
			return table.concat(buf)
		end
		buf[#buf + 1] = read_byte_buf[0]
	end
end

-- Read exactly `count` bytes from a raw fd.
-- Returns a Lua string, or nil on EOF/error.
local function read_exact(fd, count)
	local buf = ffi.new("char[?]", count)
	local total = 0
	while total < count do
		local n = ffi.C.read(fd, buf + total, count - total)
		if n <= 0 then
			ffi.C.free(buf)
			return nil
		end
		total = total + n
	end
	local result = ffi.string(buf, count)
	ffi.C.free(buf)
	return result
end

-- Close pipes and reap the child process.
local function cleanup_child()
	if write_fd then
		ffi.C.close(write_fd)
		write_fd = nil
	end
	if read_fd then
		ffi.C.close(read_fd)
		read_fd = nil
	end
	if child_pid then
		local status = ffi.new("int[1]")
		ffi.C.waitpid(child_pid, status)
		child_pid = nil
	end
	running = false
end

-- Spawn the child process.  Returns true on success.
local function spawn_child()
	if running then
		return true
	end

	exe_path = compile_exe()
	if not exe_path then
		return false
	end

	-- Create two pipes: stdin_pipe (parent→child) and stdout_pipe (child→parent)
	local stdin_pipe = ffi.new("int[2]")
	local stdout_pipe = ffi.new("int[2]")

	if ffi.C.pipe(stdin_pipe) ~= 0 then
		debug.log("wayland_capture: pipe() failed (stdin)")
		return false
	end
	if ffi.C.pipe(stdout_pipe) ~= 0 then
		ffi.C.close(stdin_pipe[0])
		ffi.C.close(stdin_pipe[1])
		debug.log("wayland_capture: pipe() failed (stdout)")
		return false
	end

	-- Build argv BEFORE fork (allocation is not async-signal-safe).
	local argv = ffi.new("char*[2]")
	argv[0] = exe_path
	argv[1] = nil

	local pid = ffi.C.fork()
	if pid < 0 then
		ffi.C.close(stdin_pipe[0])
		ffi.C.close(stdin_pipe[1])
		ffi.C.close(stdout_pipe[0])
		ffi.C.close(stdout_pipe[1])
		ffi.C.free(argv)
		debug.log("wayland_capture: fork() failed")
		return false
	end

	if pid == 0 then
		-- ---- child process: only async-signal-safe calls ----
		ffi.C.close(stdin_pipe[1])
		ffi.C.close(stdout_pipe[0])
		ffi.C.dup2(stdin_pipe[0], 0)
		ffi.C.dup2(stdout_pipe[1], 1)
		ffi.C.close(stdin_pipe[0])
		ffi.C.close(stdout_pipe[1])
		ffi.C.execvp(exe_path, argv)
		-- execvp failed; terminate without cleanup
		ffi.C._exit(1)
	end

	-- ---- parent process ----
	ffi.C.close(stdin_pipe[0])
	ffi.C.close(stdout_pipe[1])
	ffi.C.free(argv)

	child_pid = pid
	write_fd = stdin_pipe[1]
	read_fd = stdout_pipe[0]

	-- Wait for the child to become ready (5 s timeout).
	local pfd = ffi.new("struct pollfd")
	pfd.fd = read_fd
	pfd.events = 1 -- POLLIN
	local poll_ret = ffi.C.poll(pfd, 1, 5000)
	if poll_ret <= 0 then
		debug.log("wayland_capture: child not ready (poll ret=%d)", poll_ret)
		cleanup_child()
		return false
	end

	local ready = read_line(read_fd)
	if ready ~= "READY" then
		debug.log("wayland_capture: child did not send READY (got: %s)", tostring(ready))
		cleanup_child()
		return false
	end

	running = true
	debug.log("wayland_capture: child spawned (pid=%d)", pid)
	return true
end

--[[ ------------------------------------------------------------------
 Public API (matches the interface expected by grim.lua)
 ------------------------------------------------------------------ ]]

-- Check whether the native backend can be compiled and run.
-- Does NOT spawn the child; that happens in init().
function M.detect()
	local exe = compile_exe()
	if not exe then
		debug.log("wayland_capture: NOT available (compile failed)")
		return false
	end
	debug.log("wayland_capture: available (%s)", exe)
	return true
end

-- Spawn the child process (idempotent – safe to call repeatedly).
function M.init()
	return spawn_child()
end

-- Capture a frame.  Returns:
--   { width=..., height=..., stride=..., size=..., data=<lua string>, format="bgra" }
--   nil  on any failure (child crashed, timeout, protocol error).
function M.capture(output_name, scale)
	ffi.C.pthread_mutex_lock(capture_mutex)

	if not running then
		if not spawn_child() then
			ffi.C.pthread_mutex_unlock(capture_mutex)
			return nil
		end
	end

	-- Build the command: "CAPTURE <output_name> [scale]\n"
	local cmd
	if scale and scale > 1 then
		cmd = "CAPTURE " .. (output_name or "") .. " " .. scale .. "\n"
	else
		cmd = "CAPTURE " .. (output_name or "") .. "\n"
	end

	local n = ffi.C.write(write_fd, cmd, #cmd)
	if n ~= #cmd then
		debug.log("wayland_capture: write failed (child crashed?)")
		cleanup_child()
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end

	-- Wait for a response (15 s timeout: 5 s internal C timeout + margin).
	local pfd = ffi.new("struct pollfd")
	pfd.fd = read_fd
	pfd.events = 1 -- POLLIN
	local poll_ret = ffi.C.poll(pfd, 1, 15000)
	if poll_ret <= 0 then
		debug.log("wayland_capture: poll failed (ret=%d, child crashed?)", poll_ret)
		cleanup_child()
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end

	-- Read the header line.
	local header = read_line(read_fd)
	if not header then
		debug.log("wayland_capture: read failed (child crashed?)")
		cleanup_child()
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end

	if header:sub(1, 3) == "ERR" then
		debug.log("wayland_capture: capture failed: %s", header:sub(5))
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end

	if header:sub(1, 2) ~= "OK" then
		debug.log("wayland_capture: unexpected response: %s", header)
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end

	-- Parse: "OK <w> <h> <stride>"
	local w_s, h_s, stride_s = header:match("^OK (%d+) (%d+) (%d+)$")
	if not w_s then
		debug.log("wayland_capture: bad header: %s", header)
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end
	local w, h, stride = tonumber(w_s), tonumber(h_s), tonumber(stride_s)

	-- Read the raw BGRA payload.
	local size = stride * h
	local data = read_exact(read_fd, size)
	if not data then
		debug.log("wayland_capture: data read failed (child crashed?)")
		cleanup_child()
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return nil
	end

	debug.log("wayland_capture: ok %s %dx%d stride=%d (%d bytes)", output_name, w, h, stride, size)

	ffi.C.pthread_mutex_unlock(capture_mutex)

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
	ffi.C.pthread_mutex_lock(capture_mutex)
	if not running then
		ffi.C.pthread_mutex_unlock(capture_mutex)
		return
	end
	local cmd = "QUIT\n"
	ffi.C.write(write_fd, cmd, #cmd)
	cleanup_child()
	debug.log("wayland_capture: shutdown")
	ffi.C.pthread_mutex_unlock(capture_mutex)
end

return M
