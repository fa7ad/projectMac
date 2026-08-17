import AppKit
import CoreVideo
import os

final class ProjectMGLView: NSOpenGLView {

    // Accessed from both the main thread and the CVDisplayLink callback thread;
    // safety is by construction (display link lifecycle), not actor isolation.
    private nonisolated(unsafe) var displayLink: CVDisplayLink?
    private nonisolated(unsafe) var pm: projectm_handle?

    /// Set immediately after creation by `ProjectMViewRepresentable.makeNSView`, before
    /// this view is attached to a window, always non-nil by the time `prepareOpenGL()`
    /// or `keyDown(_:)` can fire.
    nonisolated(unsafe) var coordinator: AppCoordinator!

    private let logger = Logger(subsystem: "com.projectmac.app", category: "ProjectMGLView")

    // FPS counting, only ever touched from the CVDisplayLink thread.
    private nonisolated(unsafe) var frameCount = 0
    private nonisolated(unsafe) var lastFPSSampleTime = CFAbsoluteTimeGetCurrent()

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
            // Informational only: fed to presets for their own calculations, doesn't
            // throttle or otherwise affect this render loop's actual cadence, which
            // CVDisplayLink drives at the display's native rate.
            projectm_set_fps(pm, 60)
            let manager = PresetManager(pm: pm, glContext: ctx)
            coordinator.attach(presetManager: manager)
            manager.start()
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
        if let fps = sampleFPS() {
            let stats = coordinator.renderStats
            DispatchQueue.main.async {
                stats.fps = fps
            }
        }
        projectm_opengl_render_frame(pm)
        ctx.flushBuffer()
        ctx.unlock()
    }

    /// Returns a new FPS sample about once per second, else nil.
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

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        coordinator.stop()
        if let pm { projectm_destroy(pm) }
    }
}
