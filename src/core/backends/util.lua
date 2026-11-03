-- Shared helpers for the subprocess-driven backends (hyprctl, xrandr,
-- wlr-randr).
local M = {}

-- Run a shell command bounded by `timeout` seconds; return trimmed output
-- (stdout and stderr merged, so failures are visible to the caller).
function M.run(cmd, timeout)
	local f = io.popen(string.format("timeout %s %s 2>&1", timeout, cmd))
	if not f then
		return ""
	end
	local out = f:read("*a") or ""
	f:close()
	return out:match("^%s*(.-)%s*$")
end

-- Iterate over the lines of `s`. Use `[^\n]+`, not `.*` — in Lua patterns `.`
-- matches newlines, so a greedy `.*` swallows the whole string as one line.
function M.lines(s)
	return (s or ""):gmatch("[^\n]+")
end

-- The canonical availableModes element: a "WxH@F" string.
function M.mode_string(w, h, freq)
	return string.format("%dx%d@%.2f", w, h, freq)
end

-- Build a default Monitor value (see core.backends.hyprctl for the shape);
-- parsers fill in the fields they can discover.
function M.new_monitor(name)
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

return M
