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
- [ ] `core/snap.lua` — 8-point reference, snap weights, `_snap_to_best_non_overlapping`
- [ ] Snap on release (collision → nearest non-overlapping position)
- [ ] Attraction mode (toggle: snap to nearest even without collision)
- [ ] Anchor detection + propagation on resize
- **Test**: drag a monitor next to another → snaps to edge; resize → neighbors follow

### Phase 4 — Full widget set
- [ ] `widgets/button.lua` — colored rect + label, click handler, hover highlight
- [ ] `widgets/label.lua` — text display
- [ ] `widgets/dropdown.lua` — expandable list (resolutions, frequencies, profiles, rotation)
- [ ] `widgets/slider.lua` — scale ratio
- [ ] `widgets/toggle.lua` — attraction mode on/off
- [ ] `widgets/textinput.lua` — profile naming (already prototyped)
- [ ] `widgets/modal.lua` — overlay + centered panel
- **Test**: side panel renders with all controls; dropdowns expand/collapse

### Phase 5 — Side panel + per-screen settings
- [ ] Panel layout (top bar: profiles, buttons; right panel: screen settings)
- [ ] Resolution dropdown (sorted, from available modes)
- [ ] Frequency dropdown (filtered by resolution)
- [ ] Rotation dropdown (0-7)
- [ ] Scale slider (1.0, 1.5, 2.0, ...)
- [ ] On/off toggle for screen
- [ ] Status bar (selected screen name / error messages)
- **Test**: click a monitor → panel updates; change resolution → rect resizes

### Phase 6 — Profiles
- [ ] `core/profiles.lua` — save/load Lua table files to `~/.config/hyprlayout/profiles.lua`
- [ ] Profile list dropdown
- [ ] New/Save/Load/Delete buttons
- [ ] TAB key cycles profiles
- **Test**: save layout → close → reopen → load profile → layout restored

### Phase 7 — Apply layout
- [ ] Generate `hyprctl` / `wlr-randr` / `xrandr` commands from current rects
- [ ] `trim_rects_flip_y` normalization
- [ ] Confirmation countdown (20s, progress bar, ENTER to confirm / ESC to abort)
- [ ] Reload button (re-read current state)
- **Test**: click Apply → countdown → layout applied on the system

### Phase 8 — Polish
- [ ] Smooth animation (lerp rect toward target_rect, 8-frame easing)
- [ ] Screenshot previews (background thread → love.thread)
- [ ] UI scale slider
- [ ] Screen scale (global ratio for canvas)
- [ ] Keyboard shortcuts (ENTER=apply, ESC=cancel, TAB=next profile)
- [ ] Error message display (red text, auto-dismiss)
- [ ] Window resize handling (re-center, re-layout panel)
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
