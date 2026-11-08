-- Fixture-based tests for the text-parsing display backends.
--
--   just test      (or: lua tests/backends_test.lua)
--
-- These backends are pure functions over captured CLI output, so they can be
-- exercised without a compositor. Run them whenever a parser changes.

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local wlrrandr = require("core.backends.wlrrandr")
local xrandr = require("core.backends.xrandr")
local screens = require("core.screens")

local failures = 0
local checks = 0

local function check(label, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(string.format("FAIL %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
	end
end

-- --- wlr-randr -------------------------------------------------------------

local WLR_OUTPUT = [[
HDMI-A-1 "Hisense Electric Co., Ltd. - HISENSE - HDMI-A-1"
  Make: Hisense Electric Co., Ltd.
  Model: HISENSE
  Serial: 0x676C626C
  Physical size: 1430x800 mm
  Enabled: yes
  Modes:
    3840x2160 px, 60.000000 Hz (preferred, current)
    1920x1080 px, 59.938999 Hz
  Position: 0,0
  Transform: normal
  Scale: 1.000000
  Adaptive Sync: disabled
DP-1 "Microstep - MAG342CQPV - DP-1"
  Make: Microstep
  Model: MAG342CQPV
  Enabled: yes
  Modes:
    3440x1440 px, 59.973000 Hz (preferred)
    2560x1440 px, 99.982002 Hz (current)
  Position: 3840,120
  Transform: 270
  Scale: 1.250000
DP-2 "Unknown"
  Enabled: no
]]

local wmons = wlrrandr._parse(WLR_OUTPUT)

check("wlr: monitor count", #wmons, 3)

check("wlr: [1] name", wmons[1].name, "HDMI-A-1")
check("wlr: [1] description", wmons[1].description, "Hisense Electric Co., Ltd. - HISENSE - HDMI-A-1")
check("wlr: [1] disabled", wmons[1].disabled, false)
check("wlr: [1] width", wmons[1].width, 3840)
check("wlr: [1] height", wmons[1].height, 2160)
check("wlr: [1] refreshRate", wmons[1].refreshRate, 60.0)
check("wlr: [1] mode count", #wmons[1].availableModes, 2)
check("wlr: [1] mode[1]", wmons[1].availableModes[1], "3840x2160@60.00")

-- Position / Transform / Scale appear *after* the Modes block; a mode
-- sub-parser that never hands control back silently drops all three.
check("wlr: [2] x", wmons[2].x, 3840)
check("wlr: [2] y", wmons[2].y, 120)
check("wlr: [2] scale", wmons[2].scale, 1.25)
check("wlr: [2] transform", wmons[2].transform, 3)
-- "(current)" must win over "(preferred)".
check("wlr: [2] width", wmons[2].width, 2560)
check("wlr: [2] refreshRate", wmons[2].refreshRate, 99.982002)

check("wlr: [3] disabled", wmons[3].disabled, true)

-- Error output must not be mistaken for a display, or probe() hijacks the
-- facade from a backend that would actually work.
check("wlr: rejects error output", #wlrrandr._parse("compositor doesn't support wlr-output-management"), 0)
check("wlr: rejects empty output", #wlrrandr._parse(""), 0)

-- wlr-randr has no notion of focus; the facade falls back to "first enabled".
check("wlr: nothing is focused", wmons[1].focused or wmons[2].focused, false)

check(
	"wlr: config_to_args enabled",
	wlrrandr._config_to_args({
		name = "DP-1",
		enabled = true,
		width = 3440,
		height = 1440,
		refresh = 59.973,
		x = 0,
		y = 0,
		scale = 1.0,
		transform = 0,
	}),
	"--output DP-1 --on --mode 3440x1440@59.973Hz --pos 0,0 --scale 1.000000 --transform normal"
)
-- wlr-randr matches --mode at mHz precision, so the two-decimal rate carried by
-- the opaque shape (59.97) has to be expanded back to the EDID rate (59.973)
-- that the parse step saw. Otherwise it fails with "unknown mode".
check(
	"wlr: config_to_args restores the exact refresh rate",
	wlrrandr._config_to_args({
		name = "DP-1",
		enabled = true,
		width = 2560,
		height = 1440,
		refresh = 99.98,
		x = 0,
		y = 0,
		scale = 1.0,
		transform = 0,
	}),
	"--output DP-1 --on --mode 2560x1440@99.982Hz --pos 0,0 --scale 1.000000 --transform normal"
)
check(
	"wlr: config_to_args disabled",
	wlrrandr._config_to_args({ name = "DP-2", enabled = false }),
	"--output DP-2 --off"
)

-- --- xrandr ----------------------------------------------------------------

local XRANDR_OUTPUT = [[
Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
DP-1 connected primary 1920x1080+0+0 (normal left inverted right) 527mm x 296mm
   1920x1080     60.00*+  50.00    59.94
   1280x720      59.94
HDMI-1 connected 1920x1080+1920+0 (normal left inverted right) 527mm x 296mm
   1920x1080     60.00*+
DVI-0 disconnected (normal left inverted right x axis y axis)
]]

local xmons = xrandr._parse(XRANDR_OUTPUT)

check("xrandr: monitor count", #xmons, 3)
check("xrandr: [1] name", xmons[1].name, "DP-1")
check("xrandr: [1] disabled", xmons[1].disabled, false)
check("xrandr: [1] focused (primary)", xmons[1].focused, true)
check("xrandr: [1] x", xmons[1].x, 0)
check("xrandr: [1] width", xmons[1].width, 1920)
check("xrandr: [1] refreshRate", xmons[1].refreshRate, 60.0)
-- Three rates on the first line plus one on the second.
check("xrandr: [1] mode count", #xmons[1].availableModes, 4)
check("xrandr: [1] mode[1]", xmons[1].availableModes[1], "1920x1080@60.00")
check("xrandr: [1] mode[2]", xmons[1].availableModes[2], "1920x1080@50.00")
check("xrandr: [2] x", xmons[2].x, 1920)
check("xrandr: [2] focused", xmons[2].focused, false)
check("xrandr: [3] disconnected is disabled", xmons[3].disabled, true)

-- "Can't open display" must not parse as an output named "Can't", or xrandr
-- hijacks the facade on a Wayland session with no X server.
check("xrandr: rejects error output", #xrandr._parse("Can't open display "), 0)
check("xrandr: rejects empty output", #xrandr._parse(""), 0)
-- A connected-but-off output has no geometry and must stay disabled.
check(
	"xrandr: connected without geometry is disabled",
	xrandr._parse("DP-3 connected (normal left inverted right)")[1].disabled,
	true
)

check(
	"xrandr: config_to_args uses comma-separated --pos",
	xrandr._config_to_args({ name = "DP-1", enabled = true, width = 1920, height = 1080, refresh = 60, x = 1920, y = 0 }),
	"--output DP-1 --on --pos 1920,0 --mode 1920x1080 --rate 60.00"
)

-- --- the opaque shape actually feeds core.screens --------------------------
--
-- availableModes must be "WxH@F" strings: core.screens.parse_mode_str calls
-- :match on each element, so a table element is a hard runtime error.

local scr = screens.from_monitors(wmons)
check("screens: count", #scr, 3)
check("screens: [1] uid", scr[1].uid, "HDMI-A-1")
check("screens: [1] available modes", #scr[1].available, 2)
check("screens: [1] current mode width", scr[1].mode.width, 3840)
check("screens: [2] position x", scr[2].position[1], 3840)
check("screens: [2] scale", scr[2].scale, 1.25)
check("screens: [3] inactive", scr[3].active, false)

-- --- umbriel ---------------------------------------------------------------

local umbriel = require("core.backends.umbriel")
local json_ok, json = pcall(require, "dkjson")
if not json_ok then
	print("SKIP umbriel: dkjson not available")
	json = nil
end

if json then
	local UMBRIEL_JSON = [[
[
  {
    "active_workspace": "DP-1:3",
    "adaptive_sync": null,
    "config_name": "Microstep MAG342CQPV DB6H513700137",
    "description": "Microstep MAG342CQPV DB6H513700137 (DP-1)",
    "direct_scanout": {
        "active": false, "commit_seq": 137942, "commits": 137942,
        "reason": "composited", "scanout_commits": 0, "window": null
    },
    "enabled": true,
    "focused": true,
    "hdr_active": false,
    "logical_size": {"height": 1440, "width": 3440},
    "make": "Microstep",
    "model": "MAG342CQPV",
    "modes": [
      {"current": true, "height": 1440, "preferred": true, "refresh_mhz": 59999, "width": 3440},
      {"current": false, "height": 1440, "preferred": false, "refresh_mhz": 99998, "width": 3440},
      {"current": false, "height": 1440, "preferred": false, "refresh_mhz": 50000, "width": 3440},
      {"current": false, "height": 1440, "preferred": false, "refresh_mhz": 99793, "width": 2560},
      {"current": false, "height": 1440, "preferred": false, "refresh_mhz": 60000, "width": 2560}
    ],
    "name": "DP-1",
    "physical_size": {"height_mm": 330, "width_mm": 790},
    "position": {"x": 0, "y": 0},
    "powered": true,
    "scale": 1.0,
    "serial": "DB6H513700137",
    "transform": "normal",
    "usable_area": {"height": 1406, "width": 3440, "x": 0, "y": 34}
  },
  {
    "name": "DP-2",
    "description": "Samsung Odyssey G7 (DP-2)",
    "enabled": true,
    "focused": false,
    "hdr_active": true,
    "logical_size": {"height": 1440, "width": 2560},
    "modes": [
      {"current": true, "height": 1440, "preferred": true, "refresh_mhz": 143980, "width": 2560},
      {"current": false, "height": 1080, "preferred": false, "refresh_mhz": 59994, "width": 1920}
    ],
    "position": {"x": 3440, "y": 0},
    "scale": 1.0,
    "transform": "90"
  },
  {
    "name": "HDMI-A-1",
    "description": "LG Electronics (HDMI-A-1)",
    "enabled": false,
    "focused": false,
    "hdr_active": false,
    "logical_size": {"height": 1080, "width": 1920},
    "modes": [
      {"current": true, "height": 1080, "preferred": true, "refresh_mhz": 59994, "width": 1920}
    ],
    "position": {"x": 0, "y": 0},
    "scale": 1.0,
    "transform": "normal"
  }
]
]]

	local ok, data = pcall(json.decode, UMBRIEL_JSON)
	assert(ok, "failed to decode umbriel fixture JSON")

	local umbriel_mons = {}
	for i = 1, #data do
		table.insert(umbriel_mons, umbriel._parse(data[i]))
	end

	-- Parse: monitor count and per-monitor fields.
	check("umbriel: monitor count", #umbriel_mons, 3)

	check("umbriel: [1] name", umbriel_mons[1].name, "DP-1")
	check("umbriel: [1] description", umbriel_mons[1].description, "Microstep MAG342CQPV DB6H513700137 (DP-1)")
	check("umbriel: [1] disabled", umbriel_mons[1].disabled, false)
	check("umbriel: [1] focused", umbriel_mons[1].focused, true)
	check("umbriel: [1] width", umbriel_mons[1].width, 3440)
	check("umbriel: [1] height", umbriel_mons[1].height, 1440)
	check("umbriel: [1] refreshRate", umbriel_mons[1].refreshRate, 59.999)
	check("umbriel: [1] scale", umbriel_mons[1].scale, 1.0)
	check("umbriel: [1] transform", umbriel_mons[1].transform, 0)
	check("umbriel: [1] x", umbriel_mons[1].x, 0)
	check("umbriel: [1] y", umbriel_mons[1].y, 0)
	check("umbriel: [1] availableModes count", #umbriel_mons[1].availableModes, 5)
	check("umbriel: [1] availableModes[1]", umbriel_mons[1].availableModes[1], "3440x1440@60.00")
	check("umbriel: [1] availableModes[4]", umbriel_mons[1].availableModes[4], "2560x1440@99.79")
	check("umbriel: [1] currentFormat", umbriel_mons[1].currentFormat, "XRGB8888")
	check("umbriel: [1] colorManagementPreset", umbriel_mons[1].colorManagementPreset, "srgb")

	check("umbriel: [2] name", umbriel_mons[2].name, "DP-2")
	check("umbriel: [2] transform", umbriel_mons[2].transform, 1)
	check("umbriel: [2] currentFormat", umbriel_mons[2].currentFormat, "XR30")
	check("umbriel: [2] colorManagementPreset", umbriel_mons[2].colorManagementPreset, "hdr")
	check("umbriel: [2] x", umbriel_mons[2].x, 3440)
	check("umbriel: [2] y", umbriel_mons[2].y, 0)
	check("umbriel: [2] refreshRate", umbriel_mons[2].refreshRate, 143.98)

	check("umbriel: [3] disabled", umbriel_mons[3].disabled, true)
	check("umbriel: [3] name", umbriel_mons[3].name, "HDMI-A-1")

	-- Edge cases.
	-- An empty JSON array decodes to an empty table → zero monitors.
	local empty_data = json.decode("[]")
	check("umbriel: empty JSON array yields 0 entries", #empty_data, 0)
	-- Invalid JSON decodes to nil (dkjson returns nil, errmsg on failure).
	local _, data_inv = pcall(json.decode, "not json")
	check("umbriel: invalid JSON yields nil", data_inv, nil)
	-- A single entry with no fields still produces a valid (disabled) monitor.
	local empty_mon = umbriel._parse({})
	check("umbriel: bare entry has a name", empty_mon.name, "unknown")
	check("umbriel: bare entry is disabled", empty_mon.disabled, true)

	-- Missing description falls back to the name.
	local no_desc = umbriel._parse({ name = "VGA-1", enabled = true })
	check("umbriel: missing description uses name", no_desc.description, "VGA-1")

	-- config_to_args.
	check(
		"umbriel: config_to_args enabled",
		umbriel._config_to_args({
			name = "DP-1",
			enabled = true,
			width = 3440,
			height = 1440,
			refresh = 60,
			x = 0,
			y = 0,
			scale = 1.0,
			transform = 0,
		}),
		"--output DP-1 --on --mode 3440x1440@59.999Hz --pos 0,0 --scale 1.000000 --transform normal"
	)
	check(
		"umbriel: config_to_args disabled",
		umbriel._config_to_args({ name = "DP-2", enabled = false }),
		"--output DP-2 --off"
	)
	check(
		"umbriel: config_to_args transform 90",
		umbriel._config_to_args({
			name = "DP-1",
			enabled = true,
			width = 3440,
			height = 1440,
			refresh = 60,
			x = 0,
			y = 0,
			transform = 1,
		}),
		"--output DP-1 --on --mode 3440x1440@59.999Hz --pos 0,0 --transform 90"
	)
	check(
		"umbriel: config_to_args scale",
		umbriel._config_to_args({
			name = "DP-1",
			enabled = true,
			width = 3440,
			height = 1440,
			refresh = 60,
			x = 0,
			y = 0,
			scale = 1.0,
		}),
		"--output DP-1 --on --mode 3440x1440@59.999Hz --pos 0,0 --scale 1.000000 --transform normal"
	)

	-- Integration with core.screens.
	local uscr = screens.from_monitors(umbriel_mons)
	check("umbriel screens: count", #uscr, 3)
	check("umbriel screens: [1] uid", uscr[1].uid, "DP-1")
	check("umbriel screens: [1] available modes", #uscr[1].available, 5)
	check("umbriel screens: [2] hdr_enabled", uscr[2].hdr_enabled, true)
	check("umbriel screens: [3] active", uscr[3].active, false)
end

-- ---------------------------------------------------------------------------

if failures > 0 then
	print(string.format("\n%d/%d checks failed", failures, checks))
	os.exit(1)
end
print(string.format("ok — %d checks passed", checks))
