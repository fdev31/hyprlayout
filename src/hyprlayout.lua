-- hyprlayout.lua — shared entry point for Hyprland's Lua context.
--
-- This is a thin wrapper that lets a Hyprland Lua config drive the *same*
-- layout logic the LÖVE app uses. It only requires the shared core
-- (core/*), which is backend-agnostic: when required from inside Hyprland the
-- backend facade selects the `hl` backend (hl.get_monitors / hl.monitor), so
-- no hyprctl, no JSON parsing, and no subprocess is involved.
--
-- Usage in hyprland.lua:
--   require("hyprlayout").install()   -- auto-apply on monitor add/remove
--   -- or, explicitly:
--   local hyprlayout = require("hyprlayout")
--   hyprlayout.auto()                 -- same as `hyprlayout -m`
--   hyprlayout.apply_profile("Cinema") -- same as `hyprlayout Cinema`
--
-- This file is self-locating: it adds its own directory to package.path so the
-- core/* modules resolve no matter where it is required from (e.g. via a
-- symlink in the Hyprland config dir).
--
-- Every function returns (ok, message): ok is a boolean and message is either
-- a human-readable error string (on failure) or, for auto(), the applied
-- profile name (on success).

-- Resolve the directory containing this file, following symlinks, and make
-- the sibling core/ modules importable.
local function self_dir()
	local src = debug.getinfo(1, "S").source:match("^@(.*)$") or ""
	local real = src
	local f = io.popen('realpath -e "' .. src .. '" 2>/dev/null')
	if f then
		local r = f:read("*a"):match("(.-)%.lua%s*$")
		f:close()
		if r and r ~= "" then
			real = r
		end
	end
	return real:match("^(.*)/[^/]+$") or "."
end
package.path = self_dir() .. "/?.lua;" .. package.path

local backend = require("core.backend")
local screens = require("core.screens")
local profiles = require("core.profiles")
local settings = require("core.settings")
local profile_configs = require("core.profile_configs")
local profile_match = require("core.profile_match")

local M = {}

-- Must match Panel.DEFAULT_CANVAS_SCALE in the LÖVE app; profiles store their
-- positions in real pixels derived from this scale, so we must use the same
-- value to round-trip.
local DEFAULT_CANVAS_SCALE = 6

-- Resolve the canvas scale the same way the LÖVE app does: the saved value
-- (clamped to [2, 16]) or the default.
local function canvas_scale()
	local saved = settings.load()
	if saved.canvas_scale then
		return math.max(2, math.min(16, saved.canvas_scale))
	end
	return DEFAULT_CANVAS_SCALE
end

-- Load the current screens through the active backend. Returns (screens, err).
local function load_screens()
	local ok = screens.load()
	if not ok or #screens.displayInfo == 0 then
		return nil, "no screens found: " .. tostring(screens.error)
	end
	return screens.displayInfo
end

-- Apply a list of MonitorConfigs through the active backend. Returns (ok, err).
local function apply(configs)
	local ok, out = backend.configure_monitors(configs)
	if not ok then
		return false, out
	end
	return true, ""
end

-- Same as `hyprlayout -m`: find the saved profile whose screen set matches the
-- current monitor set and apply it. Returns (ok, name_or_err).
function M.auto()
	local current, err = load_screens()
	if not current then
		return false, err
	end

	local name, data = profile_match.find_matching_profile(current)
	if not data then
		return false, "no matching profile"
	end

	local configs = profile_configs.make(data, current, canvas_scale())
	local ok, aerr = apply(configs)
	if not ok then
		return false, aerr
	end
	return true, name
end

-- Same as `hyprlayout <name>`: apply the named profile to the current screens.
-- Returns (ok, err).
function M.apply_profile(name)
	local data = profiles.load_profile(name)
	if not data then
		return false, "no such profile: " .. tostring(name)
	end

	local current, err = load_screens()
	if not current then
		return false, err
	end

	local configs = profile_configs.make(data, current, canvas_scale())
	return apply(configs)
end

-- List the saved profile names. Returns a list of strings.
function M.list_profiles()
	return profiles.list_profiles()
end

local installed = false

-- Install event handlers that automatically apply the matching profile when
-- the monitor configuration changes (a monitor is plugged in or removed).
-- Call this once from your Hyprland Lua config:
--   require("hyprlayout").install()
--
-- Returns (ok, err).
function M.install()
	if installed then
		return true
	end
	if type(hl) ~= "table" or type(hl.on) ~= "function" then
		return false, "hl.on not available (not running inside Hyprland?)"
	end

	local function on_monitors_changed()
		local ok, msg = M.auto()
		if not ok then
			print("[hyprlayout] auto-apply failed: " .. tostring(msg))
		end
	end

	hl.on("monitor.added", function(_monitor)
		on_monitors_changed()
	end)
	hl.on("monitor.removed", function(_monitor)
		on_monitors_changed()
	end)

	installed = true
	return true
end

return M
