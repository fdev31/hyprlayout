-- wlr-randr backend: drives a Wayland (wlroots) display through `wlr-randr`.
-- Supports position, mode, on/off, scale and transform — but not HDR / color
-- management, which wlr-randr has no concept of.
local util = require("core.backends.util")

local M = {}

M.name = "wlr-randr"
M.capabilities = { scale = true, transform = true, hdr = false }

local timeout = 5

local function run(cmd)
	return util.run(cmd, timeout)
end

-- wlr-randr spells transforms as names; the opaque shape uses Hyprland's
-- numeric encoding.
local TRANSFORM_TO_NUM = {
	["normal"] = 0,
	["90"] = 1,
	["180"] = 2,
	["270"] = 3,
	["flipped"] = 4,
	["flipped-90"] = 5,
	["flipped-180"] = 6,
	["flipped-270"] = 7,
}

local NUM_TO_TRANSFORM = {}
for name, num in pairs(TRANSFORM_TO_NUM) do
	NUM_TO_TRANSFORM[num] = name
end

-- wlr-randr matches `--mode` against the EDID rate at mHz precision, but the
-- opaque shape rounds rates to two decimals. Remember the exact rate each
-- rounded mode string came from so config_to_args can replay it verbatim
-- instead of failing with "unknown mode".
local exact_rates = {} -- [output name][mode string] = exact rate

local function remember_rate(name, mode, freq)
	local per_output = exact_rates[name]
	if not per_output then
		per_output = {}
		exact_rates[name] = per_output
	end
	per_output[mode] = freq
end

local function exact_rate(name, mode, fallback)
	local per_output = exact_rates[name]
	return per_output and per_output[mode] or fallback
end

-- Parse `wlr-randr` output into a list of Monitor values. Each output is a
-- header line `NAME "description"` followed by indented `Key: value` fields;
-- the mode lines live under the `Modes:` field and look like
-- `3440x1440 px, 59.973000 Hz (preferred, current)`. Position / Transform /
-- Scale come *after* the Modes block.
local function parse(out)
	local monitors = {}
	local monitor
	for line in util.lines(out) do
		-- A header is the only line that starts with a bare token followed by a
		-- quoted description; this also rejects error text such as
		-- "compositor doesn't support wlr-output-management".
		local name, description = line:match('^(%S+) "(.-)"')
		if name then
			monitor = util.new_monitor(name)
			monitor.description = description
			table.insert(monitors, monitor)
		elseif monitor then
			local field = line:match("^%s+(.-)%s*$") or ""
			local w, h, freq = field:match("^(%d+)x(%d+)%s+px,%s*(%d+%.?%d*)%s+Hz")
			if w then
				-- Mode line.
				w, h, freq = tonumber(w), tonumber(h), tonumber(freq)
				local mode = util.mode_string(w, h, freq)
				table.insert(monitor.availableModes, mode)
				remember_rate(monitor.name, mode, freq)
				if field:find("current", 1, true) then
					monitor.width, monitor.height = w, h
					monitor.refreshRate = freq
				end
			else
				local key, value = field:match("^([%w%s]+):%s*(.-)$")
				if key == "Enabled" then
					monitor.disabled = value ~= "yes"
				elseif key == "Position" then
					local px, py = value:match("^(-?%d+),%s*(-?%d+)")
					if px then
						monitor.x, monitor.y = tonumber(px), tonumber(py)
					end
				elseif key == "Scale" then
					monitor.scale = tonumber(value) or monitor.scale
				elseif key == "Transform" then
					monitor.transform = TRANSFORM_TO_NUM[value] or 0
				end
			end
		end
	end
	return monitors
end

-- Serialize one MonitorConfig into wlr-randr --output arguments.
local function config_to_args(cfg)
	if not cfg.enabled then
		return string.format("--output %s --off", cfg.name)
	end
	local w, h = math.floor(cfg.width), math.floor(cfg.height)
	local mode = util.mode_string(w, h, cfg.refresh or 60)
	local rate = exact_rate(cfg.name, mode, cfg.refresh or 60)
	local parts = {
		string.format("--output %s --on", cfg.name),
		string.format("--mode %dx%d@%.3fHz", w, h, rate),
		string.format("--pos %d,%d", math.floor(cfg.x), math.floor(cfg.y)),
	}
	if cfg.scale and cfg.scale > 0 then
		table.insert(parts, string.format("--scale %.6f", cfg.scale))
	end
	local transform = NUM_TO_TRANSFORM[cfg.transform or 0]
	if transform then
		table.insert(parts, "--transform " .. transform)
	end
	return table.concat(parts, " ")
end

-- --- backend contract ---

-- True when wlr-randr is present and reports at least one output.
function M.probe()
	local monitors = parse(run("wlr-randr"))
	return #monitors > 0
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
	-- Populate the exact-rate table in case the caller applied a profile
	-- without listing monitors first.
	if next(exact_rates) == nil then
		M.list_monitors()
	end
	local args = {}
	for _, cfg in ipairs(configs) do
		table.insert(args, config_to_args(cfg))
	end
	local out = run("wlr-randr " .. table.concat(args, " "))
	-- wlr-randr is silent on success; any output is a diagnostic.
	return out == "", out
end

return M
