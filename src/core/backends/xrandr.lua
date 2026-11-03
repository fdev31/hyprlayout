-- xrandr backend: drives an X11 / legacy display through `xrandr`. Supports the
-- core operations only (position, mode, on/off) — no scale, transform, or HDR.
local util = require("core.backends.util")

local M = {}

M.name = "xrandr"
M.capabilities = { scale = false, transform = false, hdr = false }

local timeout = 5

local function run(cmd)
	return util.run(cmd, timeout)
end

-- Parse `xrandr` output into a list of Monitor values. Each output is an
-- unindented header `NAME connected|disconnected ...` followed by indented
-- mode lines like `1920x1080     60.00*+  50.00   59.94`, where `*` marks the
-- active rate and `+` the preferred one. The `Screen 0: ...` summary line and
-- error text such as "Can't open display" carry no connected/disconnected
-- token, so they are rejected by the header pattern.
local function parse(out)
	local monitors = {}
	local monitor
	for line in util.lines(out) do
		local name, state = line:match("^(%S+)%s+(%a*connected)")
		if name then
			monitor = util.new_monitor(name)
			-- Usable only when connected and currently driving a geometry.
			local w, h, px, py = line:match("(%d+)x(%d+)%+(-?%d+)%+(-?%d+)")
			if w and state == "connected" then
				monitor.width, monitor.height = tonumber(w), tonumber(h)
				monitor.x, monitor.y = tonumber(px), tonumber(py)
				monitor.disabled = false
			end
			monitor.focused = line:find(" primary ", 1, true) ~= nil
			table.insert(monitors, monitor)
		elseif monitor and line:match("^%s") then
			-- Mode line.
			local field = line:match("^%s+(.-)%s*$") or ""
			local w, h, rates = field:match("^(%d+)x(%d+)%s+(.*)$")
			if w and h then
				for rate, flags in rates:gmatch("(%d+%.?%d*)([%*%+]*)") do
					table.insert(monitor.availableModes, util.mode_string(tonumber(w), tonumber(h), tonumber(rate)))
					if flags:find("*", 1, true) then
						monitor.refreshRate = tonumber(rate)
					end
				end
			end
		end
	end
	return monitors
end

-- Serialize one MonitorConfig into xrandr --output arguments.
local function config_to_args(cfg)
	if not cfg.enabled then
		return string.format("--output %s --off", cfg.name)
	end
	local mode = string.format("%dx%d", math.floor(cfg.width), math.floor(cfg.height))
	-- xrandr's --pos takes a comma-separated pair, unlike its WxH mode syntax.
	local pos = string.format("%d,%d", math.floor(cfg.x), math.floor(cfg.y))
	local args = string.format("--output %s --on --pos %s --mode %s", cfg.name, pos, mode)
	if cfg.refresh and cfg.refresh > 0 then
		args = args .. string.format(" --rate %.2f", cfg.refresh)
	end
	return args
end

-- --- backend contract ---

-- True when xrandr is present and reports at least one output.
function M.probe()
	local monitors = parse(run("xrandr"))
	return #monitors > 0
end

-- Set the per-call timeout (seconds) for all xrandr invocations.
function M.set_timeout(n)
	if type(n) == "number" and n > 0 then
		timeout = n
	end
end

-- List all monitors as opaque Monitor values. Returns (list, raw).
function M.list_monitors()
	local out = run("xrandr")
	return parse(out), out
end

-- Apply a list of MonitorConfig values. Returns (ok, output).
function M.configure_monitors(configs)
	if #configs == 0 then
		return true, ""
	end
	local args = {}
	for _, cfg in ipairs(configs) do
		table.insert(args, config_to_args(cfg))
	end
	local out = run("xrandr " .. table.concat(args, " "))
	-- xrandr is silent on success; any output is a diagnostic.
	return out == "", out
end

return M
