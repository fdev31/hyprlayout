-- Facade / selector for the active display backend.
--
-- On first use it probes the known backends in order (hyprctl, xrandr,
-- wlr-randr) and locks onto the first one that works. All public API calls are
-- delegated to that backend. The Monitor / MonitorConfig opaque shapes are the
-- same ones documented in core.backends.hyprctl.
local M = {}

local candidates = {
	require("core.backends.hyprctl"),
	require("core.backends.xrandr"),
	require("core.backends.wlrrandr"),
}

local active = nil -- selected backend module, or nil if none available
local active_name = nil -- its name
local pending_timeout = nil
local detected = false

-- Lazily detect and lock onto the first working backend. Runs once.
local function ensure()
	if detected then
		return active
	end
	detected = true
	for _, be in ipairs(candidates) do
		local ok, works = pcall(be.probe, be)
		if ok and works then
			active = be
			active_name = be.name
			if pending_timeout then
				be.set_timeout(pending_timeout)
			end
			break
		end
	end
	return active
end

-- Name of the active backend, or nil if none is available.
function M.name()
	ensure()
	return active_name
end

-- Capabilities of the active backend: {scale=bool, transform=bool, hdr=bool}.
-- Returns a conservative all-false table when no backend is available.
function M.capabilities()
	local be = ensure()
	if be then
		return be.capabilities
	end
	return { scale = false, transform = false, hdr = false }
end

-- Set the per-call timeout (seconds). Applied to the active backend, or stored
-- and applied once a backend is detected.
function M.set_timeout(n)
	if type(n) ~= "number" or n <= 0 then
		return
	end
	pending_timeout = n
	local be = ensure()
	if be then
		be.set_timeout(n)
	end
end

-- List all monitors as opaque Monitor values. Returns (list, raw); the list is
-- empty when no backend is available.
function M.list_monitors()
	local be = ensure()
	if not be then
		return {}, ""
	end
	return be.list_monitors()
end

-- Return the focused (or first non-disabled) monitor as an opaque Monitor, or nil.
function M.active_monitor()
	local mons = M.list_monitors()
	for _, m in ipairs(mons) do
		if m.focused and not m.disabled then
			return m
		end
	end
	for _, m in ipairs(mons) do
		if not m.disabled then
			return m
		end
	end
	return nil
end

-- Return the name (string) of the monitor containing the given (x, y) point, or nil.
function M.monitor_at_point(x, y)
	local mons = M.list_monitors()
	for _, m in ipairs(mons) do
		if not m.disabled then
			local mx, my = m.x or 0, m.y or 0
			local mw, mh = m.width or 0, m.height or 0
			if x >= mx and x < mx + mw and y >= my and y < my + mh then
				return m.name
			end
		end
	end
	return nil
end

-- Apply a list of MonitorConfig values. Returns (ok, output).
function M.configure_monitors(configs)
	local be = ensure()
	if not be then
		return false, "no display backend available"
	end
	return be.configure_monitors(configs)
end

-- Move the tool's own window onto the active workspace so the UI stays visible
-- after a layout change. Backends without a window manager return (true, "").
function M.ensure_window_on_active_workspace()
	local be = ensure()
	if not be then
		return true, ""
	end
	if be.ensure_window_on_active_workspace then
		return be.ensure_window_on_active_workspace()
	end
	return true, ""
end

return M
