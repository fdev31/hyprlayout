# hyprlayout build/run helpers (Linux only).
#
#   just            run the app from source
#   just build      build both dist/ artifacts (self-contained exe + .love file)
#   just love       build only the dist/hyprlayout.love file (fast, no LÖVE build)
#   just run        build, then run the self-contained executable
#   just clean      remove dist/
#   just distclean  remove dist/ and the cached LÖVE source/build tree
#
# `just build` produces two artifacts in dist/:
#   - hyprlayout.love   a standard LÖVE game archive; run with
#                       `love hyprlayout.love` (for machines with LÖVE installed)
#   - hyprlayout        a single portable executable. It builds a statically-linked
#                       LÖVE 11.5 runtime from source (cached in .love-build/) and
#                       fuses the .love archive into the love binary using LÖVE's
#                       "fused game" format (the zip is appended to the end of the
#                       executable, which LÖVE detects and runs). It runs WITHOUT
#                       LÖVE installed; it still links common desktop shared
#                       libraries (SDL2, freetype, openal, ogg/vorbis/theora/mpg123
#                       codecs), present on any desktop Linux.
# The first build clones LÖVE and compiles it (a few minutes); later builds are
# fast because the source and build tree are cached in .love-build/.

# Run the app from the source tree.
default:
    love src

# Build both dist/ artifacts: the .love archive and the self-contained exe.
build:
    [ -d .love-build/src ] || ( rm -rf .love-build && mkdir -p .love-build && git clone --depth 1 --branch 11.5 https://github.com/love2d/love .love-build/src )
    sed -i 's/ SHARED / STATIC /' .love-build/src/CMakeLists.txt
    cmake -S .love-build/src -B .love-build/build -DCMAKE_BUILD_TYPE=Release -DLOVE_MPG123=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build .love-build/build -j"$(nproc)"
    rm -rf dist && mkdir -p dist
    cd src && zip -r -q ../dist/hyprlayout.love conf.lua main.lua panel.lua gui_screen.lua dkjson.lua core widgets
    cat .love-build/build/love dist/hyprlayout.love > dist/hyprlayout
    chmod +x dist/hyprlayout
    @echo "Built dist/hyprlayout ($(du -h dist/hyprlayout | cut -f1)) and dist/hyprlayout.love ($(du -h dist/hyprlayout.love | cut -f1))"

# Build only the .love archive (fast; no LÖVE build required).
love:
    mkdir -p dist
    cd src && zip -r -q ../dist/hyprlayout.love conf.lua main.lua panel.lua gui_screen.lua dkjson.lua core widgets
    @echo "Built dist/hyprlayout.love ($(du -h dist/hyprlayout.love | cut -f1))"

# Build, then run the self-contained executable.
run:
    @just build
    ./dist/hyprlayout

# Remove the built artifacts.
clean:
    rm -rf dist

# Remove the built artifacts and the cached LÖVE source/build tree.
distclean:
    rm -rf dist .love-build
