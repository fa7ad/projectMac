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

    func start() {
        guard let playlist = projectm_playlist_create(pm) else { return }
        self.playlist = playlist

        if let resourceURL = Bundle.main.resourceURL {
            let presetsPath = resourceURL.appendingPathComponent("Presets").path
            let texturesPath = resourceURL.appendingPathComponent("Textures").path
            projectm_playlist_add_path(playlist, presetsPath, true, false)
            projectm_playlist_add_path(playlist, texturesPath, true, false)
        }

        withLock {
            projectm_playlist_play_next(playlist, true)
        }
        reportCurrentPreset()
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
        onPresetChanged((path as NSString).lastPathComponent)
    }

    deinit {
        if let playlist {
            projectm_playlist_destroy(playlist)
        }
    }
}
