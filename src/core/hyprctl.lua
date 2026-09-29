local json = require("dkjson")

-- Abstract display/window-manager API. The public surface only deals in simple
-- or opaque Lua types (numbers, strings, booleans, and the Monitor /
-- MonitorConfig tables documented below) so it can be re-implemented on top of
-- a different compositor or tool without touching the callers.
local M = {}

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
--   availableModes: { {width, height, freq}, ... }
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

-- --- backend internals (hyprctl / hl) ---

-- Run `hyprctl <args>` and return the trimmed stdout.
local function run(args)
	local f = io.popen("hyprctl " .. args .. " 2>&1")
	local out = f:read("*a") or ""
	f:close()
	return out:match("^%s*(.-)%s*$")
end

-- Run a Lua snippet through `hyprctl eval` and return its trimmed output.
local function eval(snippet)
	return run('eval "' .. snippet .. '"')
end

-- Normalize a raw hyprctl monitor entry into the opaque Monitor shape.
local function normalize(m)
	return {
		name = m.name,
		description = m.description,
		x = m.x,
		y = m.y,
		width = m.width,
		height = m.height,
		scale = m.scale,
		transform = m.transform,
		refreshRate = m.refreshRate,
		focused = m.focused,
		disabled = m.disabled,
		availableModes = m.availableModes,
		currentFormat = m.currentFormat,
		colorManagementPreset = m.colorManagementPreset,
		sdrBrightness = m.sdrBrightness,
		sdrSaturation = m.sdrSaturation,
		sdrMaxLuminance = m.sdrMaxLuminance,
		sdrMinLuminance = m.sdrMinLuminance,
	}
end

-- Fetch all raw monitors, or nil plus the raw output on failure.
local function raw_monitors()
	local out = run("-j monitors all")
	local data = json.decode(out)
	if type(data) ~= "table" then
		return nil, out
	end
	return data, out
end

-- Serialize one MonitorConfig into an hl.monitor(...) snippet.
local function config_to_snippet(cfg)
	if not cfg.enabled then
		return string.format("hl.monitor({output='%s', disabled=true})", cfg.name)
	end
	local mode = string.format("%dx%d@%.2f", cfg.width, cfg.height, cfg.refresh)
	local pos = string.format("%dx%d", math.floor(cfg.x), math.floor(cfg.y))
	local s = string.format(
		"hl.monitor({output='%s', disabled=false, mode='%s', position='%s', scale=%.6f, transform=%d",
		cfg.name,
		mode,
		pos,
		cfg.scale,
		cfg.transform
	)
	if cfg.bitdepth == 10 then
		s = s
			.. string.format(
				", bitdepth=10, cm='%s', sdrbrightness=%.2f, sdrsaturation=%.2f, sdr_eotf='%s'",
				cfg.cm or "auto",
				cfg.sdrbrightness or 1.0,
				cfg.sdrsaturation or 1.0,
				cfg.sdr_eotf or "default"
			)
	else
		s = s .. ", bitdepth=8"
	end
	return s .. "})"
end

-- --- public API ---

-- List all monitors as opaque Monitor values. Returns (list, raw); the list is
-- empty when the backend could not be queried.
function M.list_monitors()
	local mons, raw = raw_monitors()
	if not mons then
		return {}, raw
	end
	local out = {}
	for _, m in ipairs(mons) do
		table.insert(out, normalize(m))
	end
	return out, raw
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
	if #configs == 0 then
		return true, ""
	end
	local snippets = {}
	for _, cfg in ipairs(configs) do
		table.insert(snippets, config_to_snippet(cfg))
	end
	local out = eval(table.concat(snippets, " ; "))
	local ok = out == "ok" or out == ""
	return ok, out
end

-- Move the tool's own window onto the active workspace so the UI stays visible
-- after a layout change. Returns (ok, output).
function M.ensure_window_on_active_workspace()
	local snippet = [[
local active = hl.get_active_workspace()
for _, w in ipairs(hl.get_windows()) do
  if w.title == 'hyprlayout' and w.workspace.id ~= active.id then
    hl.dispatch(hl.dsp.window.move({window=w, workspace=active.id, follow=true}))
  end
end
]]
	local out = eval(snippet)
	local ok = out == "ok" or out == ""
	return ok, out
end

return M
