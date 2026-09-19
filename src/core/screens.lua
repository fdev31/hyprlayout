local json = require("dkjson")

local Mode = {}
Mode.__index = Mode

function Mode.new(width, height, freq)
	return setmetatable({ width = width, height = height, freq = freq }, Mode)
end

function Mode:__tostring()
	return string.format("%dx%d@%.2fHz", self.width, self.height, self.freq)
end

local Screen = {}
Screen.__index = Screen

function Screen.new(opts)
	return setmetatable({
		uid = opts.uid,
		name = opts.name or opts.uid,
		active = opts.active or false,
		position = opts.position or { 0, 0 },
		mode = opts.mode or nil,
		scale = opts.scale or 1,
		available = opts.available or {},
		transform = opts.transform or 0,
		hdr_enabled = opts.hdr_enabled or false,
		current_format = opts.current_format or "XRGB8888",
		cm_preset = opts.cm_preset or "srgb",
		cm = opts.cm or "auto",
		sdrbrightness = opts.sdrbrightness or 1.0,
		sdrsaturation = opts.sdrsaturation or 1.0,
		sdr_eotf = opts.sdr_eotf or "default",
		sdr_max_luminance = opts.sdr_max_luminance or 80,
		sdr_min_luminance = opts.sdr_min_luminance or 0.2,
	}, Screen)
end

local M = {}
M.displayInfo = {}
M.error = nil

local function run(cmd)
	local f = io.popen(cmd .. " 2>&1")
	local out = f:read("*a") or ""
	f:close()
	return out
end

local function parse_mode_str(txt)
	local w, h, freq = txt:match("^(%d+)x(%d+)@(%d+%.?%d*)Hz?$")
	if not w then
		w, h, freq = txt:match("^(%d+)x(%d+)@(%d+%.?%d*)")
	end
	if not w then
		return nil
	end
	return Mode.new(tonumber(w), tonumber(h), tonumber(freq) or 60)
end

function M.load()
	M.displayInfo = {}
	M.error = nil

	local out = run("hyprctl -j monitors all")
	local monitors = json.decode(out)
	if not monitors or type(monitors) ~= "table" then
		M.error = "Failed to get monitors from hyprctl:\n" .. out:sub(1, 200)
		print(M.error)
		return false
	end

	for _, monitor in ipairs(monitors) do
		local available = {}
		for _, m in ipairs(monitor.availableModes or {}) do
			local mode = parse_mode_str(m)
			if mode then
				table.insert(available, mode)
			end
		end

		local cur_mode = nil
		for _, m in ipairs(available) do
			if
				m.width == monitor.width
				and m.height == monitor.height
				and math.abs(m.freq - (monitor.refreshRate or 60)) < 0.5
			then
				cur_mode = m
				break
			end
		end
		if not cur_mode then
			cur_mode = Mode.new(monitor.width or 1920, monitor.height or 1080, monitor.refreshRate or 60)
		end

		local active = not monitor.disabled

		local current_format = monitor.currentFormat or "XRGB8888"
		local cm_preset = monitor.colorManagementPreset or "srgb"
		local is_hdr = current_format == "XR30"
			or current_format == "XB30"
			or cm_preset == "hdr"
		local screen = Screen.new({
			uid = monitor.name,
			name = monitor.description or monitor.name,
			active = active,
			scale = monitor.scale or 1,
			position = { monitor.x or 0, monitor.y or 0 },
			available = available,
			mode = cur_mode,
			transform = monitor.transform or 0,
			hdr_enabled = is_hdr,
			current_format = current_format,
			cm_preset = cm_preset,
			cm = cm_preset,
			sdrbrightness = monitor.sdrBrightness or 1.0,
			sdrsaturation = monitor.sdrSaturation or 1.0,
			sdr_max_luminance = monitor.sdrMaxLuminance or 80,
			sdr_min_luminance = monitor.sdrMinLuminance or 0.2,
		})
		table.insert(M.displayInfo, screen)
	end

	return #M.displayInfo > 0
end

return M
