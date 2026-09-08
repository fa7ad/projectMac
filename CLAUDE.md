# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS music visualizer (SwiftUI + AppKit). It taps any running app's audio
output via a CoreAudio process tap (macOS 14.2+, `AudioHardwareCreateProcessTap`) and
feeds the PCM into libprojectM 4.x (built from source, called directly from Swift via a
C bridging header) for MilkDrop-style rendering. This is a personal build, not intended
for general use.

## Commands

All build scripts live in `scripts/` and source `scripts/lib.sh`. Put anything more
than one script needs in `lib.sh` rather than duplicating it. Every script works from
any working directory.

Build (regenerates the Xcode project via XcodeGen, then builds):
```bash
./scripts/build.sh              # Debug
./scripts/build.sh Release      # Release
./scripts/build.sh --unsigned   # skip code signing (what CI uses)
./scripts/build.sh --with-deps  # build libprojectM + fetch resources first
./scripts/build.sh --help
```

`project.yml` is the source of truth for the Xcode project. Never hand-edit
`projectMac.xcodeproj`, edit `project.yml` and re-run `xcodegen generate` (or
`scripts/build.sh`, which does this automatically).

Fetch preset/texture assets (not vendored, gitignored, run once before first build or
whenever presets need refreshing):
```bash
./scripts/fetch-resources.sh
```
`scripts/build.sh` and `scripts/package.sh` call this automatically when the directories
are missing (`ensure_resources` in `scripts/lib.sh`). The guard tests directory
*existence*, not contents — CI relies on that to skip the fetch with empty placeholders.

Package a Release build into `dist/`:
```bash
./scripts/package.sh [version]            # DMG (version defaults to `git describe`)
./scripts/package.sh [version] --no-dmg   # projectMac-<version>.app instead
```
Pushing a `v*` tag runs `scripts/package.sh` in CI
(`.github/workflows/release.yml`) and attaches the DMG to a GitHub Release.
`.github/workflows/build.yml` runs on every push/PR to `main` as a compile-only check
(`scripts/build.sh --unsigned`). Both workflows share libprojectM's build/cache step via
the `.github/actions/setup-build` composite action.

There is no automated test suite in this project (no test target in `project.yml`).
Verification is interactive: build, run via `open projectMac.xcodeproj` or
`scripts/build.sh` + launch, and exercise the feature by hand (audio tap selection,
preset navigation, settings, fullscreen).

libprojectM itself must be built from source into `$PREFIX` (default `/usr/local`)
before the app can link (Homebrew's `projectm` cask is 3.1.x with an old C++ API; this
project needs 4.x's C API). `./scripts/deps.sh` does this: clones/updates
`vendor/projectm`, builds it static with the playlist library, and installs it (set
`PREFIX` to install elsewhere, `DEPLOYMENT_TARGET` to change the minimum OS). Needs
`brew install glm`. The CI composite action `.github/actions/setup-build` runs the same
script, so the cmake invocation lives in one place only.

`project.yml` writes its search paths as `$(PROJECTM_PREFIX)/{include,lib}` and
`xcode_build` passes `PROJECTM_PREFIX=$PREFIX` on the xcodebuild command line, so
`PREFIX` is the only knob. CI must keep it off `/usr/local`: `actions/cache` restores
without sudo, so caching a `/usr/local` prefix fails extraction on every run
(`Cannot mkdir: Permission denied`) and rebuilds the library each time.

## Architecture

### Threading model: the most important constraint in this codebase

Three threads touch shared state, each with different rules:

- **Main thread (SwiftUI/AppKit)**: menu commands, `@Observable` state updates,
  `AppCoordinator`, settings changes.
- **CVDisplayLink thread** (private, high-priority, driven by `ProjectMGLView`): calls
  `AudioFeed.drainInto()` then `projectm_opengl_render_frame()`. Must lock the GL
  context (`NSOpenGLContext.lock()/unlock()`) around all GL calls, and must never touch
  AppKit/SwiftUI directly (hence `DispatchQueue.main.async` when updating `RenderStats`).
- **CoreAudio HAL I/O thread** (real-time, in `ProcessTapController`'s IOProc callback):
  zero allocations, zero Objective-C messaging, zero locks/blocking. Samples are written
  into `AudioFeed`'s lock-free SPSC ring buffer (single-producer: IOProc; single-consumer:
  render thread) rather than processed synchronously.

Any change touching audio capture or rendering needs to respect which thread it runs on.

### Core flow

```
CoreAudio HAL I/O thread (process tap) → AudioFeed ring buffer → CVDisplayLink render
thread → projectm_pcm_add_float → projectm_opengl_render_frame
```

`PresetManager` calls (`nextPreset`/`prevPreset`/etc.) share the same GL context lock the
render loop uses, since they can trigger preset loads that touch GL resources; this
avoids racing `projectm_opengl_render_frame` on the CVDisplayLink thread. Playlist calls
must only happen on the main thread.

### Key types and where state lives

- **`AppCoordinator`** (`AppCoordinator.swift`): the central `@Observable` hub. Created
  once at app launch; owns `AudioAppMonitor`, `AudioFeed`, and `RenderStats`
  immediately. Its `PresetManager` is `nil` until `ProjectMGLView.prepareOpenGL()` runs
  (it needs a live GL context to exist), at which point the view calls
  `coordinator.attach(presetManager:)`. Both the `NSViewRepresentable` and the SwiftUI
  `.commands` menu block read this same instance, so bare-key shortcuts (handled in
  `ProjectMGLView.keyDown`) and menu shortcuts drive identical state without duplication.
  Startup order in `prepareOpenGL()` matters: `attach()` wires the preset-changed
  callback *before* `PresetManager.start()` loads the first preset (so the initial load
  is observed, not just later next/prev calls), and `applyPersistedSettings()` runs
  *after* `start()` (so the playlist already exists when settings like shuffle apply).
  Because one coordinator holds exactly one `PresetManager`, the app is a single-window
  app: `projectMacApp` uses a `Window` scene (not `WindowGroup`) and disables window
  tabbing, so no second `ProjectMGLView` can attach over the first one's GL context.

- **`ProjectMGLView`** (`Rendering/ProjectMGLView.swift`): an `NSOpenGLView` subclass
  owning the `projectm_handle`, the `CVDisplayLink`, and input handling: keyboard
  shortcuts (`N`/`P`/`R`/`F`/`D`/`Q`/arrows/Escape) plus double-click to toggle
  fullscreen. Wrapped for SwiftUI via
  `ProjectMViewRepresentable`. `projectm_set_fps` is set once to a fixed `60` at
  creation, it's purely informational (fed to presets for their own calculations) and
  doesn't throttle the actual render cadence, which `CVDisplayLink` drives at the
  display's native rate regardless.

- **`PresetManager`** (`Presets/PresetManager.swift`): owns the
  `projectm_playlist_handle` for one `projectm_handle` instance; wraps
  next/prev/random/settings calls in the GL context lock.

- **`ProcessTapController` + `TapResources`** (`Audio/`): tap lifecycle for one PID.
  Mute behavior is `.unmuted`: the tapped app keeps playing through its own normal
  output path untouched; the wrapping aggregate device exists only to give the tap's
  IOProc a clock source. `TapResources.destroy()` has a strict teardown order (stop
  device proc, destroy IOProc ID, destroy aggregate device, destroy process tap);
  violating it can leak HAL resources or crash on shutdown.

- **`AudioAppMonitor`** (`Audio/AudioAppMonitor.swift`): enumerates apps currently
  producing audio via `kAudioHardwarePropertyProcessObjectList`, debounced (50ms) since
  the HAL can fire the change notification several times in quick succession.

- **`AudioFeed`** (`Audio/AudioFeed.swift`): the lock-free SPSC ring buffer bridging
  the HAL I/O thread to the render thread. Drops samples on overflow rather than
  blocking, since visual latency from a full buffer isn't worth a real-time stall. Its
  read/write indices are `Synchronization.Atomic` with release/acquire ordering, so the
  sample stores an index publishes are visible before the index itself is — this is why
  the deployment target is 15.0 rather than the 14.2 that process taps alone would need.

- **`AppSettingsKeys`** (`Settings/AppSettingsKeys.swift`): single source of truth for
  UserDefaults keys and defaults, shared between `SettingsView`'s `@AppStorage`
  properties and `AppCoordinator.applyPersistedSettings()` so the two can't drift.
  Registered via `UserDefaults.standard.register(defaults:)` in `projectMacApp.init()`.

- **`Bridge/projectm-bridge.h`**: the C bridging header importing libprojectM's C API
  (`core.h`, `render_opengl.h`, `audio.h`, `parameters.h`, `playlist.h`) plus
  `OpenGL/gl3.h`. This is how Swift calls libprojectM directly with no Obj-C++ shim.

- **`SceneStream/`** (`BeatDetector.swift`, `VisualOnsetDetector.swift`,
  `AudioBandAnalyzer.swift`, `DominantColor.swift`, `SceneReducer.swift`,
  `SceneStreamBroadcaster.swift`): streams tempo/phase (audio- and visual-derived),
  dominant-color, and frequency-band state as OSC messages over a loopback UDP socket
  (`127.0.0.1:9000` by default) for any OSC-aware process to consume — e.g. Chataigne
  bridging to smart-home lighting, TouchDesigner, or another music-reactive consumer.
  Deliberately a generic OSC source with no consumer-specific logic: it broadcasts both
  audio- and visual-derived rate estimates side by side (a preset's on-screen cut rate
  often doesn't track the song's BPM) and lets each consumer arbitrate which to trust.
  Toggled by the "Broadcast scene stream" setting (off by default). Addresses, each its
  own datagram:
  `/projectmac/tempo/bpm`, `/projectmac/tempo/phase` (audio-side, from `BeatDetector`);
  `/projectmac/visual/bpm`, `/projectmac/visual/phase`, `/projectmac/visual/onset` (bang,
  visual-side, from `VisualOnsetDetector`); `/projectmac/scene/vibrant`,
  `/projectmac/scene/muted`, `/projectmac/scene/average` (h/s/v floats, 0.0-1.0, hue as a
  fraction of the circle — from `DominantColor`'s k-means); `/projectmac/scene/brightness`
  (Rec. 709 luma, 0.0-1.0 — not the same as HSV's `v`); `/projectmac/audio/bass`,
  `/projectmac/audio/mid`, `/projectmac/audio/treble` (FFT band energy, 0.0-1.0, from
  `AudioBandAnalyzer`); `/projectmac/preset/changed` (bang) + `/projectmac/preset/name`
  (string), forwarded from `PresetManager.onPresetChanged` on every preset switch. Raw RGB
  is not on the wire at all — HSV is what real downstream lighting protocols (DMX, Hue)
  want directly.
  - `BeatDetector`: a causal energy-threshold onset detector, fed the same samples
    `AudioFeed.drainInto` hands to projectM (via its `tap` closure param), called
    once per frame on the CVDisplayLink thread — the one detector that stays there,
    since it's proven-cheap and already working. Tracks a rolling BPM estimate and a
    `phase` (0.0-1.0 position within the current beat interval) from detected onsets.
  - `ProjectMGLView.readFramebufferPixels()` is the only GL-bound step
    (`glBlitFramebuffer` + `glReadPixels` into the 32×32 `sceneSampleFramebuffer`) and
    is all that still runs on the CVDisplayLink thread; everything downstream of that
    raw pixel array — black-level exclusion, k-means, frame-diff, phase, FFT band
    split, OSC send — runs on `SceneReducer`'s own dedicated serial background queue,
    off the render thread entirely. `renderFrame` snapshots `beatDetector`'s
    BPM/phase into local values and hands the pixel array (plus a copy of this
    frame's PCM block, for the FFT) to `SceneReducer.processFrame`, which drops
    (rather than backlogs) a frame's work if the queue is still busy with the
    previous one, via an `Atomic<Bool>` in-flight flag — the same "drop rather than
    block" policy `AudioFeed` uses for ring-buffer overflow.
  - `VisualOnsetDetector`: same detection shape as `BeatDetector` (rolling
    mean+stddev threshold, refractory period, rolling-median BPM/phase) but reduced
    from a per-frame mean-RGB frame-diff energy scalar instead of streaming audio
    blocks — kept as its own class since the two inputs are structurally different.
    Lives entirely on `SceneReducer`'s queue.
  - `DominantColor`: k-means (k=3) over the readback texels, RGB space, after
    discarding near-black texels (Ambilight/Hyperion-style black-level exclusion so a
    mostly-black MilkDrop frame doesn't waste clusters on the background). `vibrant`
    maximizes population×saturation (avoids returning something drab); `muted` is the
    largest surviving cluster by population. HSV conversion happens once, after
    selection, not per texel. The flat average (`average`) is also computed here and
    converted to HSV, replacing the old raw-RGB reduction.
  - `AudioBandAnalyzer`: bass/mid/treble via `vDSP_fft_zrip` (Accelerate — linked as
    its own framework dependency in `project.yml`) over a Hann-windowed downmix of the
    same PCM `BeatDetector` sees; runs entirely on `SceneReducer`'s queue.

### Signing & entitlements

Process taps require App Sandbox off and the
`com.apple.security.device.audio-input` entitlement; both already configured in
`project.yml`/`projectMac.entitlements`.

`Config/Signing.xcconfig` defaults to ad-hoc signing and optionally includes
`Config/Local.xcconfig` (gitignored, copied from `.example`) for a real team ID.

Keep signing settings out of `project.yml` — they get baked into the committed
`project.pbxproj`, and a project-level build setting there outranks the target's
xcconfig, so it would override `Local.xcconfig` instead of being overridden by it.
