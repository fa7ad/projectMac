import AppKit
import CoreVideo
import Synchronization
import os

final class ProjectMGLView: NSOpenGLView {

    // Touched from both the main and CVDisplayLink threads; safe by construction (the
    // display link's lifecycle), not by isolation.
    private var displayLink: CVDisplayLink?
    private var pm: projectm_handle?

    /// Set by `ProjectMViewRepresentable.makeNSView` before the view reaches a window, so
    /// non-nil by the time anything here can fire.
    var coordinator: AppCoordinator!

    private let logger = Logger(subsystem: "com.projectmac.app", category: "ProjectMGLView")

    // CVDisplayLink thread only: FPS counting, and the audio peak between FPS samples.
    private var frameCount = 0
    private var lastFPSSampleTime = CFAbsoluteTimeGetCurrent()
    private var peakSinceLastSample: Float = 0

    // CVDisplayLink thread only: lets a broadcast re-enable reset the audio analyzers,
    // whose sample-counted windows would otherwise span the gap.
    private var wasBroadcasting = false

    // Widened from 8 so k-means (DominantColor) has enough texels to resolve clusters.
    private let colorSampleSize: GLsizei = 32
    // Offscreen target `sampleAverageFramebufferColor` blits the whole frame down into,
    // so the average represents the entire scene rather than one small patch of it.
    private var sceneSampleFramebuffer: GLuint = 0
    private var sceneSampleRenderbuffer: GLuint = 0

    // projectM renders into this texture rather than the window's framebuffer, so the
    // frame can also be sampled by other GL contexts sharing this one (mirror windows).
    // Sized to the view's backing size; created/resized/read only under the context lock.
    private var sceneTexture: GLuint = 0
    private var sceneFramebuffer: GLuint = 0
    private var didApplyLaunchFullscreen = false
    private var projectMSize = (0, 0) // what projectM was last told, to skip redundant resizes
    private var appliedRenderScale = 1.0 // main thread (reshape)
    private var sceneSize: (width: GLsizei, height: GLsizei) = (0, 0)
    // HDR output only (nil otherwise): boosts highlights while drawing the texture to the window.
    private var expandPass: ExpandPass?

    static func makePixelFormat() -> NSOpenGLPixelFormat {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFADepthSize), 24,
        ] + (HDR.isActive ? [UInt32(NSOpenGLPFAColorFloat), UInt32(NSOpenGLPFAColorSize), 64] : []) + [0]
        return NSOpenGLPixelFormat(attributes: attrs)!
    }

    override var acceptsFirstResponder: Bool { true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        wantsBestResolutionOpenGLSurface = true
        wantsExtendedDynamicRangeOpenGLSurface = HDR.isActive
        openGLContext?.makeCurrentContext()
        if HDR.isActive { expandPass = ExpandPass() }

        setupSceneSampleTarget()
        setupSceneTarget()
        pm = projectm_create()
        updateWindowSize()
        if let pm, let ctx = openGLContext {
            // Informational only, for presets' own calculations; CVDisplayLink drives the
            // real cadence at the display's native rate.
            projectm_set_fps(pm, 60)
            logger.debug("projectm_pcm_get_max_samples() = \(projectm_pcm_get_max_samples())")
            let manager = PresetManager(pm: pm, glContext: ctx)
            coordinator.attach(presetManager: manager)
            manager.start(shuffle: UserDefaults.standard.bool(forKey: AppSettingsKeys.shufflePresets))
            coordinator.applyPersistedSettings()
        }
        coordinator.mirrorController.attach(mainView: self)
        // Settings writes UserDefaults directly; re-size the scene when the scale changes.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.renderScale != self.appliedRenderScale else { return }
            self.reshape()
        }
        startDisplayLink()
        coordinator.start()
    }

    override func reshape() {
        super.reshape()
        guard let ctx = openGLContext else { return }
        // Lock: resizing the scene texture can't interleave with the render thread's frame.
        ctx.lock()
        ctx.makeCurrentContext()
        ctx.update()
        updateWindowSize()
        ctx.unlock()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if HDR.isActive { window?.colorSpace = .extendedSRGB }
        window?.makeFirstResponder(self)
        // The View menu's "Enter Full Screen" and the green button both send toggleFullScreen:
        // (the menu item down the responder chain, which reaches this view first), so they
        // follow the borderless setting like F and double-click do.
        if let zoom = window?.standardWindowButton(.zoomButton) {
            zoom.target = self
            zoom.action = #selector(toggleFullScreen(_:))
        }
        if !didApplyLaunchFullscreen, let window {
            didApplyLaunchFullscreen = true
            if UserDefaults.standard.bool(forKey: AppSettingsKeys.fullscreenOnLaunch) {
                // After the window is on screen; fullscreening from inside the view setup is ignored.
                DispatchQueue.main.async { [weak self] in
                    if !window.styleMask.contains(.fullScreen) { MainActor.assumeIsolated { self?.coordinator.mirrorController.toggleMainFullscreen() } }
                }
            }
        }
    }

    private func updateWindowSize() {
        let backing = convertToBacking(bounds)
        guard let pm else { return }
        let scale = renderScale
        appliedRenderScale = scale
        // While spanning, the scene is the canvas covering every display, not this window.
        let base = coordinator.mirrorController.spanCanvas ?? (width: Int(backing.width), height: Int(backing.height))
        var maxSide: GLint = 0
        glGetIntegerv(GLenum(GL_MAX_TEXTURE_SIZE), &maxSide) // 200% of a big display can exceed it
        // Shrink both sides by the same factor if the larger exceeds the texture limit (keeps the aspect).
        let fit = min(1, Double(maxSide) / (Double(max(base.width, base.height)) * scale))
        let w = max(1, Int(Double(base.width) * scale * fit))
        let h = max(1, Int(Double(base.height) * scale * fit))
        resizeSceneTarget(width: GLsizei(w), height: GLsizei(h))
        if projectMSize != (w, h) {
            projectMSize = (w, h)
            projectm_set_window_size(pm, w, h)
        }
    }

    /// Scene pixels per window pixel (Settings); the window blit and mirrors scale the
    /// scene texture to fit.
    private var renderScale: Double {
        let v = UserDefaults.standard.double(forKey: AppSettingsKeys.renderScale)
        return v > 0 ? min(v, 2) : 1
    }

    /// Needs the context current (and locked unless called during `prepareOpenGL`).
    private func setupSceneTarget() {
        glGenTextures(1, &sceneTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), sceneTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glGenFramebuffers(1, &sceneFramebuffer)
        resizeSceneTarget(width: 1, height: 1)
    }

    private func resizeSceneTarget(width: GLsizei, height: GLsizei) {
        let (w, h) = (max(1, width), max(1, height))
        guard sceneSize != (w, h) else { return }
        sceneSize = (w, h)
        glBindTexture(GLenum(GL_TEXTURE_2D), sceneTexture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, w, h, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), sceneFramebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), sceneTexture, 0)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            Unmanaged<ProjectMGLView>.fromOpaque(ctx!).takeUnretainedValue().renderFrame()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func renderFrame() {
        guard let ctx = openGLContext, let pm else { return }
        ctx.lock()
        ctx.makeCurrentContext()
        let broadcastEnabled = coordinator.sceneStreamBroadcaster.isEnabled.load(ordering: .relaxed)
        if broadcastEnabled && !wasBroadcasting { coordinator.sceneReducer.resetAudio() }
        wasBroadcasting = broadcastEnabled
        let sampleRate = coordinator.audioFeed.sampleRate
        let reducer = coordinator.sceneReducer
        coordinator.audioFeed.drainInto(pm: pm) { samples in
            guard broadcastEnabled else { return }
            // Beat/band analysis runs on the reducer's queue, off this thread.
            reducer.pushAudio(Array(samples), sampleRate: sampleRate, at: CFAbsoluteTimeGetCurrent())
        }
        peakSinceLastSample = max(peakSinceLastSample, coordinator.audioFeed.consumePeakLevel())
        if let fps = sampleFPS() {
            let stats = coordinator.renderStats
            let peak = peakSinceLastSample
            let overflows = coordinator.audioFeed.totalOverflowCount
            let backlog = coordinator.audioFeed.backlogFrames
            let capacityFrames = coordinator.audioFeed.capacityFrames
            peakSinceLastSample = 0
            DispatchQueue.main.async {
                stats.fps = fps
                stats.audioPeakLevel = peak
                stats.audioOverflowCount = overflows
                stats.audioBacklogFrames = backlog
                stats.audioCapacityFrames = capacityFrames
            }
        }
        if coordinator.mirrorController.testPattern.load(ordering: .relaxed) {
            drawTestPattern()
        } else {
            patternSize = (0, 0)
            projectm_opengl_render_frame_fbo(pm, sceneFramebuffer)
        }
        let backing = convertToBacking(bounds)
        // The whole scene, or this window's slice of it while spanning displays.
        let src = coordinator.mirrorController.mainRegion.fillRect(
            scene: Double(sceneSize.width), Double(sceneSize.height), dest: backing.width, backing.height)
        if let expandPass {
            let (sw, sh) = (Float(sceneSize.width), Float(sceneSize.height))
            expandPass.draw(texture: sceneTexture,
                            uvOffset: (Float(src.x0) / sw, Float(src.y0) / sh),
                            uvScale: (Float(src.x1 - src.x0) / sw, Float(src.y1 - src.y0) / sh),
                            gain: coordinator.hdrGain.value, width: GLint(backing.width), height: GLint(backing.height))
        } else {
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sceneFramebuffer)
            glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
            glBlitFramebuffer(
                src.x0, src.y0, src.x1, src.y1,
                0, 0, GLint(backing.width), GLint(backing.height),
                GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR) // scene may differ from window size
            )
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        if broadcastEnabled {
            let pixels = readFramebufferPixels()
            coordinator.sceneReducer.processFrame(
                pixels: pixels,
                gridSize: Int(colorSampleSize))
        }
        ctx.flushBuffer()
        // After the flush so the scene texture's commands are submitted before the mirror
        // contexts read it; the main lock stays held so a resize can't reallocate it meanwhile.
        coordinator.mirrorController.draw(texture: sceneTexture, width: sceneSize.width, height: sceneSize.height,
                                          gain: coordinator.hdrGain.value)
        ctx.unlock()
    }

    private var patternSize: (width: GLsizei, height: GLsizei) = (0, 0)

    /// Puts `SpanTestPattern` on the scene texture instead of rendering the preset. The
    /// texture only needs writing when the pattern is first shown or the scene is resized.
    private func drawTestPattern() {
        guard patternSize != sceneSize else { return }
        patternSize = sceneSize
        let pixels = SpanTestPattern.rgba(width: Int(sceneSize.width), height: Int(sceneSize.height))
        glBindTexture(GLenum(GL_TEXTURE_2D), sceneTexture)
        glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0, 0, 0, sceneSize.width, sceneSize.height,
                        GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), pixels)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
    }

    /// Allocates the fixed-size offscreen target `readFramebufferPixels` blits into.
    /// Sized once — `glBlitFramebuffer` rescales into it regardless of source size.
    private func setupSceneSampleTarget() {
        glGenRenderbuffers(1, &sceneSampleRenderbuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), sceneSampleRenderbuffer)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8), colorSampleSize, colorSampleSize)

        glGenFramebuffers(1, &sceneSampleFramebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), sceneSampleFramebuffer)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), sceneSampleRenderbuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    /// Downsamples the whole scene texture into `sceneSampleFramebuffer` and reads it back as a
    /// raw RGBA8 texel array. The one GL-bound step that can't move off the render
    /// thread; must run with the GL context current, before flushBuffer/unlock.
    private func readFramebufferPixels() -> [UInt8] {
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sceneFramebuffer)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), sceneSampleFramebuffer)
        glBlitFramebuffer(
            0, 0, sceneSize.width, sceneSize.height,
            0, 0, colorSampleSize, colorSampleSize,
            GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR)
        )

        var pixels = [UInt8](repeating: 0, count: Int(colorSampleSize * colorSampleSize) * 4)
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sceneSampleFramebuffer)
        glReadPixels(0, 0, colorSampleSize, colorSampleSize, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)

        return pixels
    }

    private func sampleFPS() -> Int? {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFPSSampleTime
        guard elapsed >= 1.0 else { return nil }
        let fps = Int((Double(frameCount) / elapsed).rounded())
        frameCount = 0
        lastFPSSampleTime = now
        return fps
    }

    override func viewDidHide() {
        super.viewDidHide()
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if let dl = displayLink { CVDisplayLinkStart(dl) }
    }

    private let cursorHider = CursorAutoHider()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        cursorHider.updateTracking(on: self)
    }

    override func mouseMoved(with event: NSEvent) { cursorHider.poke(self) }

    @objc func toggleFullScreen(_ sender: Any?) {
        coordinator.mirrorController.toggleMainFullscreen()
    }

    override func mouseDown(with event: NSEvent) {
        cursorHider.poke(self)
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        coordinator.mirrorController.toggleFullscreen(of: window)
    }

    override func keyDown(with event: NSEvent) {
        cursorHider.poke(self)
        if !handleVisualizerKey(event, in: window, coordinator: coordinator) { super.keyDown(with: event) }
    }

    /// `isolated` so teardown can touch main-actor state without an `unsafe` opt-out. A
    /// release off the main thread hops here first; the view outlives the body either way,
    /// so the display link always stops before dealloc.
    isolated deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        coordinator.stop()
        if let pm { projectm_destroy(pm) }
    }
}
