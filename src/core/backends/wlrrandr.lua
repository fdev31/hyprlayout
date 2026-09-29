-- wlr-randr backend: drives a Wayland (wlroots) display through `wlr-randr`.
-- Supports the core operations only (position, mode, on/off) — no scale,
-- transform, or HDR.
local M = {}

M.name = "wlr-randr"
M.capabilities = { scale = false, transform = false, hdr = false }

local timeout = 5

-- Run a shell command and return its trimmed stdout.
local function run(cmd)
	local f = io.popen(string.format("timeout %s %s 2>&1", timeout, cmd))
	local out = f:read("*a") or ""
	f:close()
	return out:match("^%s*(.-)%s*$")
end

-- Build a default Monitor value; the parser fills in the fields it can.
local function new_monitor(name)
	return {
		name = name,
		description = name,
		x = 0,
		y = 0,
		width = 0,
		height = 0,
		scale = 1.0,
		transform = 0,
		refreshRate = 0,
		focused = false,
		disabled = true,
		availableModes = {},
		currentFormat = "",
		colorManagementPreset = "",
		sdrBrightness = 1.0,
		sdrSaturation = 1.0,
		sdrMaxLuminance = 0,
		sdrMinLuminance = 0,
	}
end

-- Parse `wlr-randr` output into a list of Monitor values.
local function parse(out)
	local mons = {}
	local cur = nil
	local mode_mode = false
	for line in out:gmatch(".*") do
		if line:sub(1, 1) ~= " " then
			-- Monitor header: just the output name.
			local name = line:match("^%s*(%S+)")
			if name then
				cur = new_monitor(name)
				mode_mode = false
				table.insert(mons, cur)
			end
		elseif cur then
			local sline = line:match("^%s+(.*)$")
			if sline then
				if mode_mode then
					-- Mode line, e.g. "1920x1080, 60.00 Hz [current]".
					local w, h = sline:match("^(%d+)x(%d+)")
					local freq = sline:match("%d+%.?%d*%s*Hz")
					freq = freq and freq:match("(%d+%.?%d*)")
					if w and h and freq then
						local is_current = sline:find("current") ~= nil
						table.insert(cur.availableModes, {
							width = tonumber(w),
							height = tonumber(h),
							freq = tonumber(freq),
						})
						if is_current then
							cur.refreshRate = tonumber(freq)
							cur.width, cur.height = tonumber(w), tonumber(h)
						end
					end
				elseif sline:sub(1, 6) == "Modes:" then
					mode_mode = true
				elseif sline:sub(1, 7) == "Enabled" then
					cur.disabled = sline:find("yes") == nil
					if sline:find("yes") ~= nil then
						cur.focused = true
					end
				elseif sline:sub(1, 8) == "Position" then
					local px, py = sline:match("Position:%s*(-?%d+),%s*(-?%d+)")
					if px then
						cur.x, cur.y = tonumber(px), tonumber(py)
					end
				elseif sline:sub(1, 5) == "Scale" then
					local s = sline:match("Scale:%s*(%d+%.?%d*)")
					if s then
						cur.scale = tonumber(s)
					end
				end
			end
		end
	end
	return mons
end

-- Serialize one MonitorConfig into wlr-randr --output arguments.
local function config_to_args(cfg)
	if not cfg.enabled then
		return string.format("--output %s --off", cfg.name)
	end
	local mode = string.format("%dx%d", math.floor(cfg.width), math.floor(cfg.height))
	local pos = string.format("%d,%d", math.floor(cfg.x), math.floor(cfg.y))
	return string.format("--output %s --on --pos %s --mode %s", cfg.name, pos, mode)
end

-- --- backend contract ---

-- True when wlr-randr is present and reports at least one output.
function M.probe()
	local out = run("wlr-randr")
	local mons = parse(out)
	return #mons > 0
end

-- Set the per-call timeout (seconds) for all wlr-randr invocations.
function M.set_timeout(n)
	if type(n) == "number" and n > 0 then
		timeout = n
	end
end

-- List all monitors as opaque Monitor values. Returns (list, raw).
function M.list_monitors()
	local out = run("wlr-randr")
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
	local out = run("wlr-randr " .. table.concat(args, " "))
	return true, out
end

return M
