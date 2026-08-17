# projectM(ac)

[![Build](https://github.com/fa7ad/projectMac/actions/workflows/build.yml/badge.svg)](https://github.com/fa7ad/projectMac/actions/workflows/build.yml)

> **Personal build.** This is a personal project built for my own use. It is not intended to be useful for anyone other than me.

A native macOS music visualizer. Pick any running app's audio output and watch it drive a
full [projectM](https://github.com/projectM-visualizer/projectm) (MilkDrop-style)
visualization, rendered in a native SwiftUI app.

Built with:
- **SwiftUI** for the app shell, menus, and Settings window
- **libprojectM 4.x** (built from source) for rendering, called directly from Swift via a C bridging header
- **CoreAudio process taps** (`AudioHardwareCreateProcessTap`, macOS 14.2+) for per-app audio capture

## Features

- Pick any audio-producing app from the **Audio** menu (or let it auto-select the first one it finds); switches live, no restart
- Cycle, randomize, or shuffle through ~9,800 community presets from [presets-cream-of-the-crop](https://github.com/projectM-visualizer/presets-cream-of-the-crop)
- On-screen debug overlay (`D`): FPS, current preset name, tapped app
- Fullscreen (`F`), with the visualization resizing cleanly
- Settings window (⌘,): beat sensitivity, preset duration, mesh quality, shuffle, all applied live, no restart

## Keyboard shortcuts

| Key | Action |
|---|---|
| `N` / `→` | Next preset |
| `P` / `←` | Previous preset |
| `R` | Random preset (works regardless of the shuffle setting) |
| `F` | Toggle fullscreen |
| `D` | Toggle on-screen debug overlay |
| `Escape` | Close window |
| `Q` | Quit |

Menu equivalents exist for preset navigation (⌘→ / ⌘← / ⌘R) and audio source selection
(**Audio** menu).

## Building

**Requirements:** macOS 14.2+, Xcode, [Homebrew](https://brew.sh).

```bash
# Build tools
brew install cmake xcodegen

# libprojectM 4.x from source: Homebrew's `projectm` cask is 3.1.x with an old C++ API;
# this project needs 4.x's C API, which Swift can call directly.
mkdir -p vendor && cd vendor
git clone https://github.com/projectM-visualizer/projectm.git
cd projectm && git submodule update --init
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_PLAYLIST=ON -DENABLE_TESTING=OFF -DENABLE_SDL_UI=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2
cmake --build . --parallel
sudo cmake --install .
cd ../../..

# Presets + textures (fetched fresh, not vendored in this repo, see fetch-resources.sh)
./fetch-resources.sh

# Generate the Xcode project and build
xcodegen generate
open projectMac.xcodeproj
```

Or from the command line: `./build.sh` (Debug by default; pass `Release` for a release build).

`project.yml` is the source of truth for the Xcode project, re-run `xcodegen generate`
after editing it rather than hand-editing `projectMac.xcodeproj`.

### Packaging a DMG

`./package.sh [version]` builds a Release configuration and packages it into
`dist/projectMac-<version>.dmg` (version defaults to `git describe` if omitted). Pushing
a `v*` tag (e.g. `v0.2.0`) also runs this via the [Release workflow](.github/workflows/release.yml),
attaching the resulting DMG to a GitHub Release automatically.

### Signing & entitlements

Process taps require App Sandbox off and the `com.apple.security.device.audio-input`
entitlement; both are already configured in `project.yml`. Pick a signing team in
Xcode's project settings before running on your own machine.

## Architecture

Audio flows: CoreAudio HAL I/O thread (process tap) to lock-free ring buffer to CVDisplayLink
render thread to `projectm_pcm_add_float`. The render loop and any preset/settings changes
share a GL context lock to stay off each other's toes.

## Acknowledgments

- [**projectM**](https://github.com/projectM-visualizer/projectm), the visualization engine this app is a thin native wrapper around, along with its
  [presets-cream-of-the-crop](https://github.com/projectM-visualizer/presets-cream-of-the-crop) and
  [presets-milkdrop-texture-pack](https://github.com/projectM-visualizer/presets-milkdrop-texture-pack) asset packs.
- **[frontend-sdl-rust](https://github.com/projectM-visualizer/frontend-sdl-rust)** (projectM's Rust/SDL reference frontend, LGPL-licensed), used as a
  reference for preset/config conventions and keybindings.
- The process-tap code (`Audio/TapResources.swift`, `Audio/ProcessTapController.swift`) was
  written from Apple's public process-tap API, informed by patterns common to public
  reference implementations of it, notably [pantafive/fader](https://github.com/pantafive/fader)
  (MIT-licensed).

## License

This project's own code is [MIT](LICENSE).

**Third-party: libprojectM** is [LGPL-2.1-or-later](https://github.com/projectM-visualizer/projectm/blob/master/LICENSE.txt),
copyright the projectM Team. It is not vendored in this repository, the build
steps above have you clone and build it fresh from its own upstream source,
unmodified, and link it in statically.
