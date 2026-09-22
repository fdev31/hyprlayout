# hyprlayout

Successor of [wlr-layout-ui](https://github.com/fdev31/wlr-layout-ui) aka wlrlui.

A LÖVE 11.5 GUI for arranging and configuring Hyprland monitor layouts. Drag
screens into position, tune resolution / scale / rotation / HDR per output,
then apply the layout with `hyprctl`. Layouts can be saved and recalled as
named profiles.

## Requirements

**Required**

- Linux (developed and tested on Arch)
- [Hyprland](https://hyprland.org/) running — the app reads and applies
  monitor configuration through `hyprctl`
- [LÖVE 11.5](https://love2d.org/) — to run from source or the `.love`
  archive. The self-contained executable (below) needs no LÖVE install.

**Optional — live screen preview**

The per-monitor preview thumbnails are captured with a Wayland screencapture
tool and downscaled with an image scaler. If either is missing the app still
runs normally; the preview is simply omitted.

- `grim` — captures each monitor
- one of the following, to downscale each capture:
  - ImageMagick 6 → `convert`
  - ImageMagick 7 → `magick`
  - `ffmpeg`

On Arch: `sudo pacman -S grim imagemagick` (or `ffmpeg` instead of
`imagemagick`).

## Running from source

```sh
just            # == love src
```

## Command line

```
hyprlayout [option] [profile]

  -l            list saved profiles
  -m            apply the first profile (alphabetical) whose monitor set
                matches the currently active displays
  <profile>     load (apply) the named profile
  (no args)     open the GUI
```

With any option the app does its job and exits — no GUI is opened.

## GUI controls

| Input    | Action                        |
| -------- | ----------------------------- |
| drag     | move a screen                 |
| wheel    | zoom canvas / scroll the panel|
| Enter    | apply the layout              |
| R        | reload screens                |
| Tab      | cycle to the next profile     |
| F1 / ?   | toggle this help              |
| Esc      | close help / quit             |

## Building

`just build` produces two artifacts in `dist/`:

- `dist/hyprlayout` — a single self-contained executable. The first build
  clones and statically compiles LÖVE 11.5 (cached in `.love-build/`), then
  fuses the game archive into the `love` binary. It runs without LÖVE
  installed, though it links common desktop libraries (SDL2, freetype,
  openal, ogg/vorbis/theora/mpg123).
- `dist/hyprlayout.love` — a standard LÖVE game archive; run with
  `love dist/hyprlayout.love`.

Other recipes:

```
just love       # build only the .love archive (fast)
just run        # build, then run the self-contained exe
just clean      # remove dist/
just distclean  # remove dist/ and the cached LÖVE build tree
```

## Profiles & settings

Stored under `~/.config/hyprlayout/`:

- `settings.lua` — last-used UI settings (canvas scale, window size, …)
- `profiles/` — one file per saved layout

## Development

- `just lint` — run [luacheck](https://github.com/luarocks/luacheck) over
  `src/` (config in `.luacheckrc`).
- Lua sources are kept formatted with [stylua](https://github.com/JohnnyMorganz/StyLua)
  via a [pre-commit](https://pre-commit.com/) hook (`.pre-commit-config.yaml`).
  After cloning, install the hook once:

  ```sh
  pre-commit install
  ```

  Requires the `pre-commit` framework and `stylua` on `PATH`. The hook
  auto-formats staged `*.lua` files on commit; the vendored `src/dkjson.lua`
  is excluded.

## Project layout

```
src/
  main.lua        entry point, canvas, input, help overlay, CLI handling
  panel.lua       the right-hand control panel
  gui_screen.lua  a draggable screen widget
  conf.lua        LÖVE configuration
  core/           screens, apply (hyprctl), profiles, settings, rect, snap, anchors
  widgets/        reusable UI widgets (button, slider, dropdown, toggle, …)
```
