local screens = require("core.screens")
local Rect = require("core.rect")
local snap = require("core.snap")
local anchors = require("core.anchors")
local GuiScreen = require("gui_screen")
local Panel = require("panel")
local apply = require("core.apply")
local profile_apply = require("core.profile_apply")
local settings = require("core.settings")
local profiles = require("core.profiles")
local ffi = require("ffi")

local SCREEN_SCALE = Panel.DEFAULT_CANVAS_SCALE
local CONFIRM_DELAY = 20
local SCREENSHOT_INTERVAL = 10
local gui_screens = {}
local selected = nil
local dragging = false
local drag_moved = false
local drag_offset = { 0, 0 }
local status_msg = ""
local status_timer = 0
local panel = Panel.new()
local panel_w = Panel.PANEL_W
local confirm_start = 0
local original_cmd = nil
local anchor_data = {}
local shot_threads = {}
local shot_channel = nil
local shot_grim = false
local shot_converter = nil
local shot_timer = 0
local help_visible = false
local gui_initialized = false

local function build_gui_screens(info, scale)
	local list = {}
	for _, screen in ipairs(info) do
		local x, y = screen.position[1], screen.position[2]
		local w, h
		if screen.mode then
			w, h = Rect.screen_size(screen.mode.width, screen.mode.height, screen.scale, scale, screen.transform)
		else
			local max_w, max_h = 1920, 1080
			for _, m in ipairs(screen.available) do
				max_w = math.max(max_w, m.width)
				max_h = math.max(max_h, m.height)
			end
			w, h = Rect.screen_size(max_w, max_h, screen.scale, scale, screen.transform)
		end
		local rect = Rect.new(math.floor(x / scale), math.floor(y / scale), w, h)
		table.insert(list, GuiScreen.new(screen, rect))
	end
	return list
end

local function canvas_w()
	return love.graphics.getWidth() - panel_w - 20
end

local function center_layout(immediate)
	if #gui_screens == 0 then
		return
	end

	local min_x, min_y = math.huge, math.huge
	local max_x, max_y = -math.huge, -math.huge
	for _, gs in ipairs(gui_screens) do
		local r = gs.target_rect
		min_x = math.min(min_x, r.x)
		min_y = math.min(min_y, r.y)
		max_x = math.max(max_x, r.x + r.width)
		max_y = math.max(max_y, r.y + r.height)
	end

	local avg_x = (min_x + max_x) / 2
	local avg_y = (min_y + max_y) / 2
	local cw = canvas_w()
	local win_h = love.graphics.getHeight()
	local off_x = math.floor(cw / 2) - avg_x
	local off_y = math.floor(win_h / 2) - avg_y

	for _, gs in ipairs(gui_screens) do
		if immediate then
			gs:set_position(gs.target_rect.x + off_x, gs.target_rect.y + off_y)
		else
			gs.target_rect.x = gs.target_rect.x + off_x
			gs.target_rect.y = gs.target_rect.y + off_y
		end
	end
end

local function save_settings()
	settings.save({
		canvas_scale = SCREEN_SCALE,
		ui_scale = panel.ui_scale_factor,
		attract_enabled = panel.attract_enabled,
		shot_interval = SCREENSHOT_INTERVAL,
	})
end

local function change_canvas_scale(val)
	if type(val) ~= "number" then
		return
	end
	val = math.max(2, math.min(16, math.floor(val)))
	if val == SCREEN_SCALE then
		return
	end
	local old_scale = SCREEN_SCALE
	SCREEN_SCALE = val
	local ratio = old_scale / val
	for _, gs in ipairs(gui_screens) do
		local r = gs.target_rect
		r.x = r.x * ratio
		r.y = r.y * ratio
		r.width = r.width * ratio
		r.height = r.height * ratio
	end
	center_layout(true)
	anchor_data = anchors.detect(gui_screens)
	panel.screen_scale.value = val
	save_settings()
end

local function on_release_snap()
	snap.snap_active_screen(gui_screens)
	if panel.attract_enabled then
		snap.attract_screens(gui_screens)
	end
	center_layout()
	anchor_data = anchors.detect(gui_screens)
end

local function on_screen_changed()
	center_layout()
	anchor_data = anchors.detect(gui_screens)
end

local function on_screen_resized(gs, old_w, old_h)
	anchors.propagate(gui_screens, anchor_data, gs, old_w, old_h)
	center_layout()
	anchor_data = anchors.detect(gui_screens)
end

local function set_current_modes_as_ref()
	original_cmd = apply.make_commands(gui_screens, SCREEN_SCALE)
end

local function load_screens()
	gui_screens = {}
	local ok = screens.load()

	if not ok or #screens.displayInfo == 0 then
		print("No screens found! " .. tostring(screens.error))
		return
	end

	for _, gs in ipairs(build_gui_screens(screens.displayInfo, SCREEN_SCALE)) do
		gs:genColor()
		table.insert(gui_screens, gs)
	end

	center_layout(true)
	anchor_data = anchors.detect(gui_screens)
end

local function reload_all()
	load_screens()
	center_layout(true)
	panel:set_screen(nil)
	set_current_modes_as_ref()
end

local function revert_layout(msg)
	if original_cmd and #original_cmd > 0 then
		apply.run_commands(original_cmd)
	end
	confirm_start = 0
	reload_all()
	status_msg = msg
	status_timer = 3
end

local function action_apply()
	local cmds = apply.make_commands(gui_screens, SCREEN_SCALE)
	if #cmds > 0 then
		apply.run_commands(cmds)
		confirm_start = os.clock()
		status_msg = "Layout applied! Press ENTER to confirm or ESC to revert (" .. CONFIRM_DELAY .. "s)"
		status_timer = CONFIRM_DELAY
	end
end

local function layout_panel()
	local win_w = love.graphics.getWidth()
	local win_h = love.graphics.getHeight()
	panel:layout(win_w, win_h)
	panel.get_all_screens = function()
		return gui_screens
	end
	panel.on_screen_changed = on_screen_changed
	panel.on_screen_resized = on_screen_resized
	panel.on_apply_callback = function()
		action_apply()
	end
	panel.on_screen_scale_change_callback = change_canvas_scale
	panel.on_ui_scale_change_callback = function(val)
		if type(val) ~= "number" then
			return
		end
		panel.ui_scale_factor = val
		panel_w = math.floor(Panel.PANEL_W * val)
		for _, gs in ipairs(gui_screens) do
			gs.ui_scale = val
		end
		layout_panel()
		save_settings()
	end
	panel.on_visibility_changed = function()
		layout_panel()
	end
	panel.on_reload = function()
		reload_all()
	end
	panel.on_attract_toggle = function(val)
		panel.attract_enabled = val
		save_settings()
	end
	panel.on_shot_interval_change_callback = function(val)
		if type(val) ~= "number" then
			return
		end
		val = math.max(0.5, math.min(10, val))
		if val == SCREENSHOT_INTERVAL then
			return
		end
		SCREENSHOT_INTERVAL = val
		shot_timer = math.min(shot_timer, val)
		save_settings()
	end
	panel:update_profiles()
	if selected then
		panel:set_screen(selected)
	end
end

local shot_dir = nil

local function start_screenshot_thread()
	if not next(gui_screens) then
		return
	end
	if not (shot_grim and shot_converter) then
		return
	end
	-- One capture thread per active screen so all monitors are grabbed in parallel.
	shot_threads = {}
	for _, gs in ipairs(gui_screens) do
		local scr = gs.screen
		if scr.active then
			local tw, th
			if scr.mode then
				-- Decode at the size the preview is actually displayed at (the UI canvas scale)
				tw, th = Rect.screen_size(scr.mode.width, scr.mode.height, scr.scale, SCREEN_SCALE, scr.transform)
			end
			local info = {
				uid = scr.uid,
				active = scr.active,
				tw = tw,
				th = th,
				currentFormat = scr.current_format,
			}
			local t = love.thread.newThread("core/screenshot_thread.lua")
			t:start(info, shot_dir, shot_converter)
			table.insert(shot_threads, t)
		end
	end
end

local function poll_screenshots()
	for _, t in pairs(shot_threads) do
		local ok, err = pcall(function()
			return t:getError()
		end)
		if ok and err then
			print("[screenshot thread error] " .. err)
		end
	end
	if not shot_channel then
		return
	end
	while true do
		local msg = shot_channel:pop()
		if not msg then
			break
		end
		if msg.type == "screenshot" then
			-- The capture thread wrote raw RGBA (w*h*4 bytes) to the XDG cache dir.
			-- This LÖVE build can't newImage() an absolute path, so decode the bytes
			-- straight into an ImageData buffer via ffi.
			local w, h = msg.w, msg.h
			if w and h then
				local f = io.open(shot_dir .. "/" .. msg.file, "rb")
				if f then
					local bytes = f:read("*a")
					f:close()
					if bytes and #bytes == w * h * 4 then
						local id = love.image.newImageData(w, h)
						ffi.copy(id:getPointer(), bytes, w * h * 4)
						local img = love.graphics.newImage(id)
						for _, gs in ipairs(gui_screens) do
							if gs.screen.uid == msg.uid then
								gs:set_preview(img)
							end
						end
					end
				end
			end
		end
	end
end

function love.threaderror(msg)
	print("[THREAD ERROR] " .. tostring(msg))
end

local function get_canvas_scale()
	local saved = settings.load()
	if saved.canvas_scale then
		return math.max(2, math.min(16, saved.canvas_scale))
	end
	return Panel.DEFAULT_CANVAS_SCALE
end

local function headless_apply(data, canvas_scale)
	local ok = screens.load()
	if not ok or #screens.displayInfo == 0 then
		print("No screens found! " .. tostring(screens.error))
		return
	end

	local gs_list = build_gui_screens(screens.displayInfo, canvas_scale)

	for _, entry in ipairs(data.screens or {}) do
		for _, gs in ipairs(gs_list) do
			if gs.screen.uid == entry.uid then
				profile_apply.apply_screen_entry(gs, entry, canvas_scale, { match_modes = true })
			end
		end
	end

	local cmds = apply.make_commands(gs_list, canvas_scale)
	apply.run_commands(cmds)
end

local function is_path(p)
	if p:match("%.love$") then
		return true
	end
	local f = io.popen(string.format("test -d %q 2>/dev/null; echo $?", p))
	local out = f:read("*a") or ""
	f:close()
	return out:match("^0") ~= nil
end

local function first_user_arg()
	if not arg then
		return nil
	end
	-- When launched as `love <gamedir>`, arg[1] is the game directory;
	-- with a fused binary, user args start at arg[1].
	if arg[1] and is_path(arg[1]) then
		return arg[2]
	end
	return arg[1]
end

local function handle_cli()
	local a1 = first_user_arg()
	if not a1 then
		return false
	end
	local canvas_scale = get_canvas_scale()

	if a1 == "-l" then
		for _, name in ipairs(profiles.list_profiles()) do
			print(" - " .. name)
		end
		love.event.quit()
		return true
	end

	if a1 == "-m" then
		screens.load()
		local current = {}
		for _, s in ipairs(screens.displayInfo) do
			if s.active then
				current[s.uid] = true
			end
		end
		local matched_name, matched_data
		for _, name in ipairs(profiles.list_profiles()) do
			local data = profiles.load_profile(name)
			if data then
				local prof = {}
				for _, s in ipairs(data.screens or {}) do
					prof[s.uid] = true
				end
				local equal = true
				for uid in pairs(current) do
					if not prof[uid] then
						equal = false
						break
					end
				end
				if equal then
					for uid in pairs(prof) do
						if not current[uid] then
							equal = false
							break
						end
					end
				end
				if equal then
					matched_name, matched_data = name, data
					break
				end
			end
		end
		if matched_name then
			print("Matched profile " .. matched_name .. ". Applying it...")
			headless_apply(matched_data, canvas_scale)
		else
			print("No matching profile for current display set")
		end
		love.event.quit()
		return true
	end

	if a1:sub(1, 1) == "-" then
		print([[With no options, launches the GUI
Options:
         -l : list profiles
         -m : find a profile that matches the currently plugged display set, and apply it.
              No-op if not found; will apply first in alphabetical order if multiple found.
 <profile name> : loads a profile]])
		love.event.quit()
		return true
	end

	local data = profiles.load_profile(a1)
	if not data then
		print("No such profile: " .. a1)
	else
		headless_apply(data, canvas_scale)
	end
	love.event.quit()
	return true
end

function love.load()
	if handle_cli() then
		return
	end

	gui_initialized = true
	math.randomseed(os.time())
	shot_channel = love.thread.getChannel("screenshots")
	-- Captures are cached in the XDG cache dir, never the game dir / repo. This
	-- LÖVE build can't load images from an absolute path, so the capture thread
	-- writes raw RGBA here and the main thread decodes it into an Image via ffi.
	local cache_base = os.getenv("XDG_CACHE_HOME")
	if not cache_base or cache_base == "" then
		cache_base = (os.getenv("HOME") or "/tmp") .. "/.cache"
	end
	shot_dir = cache_base .. "/hyprlayout/shots"

	-- Detect capture tools once and pass the result to each capture thread
	-- (only serializable data crosses the LÖVE thread boundary).
	shot_grim = os.execute("which grim > /dev/null 2>&1")
	if os.execute("which convert > /dev/null 2>&1") then
		shot_converter = "convert"
	elseif os.execute("which magick > /dev/null 2>&1") then
		shot_converter = "magick"
	elseif os.execute("which ffmpeg > /dev/null 2>&1") then
		shot_converter = "ffmpeg"
	end
	os.execute('mkdir -p "' .. shot_dir .. '"')

	local saved = settings.load()
	if saved.canvas_scale then
		SCREEN_SCALE = math.max(2, math.min(16, saved.canvas_scale))
	end
	if saved.ui_scale then
		panel.ui_scale_factor = math.max(0.5, math.min(1.5, saved.ui_scale))
		panel_w = math.floor(Panel.PANEL_W * panel.ui_scale_factor)
	end
	if saved.attract_enabled ~= nil then
		panel.attract_enabled = saved.attract_enabled
	end
	if saved.shot_interval then
		SCREENSHOT_INTERVAL = math.max(0.5, math.min(10, saved.shot_interval))
		panel.shot_interval_value = SCREENSHOT_INTERVAL
	end

	load_screens()
	layout_panel()
	panel.screen_scale.value = SCREEN_SCALE
	for _, gs in ipairs(gui_screens) do
		gs.ui_scale = panel.ui_scale_factor or 1.0
	end
	set_current_modes_as_ref()
	start_screenshot_thread()
	shot_timer = SCREENSHOT_INTERVAL
end

function love.quit()
	if gui_initialized then
		save_settings()
	end
	for _, t in pairs(shot_threads) do
		t:wait()
	end
end

function love.resize(w, h)
	layout_panel()
	center_layout(true)
end

function love.update(dt)
	for _, gs in ipairs(gui_screens) do
		gs:update(dt)
	end
	poll_screenshots()
	shot_timer = shot_timer - dt
	if shot_timer <= 0 then
		shot_timer = SCREENSHOT_INTERVAL
		start_screenshot_thread()
	end
	if status_timer > 0 then
		status_timer = status_timer - dt
		if status_timer <= 0 then
			status_msg = ""
		end
	end
	if confirm_start > 0 then
		local elapsed = os.clock() - confirm_start
		if elapsed * 10 >= CONFIRM_DELAY then
			revert_layout("Timed out - reverted")
		end
	end
end

-- Draw a keycap (rounded box around a key label). Returns the cap width.
local function draw_keycap(x, y, label, font)
	local pad = 7
	local tw = font:getWidth(label)
	local th = font:getHeight()
	local w = tw + pad * 2
	local h = th + 8
	love.graphics.setColor(0.24, 0.24, 0.31)
	love.graphics.rectangle("fill", x, y, w, h, 3, 3)
	love.graphics.setColor(0.45, 0.45, 0.55)
	love.graphics.setLineWidth(1)
	love.graphics.rectangle("line", x, y, w, h, 3, 3)
	love.graphics.setColor(0.92, 0.92, 0.92)
	love.graphics.print(label, x + pad, y + 4)
	return w
end

local function draw_help()
	local win_w = love.graphics.getWidth()
	local win_h = love.graphics.getHeight()
	local font = love.graphics.getFont()

	local key_rows = {
		{ keys = { "ENTER" }, action = "Apply layout" },
		{ keys = { "R" }, action = "Reload screens" },
		{ keys = { "TAB" }, action = "Cycle profile" },
		{ keys = { "F1", "?" }, action = "Toggle this help" },
		{ keys = { "ESC" }, action = "Close help / Quit" },
	}
	local mouse_rows = {
		{ keys = { "drag" }, action = "Move a screen" },
		{ keys = { "wheel" }, action = "Zoom canvas / scroll panel" },
	}

	local row_h, pad = 28, 24
	local header_h, section_gap, footer_h = 46, 42, 34
	local mw = 340
	local mh = header_h + #key_rows * row_h + section_gap + #mouse_rows * row_h + footer_h
	local mx = (win_w - mw) / 2
	local my = (win_h - mh) / 2

	-- Dim + box
	love.graphics.setColor(0, 0, 0, 0.55)
	love.graphics.rectangle("fill", 0, 0, win_w, win_h)
	love.graphics.setColor(0.13, 0.13, 0.18)
	love.graphics.rectangle("fill", mx, my, mw, mh, 10, 10)
	love.graphics.setColor(0.4, 0.4, 0.5)
	love.graphics.setLineWidth(1)
	love.graphics.rectangle("line", mx, my, mw, mh, 10, 10)

	love.graphics.setColor(0.92, 0.92, 0.92)
	love.graphics.print("Shortcuts", mx + pad, my + 14)

	local y = my + header_h
	local function draw_row(row)
		local kx = mx + pad
		for _, k in ipairs(row.keys) do
			kx = kx + draw_keycap(kx, y, k, font) + 6
		end
		love.graphics.setColor(0.7, 0.7, 0.75)
		love.graphics.print(row.action, mx + pad + 116, y + 4)
		y = y + row_h
	end
	for _, row in ipairs(key_rows) do
		draw_row(row)
	end

	love.graphics.setColor(0.3, 0.3, 0.4)
	love.graphics.rectangle("fill", mx + pad, y, mw - pad * 2, 1)
	y = y + 14
	love.graphics.setColor(0.55, 0.55, 0.6)
	love.graphics.print("Mouse", mx + pad, y + 4)
	y = y + row_h
	for _, row in ipairs(mouse_rows) do
		draw_row(row)
	end

	love.graphics.setColor(0.5, 0.5, 0.55)
	love.graphics.print("F1 / ? / ESC / click to close", mx + pad, my + mh - 22)
end

-- Show a "drag to move" hint on the screen currently under the mouse.
local function draw_drag_hint()
	if dragging then
		return
	end
	local mx, my = love.mouse.getX(), love.mouse.getY()
	for i = #gui_screens, 1, -1 do
		local gs = gui_screens[i]
		if gs.rect:contains(mx, my) then
			local r = gs.rect
			local label = "drag to move"
			local font = love.graphics.getFont()
			local tw = font:getWidth(label)
			local th = font:getHeight()
			local pw, ph = tw + 20, th + 10
			local px = r.x + r.width / 2 - pw / 2
			local py = r.y + 8
			if r.height > ph + 16 then
				love.graphics.setColor(0, 0, 0, 0.55)
				love.graphics.rectangle("fill", px, py, pw, ph, 5, 5)
				love.graphics.setColor(0.85, 0.85, 0.88)
				love.graphics.print(label, px + 10, py + 5)
			end
			break
		end
	end
end

-- Hit/draw rect for the corner "?" help button (top-right of the canvas).
local function help_btn_rect()
	local font = love.graphics.getFont()
	local w = font:getWidth("?") + 14
	local h = font:getHeight() + 8
	return canvas_w() - w - 10, 10, w, h
end

function love.draw()
	love.graphics.clear(0.2, 0.2, 0.2)

	if #gui_screens == 0 then
		love.graphics.setColor(1, 0.4, 0.4)
		love.graphics.print("hyprlayout - no screens detected", 20, 20)
		if screens.error then
			love.graphics.setColor(0.8, 0.8, 0.8)
			love.graphics.print(screens.error:sub(1, 500), 20, 50)
		end
		panel:draw()
		return
	end

	for _, gs in ipairs(gui_screens) do
		gs:draw()
	end

	panel:draw()

	if confirm_start > 0 then
		local elapsed = os.clock() - confirm_start
		local remaining = CONFIRM_DELAY - (elapsed * 10)
		local ratio = remaining / CONFIRM_DELAY
		local win_w = love.graphics.getWidth()
		local win_h = love.graphics.getHeight()

		-- Dim overlay
		love.graphics.setColor(0, 0, 0, 0.6)
		love.graphics.rectangle("fill", 0, 0, win_w, win_h)

		-- Modal box
		local mw, mh = 360, 160
		local mx, my = (win_w - mw) / 2, (win_h - mh) / 2
		love.graphics.setColor(0.15, 0.15, 0.2, 1)
		love.graphics.rectangle("fill", mx, my, mw, mh, 8, 8)
		love.graphics.setColor(0.4, 0.4, 0.5)
		love.graphics.setLineWidth(1)
		love.graphics.rectangle("line", mx, my, mw, mh, 8, 8)

		-- Title
		love.graphics.setColor(1, 1, 1)
		love.graphics.printf("Apply layout?", mx, my + 20, mw, "center")

		-- Progress bar
		local bar_w, bar_h = mw - 60, 12
		local bar_x, bar_y = mx + 30, my + 60
		love.graphics.setColor(0.3, 0.3, 0.35)
		love.graphics.rectangle("fill", bar_x, bar_y, bar_w, bar_h, 4, 4)
		local bar_color_r = 50 + math.floor(200 * (1.0 - ratio)) / 255
		local bar_color_g = math.floor(200 * ratio) / 255
		love.graphics.setColor(bar_color_r, bar_color_g, 0.4)
		love.graphics.rectangle("fill", bar_x, bar_y, math.max(bar_h, math.floor(bar_w * ratio)), bar_h, 4, 4)

		-- Instructions
		love.graphics.setColor(0.7, 0.7, 0.7)
		love.graphics.printf("ENTER to confirm  |  ESC to abort", mx, my + 100, mw, "center")
		love.graphics.printf(string.format("%.1fs", remaining), mx, my + 125, mw, "center")
	else
		local font = love.graphics.getFont()

		-- Compact "?" button (top-right of the canvas) to open the help overlay
		local bx, by = help_btn_rect()
		draw_keycap(bx, by, "?", font)

		draw_drag_hint()

		if status_msg ~= "" then
			local sw = font:getWidth(status_msg)
			local sh = font:getHeight()
			love.graphics.setColor(0, 0, 0, 0.5)
			love.graphics.rectangle("fill", 8, 8, sw + 20, sh + 12, 6, 6)
			love.graphics.setColor(1, 0.9, 0.5)
			love.graphics.print(status_msg, 18, 14)
		end

		if help_visible then
			draw_help()
		end
	end
end

function love.mousemoved(x, y)
	if dragging and selected then
		local nx = x - drag_offset[1]
		local ny = y - drag_offset[2]
		if nx ~= selected.rect.x or ny ~= selected.rect.y then
			drag_moved = true
		end
		selected:set_position(nx, ny)
	else
		panel:on_move(x, y)
	end
end

function love.wheelmoved(_, dy)
	-- Panel scrolls its own content when hovered; otherwise the wheel zooms the canvas
	if panel:handle_scroll(dy) then
		return
	end
	local x = love.mouse.getX()
	if x < canvas_w() then
		change_canvas_scale(SCREEN_SCALE - dy)
	end
end

local function set_highlight(gs)
	for _, s in ipairs(gui_screens) do
		s.highlighted = (s == gs)
	end
end

function love.mousepressed(x, y, button)
	if button ~= 1 then
		return
	end

	-- Help overlay: any click dismisses it; the corner "?" button opens it
	if help_visible then
		help_visible = false
		return
	end
	local bx, by, bw, bh = help_btn_rect()
	if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
		help_visible = true
		return
	end

	-- Panel gets priority
	if panel:on_press(x, y) then
		return
	end

	for i = #gui_screens, 1, -1 do
		local gs = gui_screens[i]
		if gs.rect:contains(x, y) then
			selected = gs
			set_highlight(gs)
			dragging = true
			drag_moved = false
			drag_offset[1] = x - gs.rect.x
			drag_offset[2] = y - gs.rect.y
			table.remove(gui_screens, i)
			table.insert(gui_screens, gs)
			panel:set_screen(gs)
			return
		end
	end
	selected = nil
	set_highlight(nil)
	panel:set_screen(nil)
end

function love.mousereleased(x, y, button)
	if button ~= 1 then
		return
	end
	panel:on_release(x, y)
	if dragging and selected and drag_moved then
		on_release_snap()
	end
	dragging = false
end

function love.textinput(txt)
	if panel:text_input(txt) then
		return
	end
end

function love.keypressed(key)
	if panel:modal_keypressed(key) then
		return
	end
	-- F1 / ? toggle the (non-blocking) help overlay
	local is_help_key = key == "f1"
		or (key == "slash" and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")))
	if is_help_key then
		help_visible = not help_visible
		return
	end
	if key == "return" or key == "kpenter" then
		if confirm_start > 0 then
			confirm_start = 0
			set_current_modes_as_ref()
			status_msg = ""
			status_timer = 0
		else
			action_apply()
		end
	elseif key == "escape" then
		if help_visible then
			help_visible = false
		elseif confirm_start > 0 then
			revert_layout("Reverted")
		else
			love.event.quit()
		end
	elseif key == "tab" then
		if panel:cycle_profile() then
			panel:load_profile()
		end
	elseif key == "r" then
		reload_all()
	end
end
