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

    // CVDisplayLink thread only. Assumes ~48kHz; the tap's actual rate varies by source
    // app, but beat detection doesn't need sample accuracy.
    private let beatDetector = BeatDetector(sampleRate: 48000)

    // Widened from 8 so k-means (DominantColor) has enough texels to resolve clusters.
    private let colorSampleSize: GLsizei = 32
    // Offscreen target `sampleAverageFramebufferColor` blits the whole frame down into,
    // so the average represents the entire scene rather than one small patch of it.
    private var sceneSampleFramebuffer: GLuint = 0
    private var sceneSampleRenderbuffer: GLuint = 0

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
        startDisplayLink()
        coordinator.start()
    }

    override func reshape() {
        super.reshape()
        openGLContext?.update()
        updateWindowSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func updateWindowSize() {
        let backing = convertToBacking(bounds)
        guard let pm else { return }
        projectm_set_window_size(pm, Int(backing.width), Int(backing.height))
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
        var pcmCopy: [Float]?
        coordinator.audioFeed.drainInto(pm: pm) { [weak self] samples in
            guard let self, broadcastEnabled else { return }
            _ = self.beatDetector.push(samples)
            pcmCopy = Array(samples)
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
        projectm_opengl_render_frame(pm)
        if broadcastEnabled {
            let pixels = readFramebufferPixels()
            coordinator.sceneReducer.processFrame(
                pixels: pixels,
                gridSize: Int(colorSampleSize),
                audioBPM: beatDetector.currentBPM,
                audioPhase: beatDetector.phase,
                pcm: pcmCopy
            )
        }
        ctx.flushBuffer()
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

    /// Downsamples the whole frame into `sceneSampleFramebuffer` and reads it back as a
    /// raw RGBA8 texel array. The one GL-bound step that can't move off the render
    /// thread; must run with the GL context current, before flushBuffer/unlock.
    private func readFramebufferPixels() -> [UInt8] {
        let backing = convertToBacking(bounds)

        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), 0)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), sceneSampleFramebuffer)
        glBlitFramebuffer(
            0, 0, GLint(backing.width), GLint(backing.height),
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
