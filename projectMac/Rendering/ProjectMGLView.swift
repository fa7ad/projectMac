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
    private var sceneSize: (width: GLsizei, height: GLsizei) = (0, 0)

    static func makePixelFormat() -> NSOpenGLPixelFormat {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFADepthSize), 24,
            0
        ]
        return NSOpenGLPixelFormat(attributes: attrs)!
    }

    override var acceptsFirstResponder: Bool { true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        wantsBestResolutionOpenGLSurface = true
        openGLContext?.makeCurrentContext()

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
        window?.makeFirstResponder(self)
    }

    private func updateWindowSize() {
        let backing = convertToBacking(bounds)
        guard let pm else { return }
        resizeSceneTarget(width: GLsizei(backing.width), height: GLsizei(backing.height))
        projectm_set_window_size(pm, Int(backing.width), Int(backing.height))
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
        projectm_opengl_render_frame_fbo(pm, sceneFramebuffer)
        let backing = convertToBacking(bounds)
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sceneFramebuffer)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
        glBlitFramebuffer(
            0, 0, sceneSize.width, sceneSize.height,
            0, 0, GLint(backing.width), GLint(backing.height),
            GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST)
        )
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
        coordinator.mirrorController.draw(texture: sceneTexture, width: sceneSize.width, height: sceneSize.height)
        ctx.unlock()
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

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        window?.toggleFullScreen(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "n":
            coordinator.nextPreset()
        case "p":
            coordinator.prevPreset()
        case "r":
            coordinator.randomPreset()
        case "f":
            window?.toggleFullScreen(nil)
        case "d":
            coordinator.renderStats.isDebugOverlayVisible.toggle()
        case "q":
            NSApp.terminate(nil)
        case "\u{1b}": // Escape
            window?.performClose(nil)
        default:
            switch event.specialKey {
            case .rightArrow:
                coordinator.nextPreset()
            case .leftArrow:
                coordinator.prevPreset()
            default:
                super.keyDown(with: event)
            }
        }
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
