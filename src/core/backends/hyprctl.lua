-- dkjson may not be present in every context that loads this module (e.g. when
-- the shared core is required from Hyprland's Lua). Make the require lenient:
-- when it is unavailable the backend simply fails its probe and the facade
-- falls through to the next candidate.
local json_ok, json = pcall(require, "dkjson")
if not json_ok then
	json = nil
end

-- hyprctl backend: drives a Hyprland instance through `hyprctl`. Supports the
-- full feature set (scale, transform, HDR / color management).
local M = {}

M.name = "hyprctl"
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

-- Bounds (seconds) for any single hyprctl call. Set via M.set_timeout.
local timeout = 5

-- Run `hyprctl <args>` and return the trimmed stdout. The call is bounded by
-- `timeout` so a wedged compositor cannot hang the UI.
local function run(args)
	local f = io.popen(string.format("timeout %s hyprctl %s 2>&1", timeout, args))
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
	if not json then
		return nil, "dkjson unavailable"
	end
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

-- --- backend contract ---

-- True when hyprctl is present and a Hyprland instance answers it.
function M.probe()
	local mons = raw_monitors()
	return mons ~= nil
end

-- Set the per-call timeout (seconds) for all hyprctl invocations.
function M.set_timeout(n)
	if type(n) == "number" and n > 0 then
		timeout = n
	end
end

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
