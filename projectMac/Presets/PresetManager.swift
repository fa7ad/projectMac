import AppKit

/// Owns the projectM playlist for one projectm_handle.
///
/// Playlist calls can trigger preset loading, which touches GL resources, so every one is
/// wrapped in the same context lock that guards rendering on the CVDisplayLink thread.
final class PresetManager {
    private let pm: projectm_handle
    private let glContext: NSOpenGLContext
    private var playlist: projectm_playlist_handle?

    /// Fired after every preset change with the preset's filename.
    var onPresetChanged: ((String) -> Void)?

    init(pm: projectm_handle, glContext: NSOpenGLContext) {
        self.pm = pm
        self.glContext = glContext
    }

    /// `shuffle` governs later next/prev ordering only: the startup preset is always
    /// random, as is `randomPreset()`.
    func start(shuffle: Bool) {
        guard let playlist = projectm_playlist_create(pm) else { return }
        self.playlist = playlist

        if let resourceURL = Bundle.main.resourceURL {
            let presetsPath = resourceURL.appendingPathComponent("Presets").path
            let texturesPath = resourceURL.appendingPathComponent("Textures").path
            projectm_playlist_add_path(playlist, presetsPath, true, false)
            projectm_playlist_add_path(playlist, texturesPath, true, false)
        }

        projectm_playlist_set_preset_switched_event_callback(playlist, Self.presetSwitchedCallback, Unmanaged.passUnretained(self).toOpaque())

        setShuffle(shuffle)

        let size = projectm_playlist_size(playlist)
        withLock {
            if size > 0 {
                _ = projectm_playlist_set_position(playlist, UInt32.random(in: 0..<size), true)
            } else {
                projectm_playlist_play_next(playlist, true)
            }
        }
        reportCurrentPreset()
    }

    /// Fires on *any* switch, including projectM's automatic ones (duration timeout, beat
    /// cuts) — those run inside `projectm_opengl_render_frame`, so on the CVDisplayLink
    /// thread. Both paths are serialized by the GL context lock, and `reportCurrentPreset`
    /// hops to main before touching `@Observable` state.
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

    /// Ignores the shuffle setting: that governs next/prev ordering, this is a one-off.
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
