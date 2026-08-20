# projectM(ac)

[![Build](https://github.com/fa7ad/projectMac/actions/workflows/build.yml/badge.svg)](https://github.com/fa7ad/projectMac/actions/workflows/build.yml)

> **Personal build.** Written for my own use, not maintained for general use.

A macOS music visualizer. It captures the audio output of a selected running app and
renders a MilkDrop-style visualization from it using
[projectM](https://github.com/projectM-visualizer/projectm).

Components:
- **SwiftUI** for the app shell, menus, and Settings window
- **libprojectM 4.x**, built from source and called from Swift through a C bridging header
- **CoreAudio process taps** (`AudioHardwareCreateProcessTap`, introduced in macOS 14.2) for per-app audio capture

## Features

- Audio source is chosen from the **Audio** menu, listing apps that are currently producing
  audio; the first one found is selected at launch. Changing it takes effect without a restart.
- Preset navigation: next, previous, random, and shuffle over the ~9,800 presets in
  [presets-cream-of-the-crop](https://github.com/projectM-visualizer/presets-cream-of-the-crop)
- On-screen debug overlay (`D`): FPS, current preset name, tapped app
- Fullscreen (`F`); the visualization resizes with the window
- Settings window (⌘,): beat sensitivity, preset duration, mesh quality, and shuffle,
  each applied without a restart

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

**Requirements:** macOS 15+, Xcode, [Homebrew](https://brew.sh). (Process taps need
14.2; the 15 floor comes from the Swift `Synchronization` module the audio ring
buffer uses.)

```bash
# Build tools
brew install cmake xcodegen

# libprojectM 4.x, built from source (see below)
./build-libprojectm.sh

# Presets + textures (fetched fresh, not vendored in this repo, see fetch-resources.sh)
./fetch-resources.sh

# Generate the Xcode project and build
xcodegen generate
open projectMac.xcodeproj
```

Or from the command line: `./build.sh` (Debug by default; pass `Release` for a release build).

`project.yml` is the source of truth for the Xcode project, re-run `xcodegen generate`
after editing it rather than hand-editing `projectMac.xcodeproj`.

### libprojectM

The app links against libprojectM 4.x, which it calls through the library's C API.
Homebrew's `projectm` package is 3.1.x and exposes a C++ API instead, so the 4.x build
comes from source.

`./build-libprojectm.sh` performs that build:

- clones `projectM-visualizer/projectm` into `vendor/projectm`, or fast-forwards it if
  the clone already exists, then initializes its submodules
- configures a Release build in `vendor/projectm/build` as a static library with the
  playlist library enabled, tests and the SDL UI disabled, and a 15.0 deployment target
- builds and installs into `/usr/local`, using `sudo` for the install step only when the
  prefix is not writable

Set `PREFIX` to install elsewhere: `PREFIX="$HOME/.local" ./build-libprojectm.sh`.
`vendor/` is gitignored, so the checkout and build tree stay out of this repository.

### Packaging a DMG

`./package.sh [version]` builds a Release configuration and packages it into
`dist/projectMac-<version>.dmg` (version defaults to `git describe` if omitted). Pushing
a `v*` tag (e.g. `v0.2.0`) also runs this via the [Release workflow](.github/workflows/release.yml),
attaching the resulting DMG to a GitHub Release.

### Signing & entitlements

Process taps require App Sandbox off and the `com.apple.security.device.audio-input`
entitlement; both are already configured in `project.yml`. Pick a signing team in
Xcode's project settings before running on your own machine.

## Architecture

Audio flows: CoreAudio HAL I/O thread (process tap) to lock-free ring buffer to CVDisplayLink
render thread to `projectm_pcm_add_float`. The render loop and any preset/settings changes
share a GL context lock, so they do not run concurrently.

## Acknowledgments

- [**projectM**](https://github.com/projectM-visualizer/projectm), the visualization engine
  this app wraps, along with its
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
copyright the projectM Team. It is not vendored in this repository; the build steps above
clone and build it from its own upstream source, unmodified, and link it statically.
