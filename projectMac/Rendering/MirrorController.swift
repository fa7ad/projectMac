import AppKit
import Observation
import Synchronization
import os

/// Mirrors the visualizer onto other displays: one borderless window per chosen screen,
/// each with its own GL context sharing the main one's objects so it can sample
/// `ProjectMGLView`'s scene texture. The scene is rendered once; every mirror just
/// aspect-fills a blit of it, so presets, audio and OSC stay single.
///
/// Main thread: `toggle`, window lifecycle. CVDisplayLink thread: `draw`, which only
/// takes a snapshot of `windows` and then the per-context lock.
@Observable
final class MirrorController: @unchecked Sendable {
    /// Drives the menu's checkmarks; mutated on the main thread only.
    private(set) var mirroredDisplayIDs: Set<CGDirectDisplayID> = []

    @ObservationIgnored private let logger = Logger(subsystem: "com.projectmac.app", category: "MirrorController")
    @ObservationIgnored private let windows = Mutex<[CGDirectDisplayID: MirrorWindow]>([:])
    @ObservationIgnored private weak var mainView: ProjectMGLView?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Connected displays, for the menu.
    var screens: [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { s in Self.displayID(of: s).map { ($0, s.localizedName) } }
    }

    /// Called from `ProjectMGLView.prepareOpenGL`, once its context exists.
    func attach(mainView: ProjectMGLView) {
        self.mainView = mainView
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.appActiveChanged()
            }
        }

        // The window isn't on a screen yet during prepareOpenGL; restore once it is.
        let saved = UserDefaults.standard.array(forKey: AppSettingsKeys.mirrorDisplays) as? [Int] ?? []
        DispatchQueue.main.async { [weak self] in
            for id in saved { self?.setMirroring(CGDirectDisplayID(id), on: true) }
        }
    }

    func isMirroring(_ id: CGDirectDisplayID) -> Bool { mirroredDisplayIDs.contains(id) }

    func setMirroring(_ id: CGDirectDisplayID, on: Bool) {
        if !on {
            windows.withLock { $0.removeValue(forKey: id) }?.close()
        } else if !mirroredDisplayIDs.contains(id) {
            guard let view = mainView, let ctx = view.openGLContext,
                  let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == id }),
                  // A mirror over the visualizer's own display would just cover it.
                  screen != view.window?.screen
            else {
                logger.error("cannot mirror display \(id): no GL context, unknown screen, or it is the visualizer's own")
                return
            }
            let mirror = MirrorWindow(screen: screen, sharing: ctx)
            windows.withLock { $0[id] = mirror }
            mirror.orderFrontRegardless()
        }
        mirroredDisplayIDs = Set(windows.withLock { $0.keys })
        UserDefaults.standard.set(mirroredDisplayIDs.map { Int($0) }, forKey: AppSettingsKeys.mirrorDisplays)
    }

    /// Mirrors sit above other apps' windows while projectMac is the active app (so they
    /// fully cover the display), and drop to normal level when you switch away, so the
    /// app you switched to is visible and usable on that display.
    private func appActiveChanged() {
        let active = NSApp.isActive
        for mirror in windows.withLock({ Array($0.values) }) {
            mirror.level = active ? .floating : .normal
            if active { mirror.orderFrontRegardless() }
        }
    }

    /// Unplugged displays lose their mirror; the rest refit in case a resolution changed.
    private func screensChanged() {
        for id in mirroredDisplayIDs {
            if let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == id }) {
                windows.withLock { $0[id] }?.setFrame(screen.frame, display: true)
            } else {
                windows.withLock { $0.removeValue(forKey: id) }?.close()
            }
        }
        mirroredDisplayIDs = Set(windows.withLock { $0.keys })
    }

    /// CVDisplayLink thread, after the main view's frame is flushed (so the texture's
    /// commands are submitted before another context reads it).
    func draw(texture: GLuint, width: GLsizei, height: GLsizei) {
        let current = windows.withLock { Array($0.values) }
        for mirror in current { mirror.glView.draw(texture: texture, width: width, height: height) }
    }
}

private final class MirrorWindow: NSWindow {
    let glView: MirrorGLView

    init(screen: NSScreen, sharing mainContext: NSOpenGLContext) {
        glView = MirrorGLView(frame: NSRect(origin: .zero, size: screen.frame.size), sharing: mainContext)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        contentView = glView
        isReleasedWhenClosed = false
        level = NSApp.isActive ? .floating : .normal // see `MirrorController.appActiveChanged`
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: true)
    }

    // Keeps keyboard focus on the visualizer window.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Aspect-fills the shared scene texture. All GL happens under the context lock.
private final class MirrorGLView: NSOpenGLView {
    private var readFramebuffer: GLuint = 0
    private var backingSize = (width: GLint(1), height: GLint(1)) // under the context lock

    init(frame: NSRect, sharing mainContext: NSOpenGLContext) {
        let format = ProjectMGLView.makePixelFormat()
        super.init(frame: frame, pixelFormat: format)!
        openGLContext = NSOpenGLContext(format: format, share: mainContext)
        wantsBestResolutionOpenGLSurface = true
        // Don't block the render thread on this display's vsync as well as the main one's.
        openGLContext?.setValues([0], for: .swapInterval)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func reshape() {
        super.reshape()
        guard let ctx = openGLContext else { return }
        ctx.lock()
        ctx.update()
        let backing = convertToBacking(bounds)
        backingSize = (GLint(backing.width), GLint(backing.height))
        ctx.unlock()
    }

    func draw(texture: GLuint, width: GLsizei, height: GLsizei) {
        guard let ctx = openGLContext else { return }
        ctx.lock()
        defer { ctx.unlock() }
        ctx.makeCurrentContext()
        if readFramebuffer == 0 { glGenFramebuffers(1, &readFramebuffer) }

        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
        glFramebufferTexture2D(GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)

        // Centre-crop the source to the destination's aspect ratio.
        let (dw, dh) = (Double(backingSize.width), Double(backingSize.height))
        let (sw, sh) = (Double(width), Double(height))
        var (x0, y0, x1, y1) = (GLint(0), GLint(0), GLint(width), GLint(height))
        if sw * dh > dw * sh { // source wider than destination: crop the sides
            let cropped = sh * dw / dh
            x0 = GLint((sw - cropped) / 2)
            x1 = GLint((sw + cropped) / 2)
        } else {
            let cropped = sw * dh / dw
            y0 = GLint((sh - cropped) / 2)
            y1 = GLint((sh + cropped) / 2)
        }
        glBlitFramebuffer(
            x0, y0, x1, y1,
            0, 0, backingSize.width, backingSize.height,
            GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR)
        )
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        ctx.flushBuffer()
    }
}
