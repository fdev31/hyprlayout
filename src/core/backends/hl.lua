-- hl backend: drives Hyprland from *inside* Hyprland's own Lua context using
-- the `hl.*` API. No hyprctl, no JSON, no subprocess — the values come back as
-- native Lua tables / userdata. This is the backend used when the shared core
-- is `require`d from a Hyprland Lua config (see src/hyprlayout.lua).
--
-- It speaks the same opaque Monitor / MonitorConfig shapes as the hyprctl
-- backend (see core.backends.hyprctl), so the rest of the core is agnostic to
-- which one is active.
local M = {}

M.name = "hl"
M.capabilities = { scale = true, transform = true, hdr = true }

-- True when we are running inside Hyprland's Lua context (the `hl` global is a
-- table exposing the query API). In LÖVE this is nil, so the facade falls
-- through to the other candidates.
function M.probe()
	return type(hl) == "table" and type(hl.get_monitors) == "function"
end

-- The hl backend talks to the compositor in-process; there is nothing to time
-- out, so this is a no-op (kept for contract conformance).
function M.set_timeout(_n) end

-- Convert one HL.Monitor's available_modes (a list of {width, height,
-- refresh_rate, preferred}) into the "WxH@F" strings the opaque shape expects.
local function available_modes_strings(m)
	local out = {}
	for _, am in ipairs(m.available_modes or {}) do
		table.insert(out, string.format("%dx%d@%.2f", am.width, am.height, am.refresh_rate))
	end
	return out
end

-- Normalize one HL.Monitor object into the opaque Monitor shape.
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
		refreshRate = m.refresh_rate,
		focused = m.focused,
		disabled = not m.enabled,
		availableModes = available_modes_strings(m),
		-- HL.Monitor does not expose the current pixel format or the sdr*
		-- values, so we omit them and let core.screens fall back to defaults.
		-- The color-management preset is exposed as `cm`, which is what
		-- core.screens uses to derive hdr_enabled.
		colorManagementPreset = m.cm,
	}
end

-- List all monitors (including disabled ones) as opaque Monitor values.
-- Returns (list, raw); raw is always "" here because there is no raw output.
function M.list_monitors()
	local raw = ""
	local mons
	local ok = pcall(function()
		mons = hl.get_monitors({ all = true })
	end)
	if not ok or type(mons) ~= "table" then
		return {}, raw
	end
	local out = {}
	for _, m in ipairs(mons) do
		table.insert(out, normalize(m))
	end
	return out, raw
end

-- Convert one MonitorConfig into an hl.monitor(...) call.
local function apply_config(cfg)
	if not cfg.enabled then
		hl.monitor({ output = cfg.name, disabled = true })
		return
	end
	local args = {
		output = cfg.name,
		mode = string.format("%dx%d@%.2f", cfg.width, cfg.height, cfg.refresh),
		position = string.format("%dx%d", math.floor(cfg.x), math.floor(cfg.y)),
		scale = cfg.scale,
		transform = cfg.transform,
	}
	if cfg.bitdepth == 10 then
		args.bitdepth = 10
		args.cm = cfg.cm or "auto"
		args.sdrbrightness = cfg.sdrbrightness or 1.0
		args.sdrsaturation = cfg.sdrsaturation or 1.0
		args.sdr_eotf = cfg.sdr_eotf or "default"
	else
		args.bitdepth = 8
	end
	hl.monitor(args)
end

-- Apply a list of MonitorConfig values. Returns (ok, output); output is always
-- "" because hl.monitor does not return a string.
function M.configure_monitors(configs)
	if #configs == 0 then
		return true, ""
	end
	local ok, err = pcall(function()
		for _, cfg in ipairs(configs) do
			apply_config(cfg)
		end
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, ""
end

return M
