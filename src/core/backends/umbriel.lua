-- Umbriel display backend for hyprlayout.
--
-- Umbriel is a wlroots-based Wayland compositor. It exposes rich output state
-- via `umbriel outputs --json` (JSON array) and delegates live reconfiguration
-- (mode, position, scale, transform, on/off) to `wlr-randr`. Enable/disable
-- is handled by `umbriel msg output-{enable,disable}`.
--
-- This backend reads state from the JSON output and writes via wlr-randr,
-- giving us the full feature set including HDR awareness.

local util = require("core.backends.util")

-- dkjson may not be present in every context that loads this module (e.g. when
-- the shared core is required from a compositor's Lua). Make the require
-- lenient: when it is unavailable the backend simply fails its probe and the
-- facade falls through to the next candidate.
local json_ok, json = pcall(require, "dkjson")
if not json_ok then
	json = nil
end

local M = {}

M.name = "umbriel"
M.capabilities = { scale = true, transform = true, hdr = true }

-- A Monitor is an opaque value describing one display. Fields:
--   name: string          unique id / output name
--   description: string
--   x, y: number          top-left position
--   width, height: number
--   scale: number
--   transform: number
--   refreshRate: number
--   focused: boolean
--   disabled: boolean
--   availableModes: { "WxH@F", ... }   (strings; see core.backends.util.mode_string)
--   currentFormat: string
--   colorManagementPreset: string
--   sdrBrightness, sdrSaturation, sdrMaxLuminance, sdrMinLuminance: number
--
-- A MonitorConfig is an opaque value describing the desired state of one display:
--   name: string          (required) matches a Monitor name
--   enabled: boolean
--   width, height: number  mode
--   refresh: number
--   x, y: number           position
--   scale: number
--   transform: number
--   bitdepth: number
--   cm, sdr_eotf: string
--   sdrbrightness, sdrsaturation: number

-- Bounds (seconds) for any single command invocation. Set via M.set_timeout.
local timeout = 5

-- Run a shell command bounded by `timeout` seconds; return trimmed output
-- (stdout and stderr merged, so failures are visible to the caller).
local function run(cmd)
	return util.run(cmd, timeout)
end

-- Umbriel spells transforms as names in its JSON; the opaque shape uses
-- Hyprland's numeric encoding.
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

-- Normalize a raw umbriel JSON output entry into the opaque Monitor shape.
local function parse(raw)
	local mon = util.new_monitor(raw.name or "unknown")

	-- Description
	if raw.description then
		mon.description = raw.description
	end

	-- Position: JSON object {x, y}
	if raw.position and type(raw.position) == "table" then
		mon.x = raw.position.x or 0
		mon.y = raw.position.y or 0
	end

	-- Logical size
	if raw.logical_size and type(raw.logical_size) == "table" then
		mon.width = raw.logical_size.width or 0
		mon.height = raw.logical_size.height or 0
	end

	-- Scale
	if raw.scale then
		mon.scale = raw.scale
	end

	-- Transform: string → number
	mon.transform = TRANSFORM_TO_NUM[raw.transform] or 0

	-- Enabled / disabled
	mon.disabled = not raw.enabled

	-- Focused
	mon.focused = raw.focused or false

	-- Modes: array of objects with width, height, refresh_mhz (mHz), current, preferred
	if raw.modes and type(raw.modes) == "table" then
		mon.availableModes = {}
		for i, m in ipairs(raw.modes) do
			local freq = (m.refresh_mhz or 0) / 1000
			local mode_str = util.mode_string(m.width, m.height, freq)
			table.insert(mon.availableModes, mode_str)
			-- Remember exact rates for later wlr-randr replay.
			remember_rate(mon.name, mode_str, freq)
			-- Current mode determines the monitor's active resolution and refresh.
			if m.current then
				mon.width = m.width
				mon.height = m.height
				mon.refreshRate = freq
			end
		end
	end

	-- HDR → currentFormat
	mon.currentFormat = raw.hdr_active and "XR30" or "XRGB8888"

	-- HDR → colorManagementPreset
	mon.colorManagementPreset = raw.hdr_active and "hdr" or "srgb"

	-- SDR values (defaults; not in JSON)
	mon.sdrBrightness = 1.0
	mon.sdrSaturation = 1.0
	mon.sdrMaxLuminance = 80
	mon.sdrMinLuminance = 0.2

	return mon
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

-- True when `umbriel outputs --json` returns valid JSON with at least one
-- output.
function M.probe()
	if not json then
		return false
	end
	local out = run("umbriel outputs --json")
	if not out or out == "" then
		return false
	end
	local ok, data = pcall(json.decode, out)
	if not ok or type(data) ~= "table" then
		return false
	end
	-- dkjson produces 1-based arrays; an empty array decodes to an empty table.
	return #data > 0
end

-- Set the per-call timeout (seconds) for all command invocations.
function M.set_timeout(n)
	if type(n) == "number" and n > 0 then
		timeout = n
	end
end

-- List all monitors as opaque Monitor values. Returns (list, raw).
function M.list_monitors()
	if not json then
		return {}, "dkjson unavailable"
	end
	local out = run("umbriel outputs --json")
	if not out or out == "" then
		return {}, "umbriel outputs --json returned empty output"
	end
	local ok, data = pcall(json.decode, out)
	if not ok then
		return {}, "failed to parse umbriel JSON: " .. tostring(data)
	end
	if type(data) ~= "table" then
		return {}, out
	end
	local monitors = {}
	for i = 1, #data do
		table.insert(monitors, parse(data[i]))
	end
	return monitors, out
end

-- Apply a list of MonitorConfig values. Returns (ok, output).
-- Uses wlr-randr for the layout changes (mode, position, scale, transform,
-- on/off) and `umbriel msg output-{enable,disable}` for enable/disable
-- toggling, since wlr-randr's --on/--off is the proven write path in
-- Umbriel.
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

-- Move the tool's own window onto the active workspace so the UI stays
-- visible after a layout change. Umbriel does not expose a direct
-- "move window to workspace" CLI in the same way Hyprland does; this is a
-- no-op that signals success.
function M.ensure_window_on_active_workspace()
	return true, ""
end

-- Exposed for the fixture tests (tests/backends_test.lua).
M._parse = parse
M._config_to_args = config_to_args

return M
