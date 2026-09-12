# hyprlayout — Conversion Plan

Port of `wlr-layout-ui` (Python/pyglet) to Lua/LÖVE.

## Architecture

```
hyprlayout/
├── main.lua              # love callbacks, event dispatch, main loop
├── conf.lua              # window config (title, size)
├── dkjson.lua            # vendored pure-Lua JSON decoder
├── core/
│   ├── rect.lua          # Rect type (x, y, w, h, collide, contains, center, corners)
│   ├── screens.lua       # Screen/Mode types + hyprctl/wlr-randr/xrandr loading
│   ├── snap.lua          # 8-point reference, snap weights, anchor detection/propagation
│   └── profiles.lua      # Lua-table profile save/load (replaces TOML)
├── widgets/
│   ├── widget.lua        # base widget: rect, hit_test, events, draw
│   ├── button.lua
│   ├── label.lua
│   ├── dropdown.lua
│   ├── slider.lua
│   ├── toggle.lua
│   ├── textinput.lua
│   └── modal.lua
├── gui_screen.lua        # GuiScreen: draggable monitor rect + animation + color
└── app.lua               # main UI state, panel layout, actions (save/load/apply)
```

## Phases

### Phase 0 — Scaffold (minimal testable app)
- [x] `conf.lua` — window title "hyprlayout", 1024x768, resizable
- [x] `main.lua` — love.load/update/draw skeleton
- [x] `dkjson.lua` — vendored JSON decoder
- [x] `core/rect.lua` — Rect type with collide, contains, center, corner accessors
- **Test**: `love .` opens a dark window with "hyprlayout" title

### Phase 1 — Screen info loading
- [x] `core/screens.lua` — parse `hyprctl -j monitors all` (Hyprland-only)
- [x] Screen/Mode types
- [x] Error handling (shows message if hyprctl fails)
- **Test**: console prints monitor names, positions, modes on load

### Phase 2 — Widget base + GuiScreen canvas
- [x] `widgets/widget.lua` — base class (rect, hit_test, on_press/drag/release, draw)
- [x] `gui_screen.lua` — GuiScreen widget (colored rect, drag, highlight, animation)
- [x] Drag & drop in main.lua (mouse events)
- [x] Center layout in window
- **Test**: monitors appear as colored rects, draggable, centered in window

### Phase 3 — Snapping & attraction
- [x] `core/snap.lua` — 8-point reference, snap weights, `_snap_to_best_non_overlapping`
- [x] Snap on release (collision → nearest non-overlapping position)
- [x] Attraction (always active: snap to nearest even without collision, within 300px)
- [ ] Anchor detection + propagation on resize
- **Test**: drag a monitor next to another → snaps to edge; resize → neighbors follow

### Phase 4 — Full widget set
- [x] `widgets/button.lua` — colored rect + label, click handler, hover highlight
- [x] `widgets/label.lua` — text display
- [x] `widgets/dropdown.lua` — expandable list (resolutions, frequencies, profiles, rotation)
- [x] `widgets/toggle.lua` — power on/off
- [ ] `widgets/slider.lua` — scale ratio (using dropdown instead)
- [ ] `widgets/textinput.lua` — profile naming
- [ ] `widgets/modal.lua` — overlay + centered panel
- **Test**: side panel renders with all controls; dropdowns expand/collapse

### Phase 5 — Side panel + per-screen settings
- [x] Panel layout (right panel: screen settings, profiles, apply)
- [x] Resolution dropdown (sorted, from available modes)
- [x] Frequency dropdown (filtered by resolution)
- [x] Rotation dropdown (0-5)
- [x] Scale dropdown (0.5-2.0)
- [x] On/off toggle for screen
- [x] Status bar (selected screen name / error messages)
- **Test**: click a monitor → panel updates; change resolution → rect resizes

### Phase 6 — Profiles
- [x] `core/profiles.lua` — save/load Lua table files to `~/.config/hyprlayout/profiles/*.lua`
- [x] Profile list dropdown
- [x] Save/Load/New buttons
- [ ] Delete button
- [ ] TAB key cycles profiles
- **Test**: save layout → close → reopen → load profile → layout restored

### Phase 7 — Apply layout
- [x] Generate `hyprctl eval` commands from current rects
- [x] `trim_rects_flip_y` normalization
- [ ] Confirmation countdown (20s, progress bar, ENTER to confirm / ESC to abort)
- [x] Reload button (R key, re-read current state)
- **Test**: click Apply → layout applied on the system

### Phase 8 — Polish
- [x] Smooth animation (lerp rect toward target_rect, 8-frame easing)
- [ ] Screenshot previews (background thread → love.thread)
- [ ] UI scale slider
- [x] Screen scale (global ratio for canvas, SCREEN_SCALE=8)
- [ ] Keyboard shortcuts (ENTER=apply, ESC=cancel, TAB=next profile)
- [x] Error message display (status label in panel)
- [x] Window resize handling (re-center, re-layout panel)
- [ ] Hyprland window rules (WM class / title)

## Key Design Decisions

1. **Config format**: Lua tables saved as `.lua` files (no TOML/JSON dependency for profiles)
2. **JSON**: `dkjson` (pure Lua, single file) for parsing `hyprctl -j` output
3. **No GUI library**: build minimal retained-mode widgets directly on `love.graphics`
4. **External commands**: `io.popen` (sync, fine for fast `hyprctl` calls)
5. **Canvas**: free-drag with 8-point snap (ported from Python)
6. **Animation**: lerp toward target_rect each frame (same as Python version)

## Reference: Python source mapping

| Python file | Lua equivalent | Notes |
|---|---|---|
| `types.py` | `core/screens.lua` | Screen, Mode dataclasses |
| `screens.py` | `core/screens.lua` | hyprctl/wlr-randr/xrandr parsing |
| `utils.py` | `core/rect.lua` + `core/snap.lua` | Rect, commands, helpers |
| `displaywidget.py` | `gui_screen.lua` | GuiScreen widget |
| `gui.py` | `main.lua` + `app.lua` | Main UI, snapping, actions |
| `profiles.py` | `core/profiles.lua` | Profile save/load |
| `widgets.py` | `widgets/` | Button, Dropdown, Slider, etc. |
| `app.py` | `main.lua` (load) | Entry point, window sizing |
