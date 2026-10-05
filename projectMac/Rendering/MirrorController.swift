import AppKit
import Synchronization

/// Mirrors the visualizer into extra ordinary windows: "New Mirror Window" opens one you
/// can drag to another display and fullscreen like any window. Each window's GL view has
/// its own context *sharing* the main one's objects, so it can sample `ProjectMGLView`'s
/// scene texture. The scene is rendered once; every mirror aspect-fills a blit of it, so
/// presets, audio and OSC stay single.
///
/// Main thread: window lifecycle. CVDisplayLink thread: `draw`, which only takes a
/// snapshot of `windows` and then the per-context lock.
final class MirrorController: @unchecked Sendable {
    private let windows = Mutex<[MirrorWindow]>([])
    private weak var mainView: ProjectMGLView?

    /// Called from `ProjectMGLView.prepareOpenGL`, once its context exists.
    func attach(mainView: ProjectMGLView) {
        self.mainView = mainView
    }

    func openMirrorWindow() {
        guard let ctx = mainView?.openGLContext else { return }
        let mirror = MirrorWindow(sharing: ctx)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: mirror, queue: .main
        ) { [weak self, weak mirror] _ in
            self?.windows.withLock { list in list.removeAll { $0 === mirror } }
        }
        // Start on another display if there is one, so it only needs fullscreening.
        if let other = NSScreen.screens.first(where: { $0 != mainView?.window?.screen }) {
            let frame = other.visibleFrame
            mirror.setFrameOrigin(NSPoint(x: frame.midX - mirror.frame.width / 2,
                                          y: frame.midY - mirror.frame.height / 2))
        }
        windows.withLock { $0.append(mirror) }
        mirror.makeKeyAndOrderFront(nil)
    }

    /// CVDisplayLink thread, after the main view's frame is flushed (so the texture's
    /// commands are submitted before another context reads it).
    func draw(texture: GLuint, width: GLsizei, height: GLsizei, gain: Float) {
        let current = windows.withLock { $0 }
        for mirror in current { mirror.glView.draw(texture: texture, width: width, height: height, gain: gain) }
    }
}

private final class MirrorWindow: NSWindow {
    let glView: MirrorGLView

    init(sharing mainContext: NSOpenGLContext) {
        let size = NSSize(width: 960, height: 540)
        glView = MirrorGLView(frame: NSRect(origin: .zero, size: size), sharing: mainContext)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "projectMac Mirror"
        contentView = glView
        contentAspectRatio = size
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenPrimary]
        if HDR.isActive { colorSpace = .extendedSRGB }
        center()
    }
}

/// Aspect-fills the shared scene texture. All GL happens under the context lock.
private final class MirrorGLView: NSOpenGLView {
    private var readFramebuffer: GLuint = 0
    private var expandPass: ExpandPass? // HDR only; created lazily in this view's context
    private var backingSize = (width: GLint(1), height: GLint(1)) // under the context lock

    init(frame: NSRect, sharing mainContext: NSOpenGLContext) {
        let format = ProjectMGLView.makePixelFormat()
        super.init(frame: frame, pixelFormat: format)!
        openGLContext = NSOpenGLContext(format: format, share: mainContext)
        wantsBestResolutionOpenGLSurface = true
        wantsExtendedDynamicRangeOpenGLSurface = HDR.isActive
        // Don't block the render thread on this display's vsync as well as the main one's.
        openGLContext?.setValues([0], for: .swapInterval)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.toggleFullScreen(nil) } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "f" {
            window?.toggleFullScreen(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func reshape() {
        super.reshape()
        guard let ctx = openGLContext else { return }
        ctx.lock()
        ctx.update()
        let backing = convertToBacking(bounds)
        backingSize = (GLint(backing.width), GLint(backing.height))
        ctx.unlock()
    }

    func draw(texture: GLuint, width: GLsizei, height: GLsizei, gain: Float) {
        guard let ctx = openGLContext else { return }
        ctx.lock()
        defer { ctx.unlock() }
        ctx.makeCurrentContext()
        if HDR.isActive && expandPass == nil { expandPass = ExpandPass() }
        // Centre-crop the source to the destination's aspect ratio.
        let (dw, dh) = (Double(backingSize.width), Double(backingSize.height))
        let (sw, sh) = (Double(width), Double(height))
        var (x0, y0, x1, y1) = (0.0, 0.0, sw, sh)
        if sw * dh > dw * sh { // source wider than destination: crop the sides
            let cropped = sh * dw / dh
            x0 = (sw - cropped) / 2
            x1 = (sw + cropped) / 2
        } else {
            let cropped = sw * dh / dw
            y0 = (sh - cropped) / 2
            y1 = (sh + cropped) / 2
        }

        if let expandPass {
            expandPass.draw(texture: texture,
                            uvOffset: (Float(x0 / sw), Float(y0 / sh)),
                            uvScale: (Float((x1 - x0) / sw), Float((y1 - y0) / sh)),
                            gain: gain, width: backingSize.width, height: backingSize.height)
        } else {
            if readFramebuffer == 0 { glGenFramebuffers(1, &readFramebuffer) }
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
            glFramebufferTexture2D(GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
            glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
            glBlitFramebuffer(
                GLint(x0), GLint(y0), GLint(x1), GLint(y1),
                0, 0, backingSize.width, backingSize.height,
                GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR)
            )
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        ctx.flushBuffer()
    }
}
