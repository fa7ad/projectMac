import AppKit
import CoreVideo
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
        coordinator.audioFeed.drainInto(pm: pm)
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
        ctx.flushBuffer()
        ctx.unlock()
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
