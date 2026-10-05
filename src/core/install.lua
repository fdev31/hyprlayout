-- Hyprland integration installer.
--
-- `hyprlayout install` symlinks the shared entry point (hyprlayout.lua) into
-- the Hyprland config dir and patches hyprland.lua to require() it, so the
-- auto-apply event handlers (install()) run on monitor add/remove.
--
-- The entry point is self-locating, so once it is reachable from the config
-- dir (via the symlink) the core/* modules resolve automatically.

local M = {}

local function config_dir()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return xdg
	end
	return (os.getenv("HOME") or "/tmp") .. "/.config"
end

local function hypr_dir()
	return config_dir() .. "/hypr"
end

-- Create (or refresh) the symlink <hypr_dir>/hyprlayout.lua -> entrypoint.
local function link_entrypoint(entrypoint)
	local target = hypr_dir() .. "/hyprlayout.lua"
	os.remove(target)
	-- os.execute returns 0 (number) or true on success depending on the Lua build.
	local code = os.execute(string.format("ln -s %q %q", entrypoint, target))
	if code ~= 0 and code ~= true then
		return false, "failed to create symlink: " .. target
	end
	return true
end

local MARKER = 'require("hyprlayout").install()'
local SNIPPET = table.concat({
	"-- Auto-apply the matching monitor layout when monitors are added/removed.",
	MARKER,
	"",
}, "\n")

-- Append the require + install() snippet to hyprland.lua if not present.
local function patch_config()
	local path = hypr_dir() .. "/hyprland.lua"
	local f = io.open(path, "r")
	if not f then
		return false, "cannot read " .. path
	end
	local content = f:read("*a")
	f:close()

	if content:find(MARKER, 1, true) then
		return true, "already installed"
	end

	local out = io.open(path, "w")
	if not out then
		return false, "cannot write " .. path
	end
	out:write(content)
	if content:sub(-1) ~= "\n" then
		out:write("\n")
	end
	out:write(SNIPPET)
	out:close()
	return true
end

-- Run the full install. entrypoint is the absolute path to hyprlayout.lua.
-- Returns (ok, message).
function M.run(entrypoint)
	local dir = hypr_dir()
	local check = io.popen(string.format("test -d %q; echo $?", dir))
	local r = check:read("*a") or ""
	check:close()
	if r:match("^0") == nil then
		return false, "Hyprland config dir not found: " .. dir
	end

	local ok, err = link_entrypoint(entrypoint)
	if not ok then
		return false, err
	end

	local ok2, status = patch_config()
	if not ok2 then
		return false, status
	end

	if status == "already installed" then
		print("hyprlayout is already installed in " .. dir)
		return true
	end

	print("Installed hyprlayout into " .. dir)
	print("  symlink: " .. dir .. "/hyprlayout.lua -> " .. entrypoint)
	print("  patched: " .. dir .. "/hyprland.lua")
	return true
end

return M
