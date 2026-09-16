-- luacheck config for hyprlayout (LÖVE 11.5 / Lua 5.1)
std = "lua51"

-- Vendored third-party decoder; not linted.
exclude_files = { "src/dkjson.lua" }

-- LÖVE framework global. Writable: games assign lifecycle callbacks
-- (love.load, love.update, love.draw, ...) to it.
globals = { "love" }

-- OOP stubs keep unused arguments for interface conformance.
unused_args = false
