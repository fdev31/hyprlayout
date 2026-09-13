# PORTING_NOTES

Summary of the port from `wlr-layout-ui` (Python/pyglet) to `hyprlayout` (Lua/LÖVE 11.5).

## Architecture

| Component | File(s) | Notes |
|-----------|---------|-------|
| Entry point | `main.lua` | LÖVE callbacks, global state, screen loading |
| Side panel | `panel.lua` | General + Screen Settings sections |
| Screen widget | `gui_screen.lua` | Draggable colored rect, `target_rect` + `update(dt)` |
| Apply logic | `core/apply.lua` | Generates `hyprctl eval` commands |
| Screen loading | `core/screens.lua` | Parses `hyprctl -j monitors all` |
| Snap logic | `core/snap.lua` | `snap_active_screen` (overlap), `attract_screens` (proximity) |
| Anchors | `core/anchors.lua` | Reference-point detection + BFS propagation |
| Profiles | `core/profiles.lua` | Lua table save/load/list/delete |
| JSON | `dkjson.lua` | Minimal pure-Lua JSON decoder |
| Widgets | `widgets/*.lua` | Button, Toggle, Dropdown, Slider, Modal, Anim |

## Key Design Decisions

- **No GUI library** — all widgets built from scratch on `love.graphics`
- **Hyprland-only** — uses `hyprctl -j` for screen info, `hyprctl eval` for applying
- **Profiles as Lua tables** — loaded with `loadfile()`, saved with custom serializer
- **Canvas scale** (`SCREEN_SCALE`) — user-adjustable (2-16, default 4), converts physical pixels to canvas units
- **Retained-mode widgets** — `Widget:extend("Name")` pattern, `setmetatable` for inheritance

## Ported Features (from wlr-layout-ui)

- [x] Screen detection via hyprctl
- [x] Drag & drop screen repositioning
- [x] Snap on overlap
- [x] Attract (proximity snap, toggleable)
- [x] Anchor-based relative positioning (BFS propagation on resize)
- [x] Resolution / Refresh / Scale / Rotation per screen
- [x] Apply with 20s countdown + revert
- [x] Profile save/load/delete (Lua table files)
- [x] TAB to cycle profiles
- [x] Center layout
- [x] Reload screens
- [x] Canvas scale slider
- [x] UI scale slider
- [x] Animations (toggle, dropdown, slider, button)
- [x] Text input modal (for profile naming)

## Bugs Fixed During Port

| Commit | Bug |
|--------|-----|
| `9bfdb29` | Dropdown z-order — dropdown rendered behind other widgets |
| `4a14767` | `drag_moved` flag — snap fired on simple click without drag |
| `7007ca8` | Screen duplication — screens appeared twice on reload |
| `99fe4cf` | Type guards — nil crashes on missing mode data |
| `ea8d41f` | Mode fallback + default SCREEN_SCALE 8→4 |
| `0b5ec98` | Slider callback `:` → `.` syntax (instance var shadowing) |
| `643cfd2` | UI scale slider value not reset on reload |
| `656ed78` | UI scale widget not scaling its own dimensions |
| `f5e7c0c` | Panel split into General + Screen Settings |
| `ae2c7bb` | Animation system for all widgets |
| `897f018` | Canvas scale change didn't rescale existing rects |
| `4d13e64` | Added Reload button + Attraction toggle |
| `81ed2cd` | Reload button nil callback (method vs callback conflict) |
| `71b7698` | Hardcoded SCREEN_SCALE=8 in apply.lua/panel.lua → wrong positions |

## Lua 5.1 Gotchas Encountered

- No `//` operator (use `math.floor(a/b)`)
- No `continue` statement (use `if not cond then ... end` or goto)
- `a and b()` as single-expression function body causes parse errors
- Operator precedence: `a or b and c` = `((a or b) and c)` — use explicit parens
- `:` vs `.` call syntax: instance vars can shadow class methods

## SCREEN_SCALE Conversion

```
canvas_units = physical_pixels / SCREEN_SCALE / screen.scale
physical_pixels = canvas_units * SCREEN_SCALE * screen.scale
```

- `target_rect` stores coordinates in canvas units
- `apply.make_commands(gui_screens, canvas_scale)` converts back to physical pixels
- When user changes scale, all `target_rect` values are rescaled by `old/new` ratio

## Command Format

```
hyprctl eval "hl.monitor({output='HDMI-A-1', mode='1920x1080@60.00', position='0x0', scale=1.000000, transform=0}) ; hl.monitor({output='DP-1', mode='3440x1440@60.00', position='1920x0', scale=1.000000, transform=0})"
```

## File Structure

```
hyprlayout/
├── main.lua          # Entry point, LÖVE callbacks
├── panel.lua         # Side panel (General + Screen Settings)
├── gui_screen.lua    # Draggable screen widget
├── conf.lua          # Window config (1024x768, resizable)
├── dkjson.lua        # Minimal JSON decoder
├── core/
│   ├── apply.lua     # Command generation + execution
│   ├── screens.lua   # hyprctl screen loading
│   ├── snap.lua      # Snap + attract logic
│   ├── anchors.lua   # Anchor detection + propagation
│   └── profiles.lua  # Profile CRUD
├── widgets/
│   ├── widget.lua    # Base widget class
│   ├── button.lua    # Animated button
│   ├── toggle.lua    # Animated toggle switch
│   ├── dropdown.lua  # Animated dropdown
│   ├── slider.lua    # Animated slider
│   ├── modal.lua     # Text input modal
│   └── anim.lua      # AnimFloat + AnimColor helpers
├── ACTION_PLAN.md    # Original porting plan
└── PORTING_NOTES.md  # This file
```
