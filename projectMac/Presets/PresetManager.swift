import AppKit

/// Owns the projectM playlist for one projectm_handle instance.
///
/// Playlist calls (`projectm_playlist_play_next`, etc.) can trigger preset loading, which
/// touches GL resources, so every call here is wrapped in the same GL context lock the
/// render loop uses, to avoid racing with `projectm_opengl_render_frame` on the
/// CVDisplayLink thread.
final class PresetManager {
    private let pm: projectm_handle
    private let glContext: NSOpenGLContext
    private nonisolated(unsafe) var playlist: projectm_playlist_handle?

    /// Fired after every preset change, with the preset's filename (no directory). Called
    /// synchronously on whatever thread triggered the change (always the main thread in
    /// this app, start()/nextPreset()/etc. are only ever called from AppKit/SwiftUI).
    var onPresetChanged: ((String) -> Void)?

    init(pm: projectm_handle, glContext: NSOpenGLContext) {
        self.pm = pm
        self.glContext = glContext
    }

    /// `shuffle` must be applied before the initial `play_next` below, since that call is
    /// what decides whether the first-ever preset is picked randomly or deterministically
    /// (always whatever landed first when the paths were scanned) — applying it only
    /// afterwards, e.g. from `AppCoordinator.applyPersistedSettings()`, is too late for
    /// this first pick.
    func start(shuffle: Bool) {
        guard let playlist = projectm_playlist_create(pm) else { return }
        self.playlist = playlist

        if let resourceURL = Bundle.main.resourceURL {
            let presetsPath = resourceURL.appendingPathComponent("Presets").path
            let texturesPath = resourceURL.appendingPathComponent("Textures").path
            projectm_playlist_add_path(playlist, presetsPath, true, false)
            projectm_playlist_add_path(playlist, texturesPath, true, false)
        }

        // Without this, `onPresetChanged` would only ever fire from nextPreset()/
        // prevPreset()/etc. below, missing projectM's own automatic switches (preset
        // duration timeout, beat-driven hard cuts) — the displayed preset name would go
        // stale the moment the engine advances on its own.
        projectm_playlist_set_preset_switched_event_callback(playlist, Self.presetSwitchedCallback, Unmanaged.passUnretained(self).toOpaque())

        setShuffle(shuffle)

        withLock {
            projectm_playlist_play_next(playlist, true)
        }
        reportCurrentPreset()
    }

    /// Fires on *any* preset switch, not just ones made through this class. Automatic
    /// switches happen inside `projectm_opengl_render_frame`, so this runs on the
    /// CVDisplayLink render thread in that case (vs. the main thread for
    /// start()/nextPreset()/etc.) — safe without extra locking because both paths are
    /// already serialized by the same GL context lock (`withLock` here, `ctx.lock()`
    /// around the render call in `ProjectMGLView`). `reportCurrentPreset` hops to main
    /// before touching `onPresetChanged`, since it drives `@Observable` state.
    private static let presetSwitchedCallback: projectm_playlist_preset_switched_event = { _, _, userData in
        guard let userData else { return }
        Unmanaged<PresetManager>.fromOpaque(userData).takeUnretainedValue().reportCurrentPreset()
    }

    func nextPreset() {
        guard let playlist else { return }
        withLock {
            projectm_playlist_play_next(playlist, false)
        }
        reportCurrentPreset()
    }

    func prevPreset() {
        guard let playlist else { return }
        withLock {
            projectm_playlist_play_previous(playlist, false)
        }
        reportCurrentPreset()
    }

    /// Jumps to a random playlist position, ignoring the shuffle setting: shuffle only
    /// governs automatic next/prev ordering, this is an explicit one-off user request.
    func randomPreset() {
        guard let playlist else { return }
        let size = projectm_playlist_size(playlist)
        guard size > 0 else { return }
        let index = UInt32.random(in: 0..<size)
        withLock {
            _ = projectm_playlist_set_position(playlist, index, false)
        }
        reportCurrentPreset()
    }

    // MARK: - Settings

    func setBeatSensitivity(_ value: Float) {
        withLock { projectm_set_beat_sensitivity(pm, value) }
    }

    func setPresetDuration(_ seconds: Double) {
        withLock { projectm_set_preset_duration(pm, seconds) }
    }

    func setMeshSize(width: Int, height: Int) {
        withLock { projectm_set_mesh_size(pm, width, height) }
    }

    func setShuffle(_ enabled: Bool) {
        guard let playlist else { return }
        withLock { projectm_playlist_set_shuffle(playlist, enabled) }
    }

    private func withLock(_ body: () -> Void) {
        glContext.lock()
        glContext.makeCurrentContext()
        body()
        glContext.unlock()
    }

    private func reportCurrentPreset() {
        guard let playlist, let onPresetChanged else { return }
        let position = projectm_playlist_get_position(playlist)
        guard let cString = projectm_playlist_item(playlist, position) else { return }
        let path = String(cString: cString)
        projectm_playlist_free_string(cString)
        let name = (path as NSString).lastPathComponent
        RunLoop.main.perform {
            onPresetChanged(name)
        }
    }

    deinit {
        if let playlist {
            projectm_playlist_set_preset_switched_event_callback(playlist, nil, nil)
            projectm_playlist_destroy(playlist)
        }
    }
}
