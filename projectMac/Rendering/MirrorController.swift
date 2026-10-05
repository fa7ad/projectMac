import AppKit
import Synchronization

/// A rectangle of the scene texture in normalized 0...1 coordinates (origin bottom-left,
/// like the texture). `.full` is the whole scene.
struct SceneRegion: Sendable {
    var x0 = 0.0, y0 = 0.0, x1 = 1.0, y1 = 1.0
    static let full = SceneRegion()

    /// Pixel rectangle of a `sw`×`sh` scene to draw into a `dw`×`dh` destination: this
    /// region, centre-cropped to the destination's aspect ratio (aspect-fill).
    func fillRect(scene sw: Double, _ sh: Double, dest dw: Double, _ dh: Double)
        -> (x0: GLint, y0: GLint, x1: GLint, y1: GLint) {
        var (a0, b0, a1, b1) = (x0 * sw, y0 * sh, x1 * sw, y1 * sh)
        let (rw, rh) = (a1 - a0, b1 - b0)
        if rw * dh > dw * rh { // region wider than destination: crop the sides
            let mid = (a0 + a1) / 2, half = rh * dw / dh / 2
            (a0, a1) = (mid - half, mid + half)
        } else {
            let mid = (b0 + b1) / 2, half = rw * dh / dw / 2
            (b0, b1) = (mid - half, mid + half)
        }
        return (GLint(a0.rounded()), GLint(b0.rounded()), GLint(a1.rounded()), GLint(b1.rounded()))
    }
}

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

    // Span mode (Display > Span Across Displays): the scene is one canvas covering every
    // display side by side, each display showing its slice. Written on the main thread,
    // read by the render thread (`ProjectMGLView`) for the canvas size and its own slice.
    private let spanState = Mutex<(canvas: (width: Int, height: Int), main: SceneRegion)?>(nil)
    private var spanWindows: [MirrorWindow] = [] // main thread
    private var spanSignature = ""
    /// Fired on the main thread when span mode turns on/off, for the menu checkmark.
    var onSpanChanged: ((Bool) -> Void)?

    var isSpanning: Bool { spanState.withLock { $0 != nil } }
    /// Pixel size of the whole canvas while spanning (before render scale), else nil.
    var spanCanvas: (width: Int, height: Int)? { spanState.withLock { $0?.canvas } }
    /// The slice the main window shows.
    var mainRegion: SceneRegion { spanState.withLock { $0?.main } ?? .full }

    /// Called from `ProjectMGLView.prepareOpenGL`, once its context exists.
    func attach(mainView: ProjectMGLView) {
        self.mainView = mainView
        // Re-slice when displays are added/removed/rearranged or the main window changes display.
        let relayout: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.relayoutSpan() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil, using: relayout)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: relayout)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: nil) { [weak self] n in
            let isMain = (n.object as? NSWindow) === self?.mainView?.window
            if isMain { DispatchQueue.main.async { self?.relayoutSpan() } }
        }
    }

    @MainActor
    func setSpan(_ on: Bool) {
        spanSignature = ""
        guard on else { return endSpan() }
        buildSpan()
    }

    @MainActor
    private func relayoutSpan() {
        guard isSpanning else { return }
        buildSpan()
    }

    @MainActor
    private func endSpan() {
        let was = isSpanning
        spanWindows.forEach { $0.close() }
        spanWindows = []
        spanState.withLock { $0 = nil }
        if was { mainView?.reshape() }
        onSpanChanged?(false)
    }

    /// Slices the canvas per `AppSettingsKeys.spanLayout`. Every layout is a rectangle per
    /// display in some common unit; the canvas is the bounding box of those, at the pixel
    /// density of the sharpest display, and a display's region is its rectangle within it.
    @MainActor
    private func buildSpan() {
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard let mainView, let mainScreen = mainView.window?.screen, screens.count > 1 else { return endSpan() }
        let layout = UserDefaults.standard.string(forKey: AppSettingsKeys.spanLayout) ?? "displays"
        let signature = "\(layout)|\(screens.map(\.frame))|\(mainScreen.frame)"
        guard signature != spanSignature else { return }
        spanSignature = signature
        spanWindows.forEach { $0.close() }
        spanWindows = []

        let rects = Self.spanRects(for: screens, layout: layout)
        let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let pixelsPerUnit = zip(screens, rects).map { $0.frame.width * $0.backingScaleFactor / $1.width }.max()!
        let canvas = (width: Int((bounds.width * pixelsPerUnit).rounded()), height: Int((bounds.height * pixelsPerUnit).rounded()))
        let slices = zip(screens, rects).map { screen, r in
            (screen, SceneRegion(x0: (r.minX - bounds.minX) / bounds.width, y0: (r.minY - bounds.minY) / bounds.height,
                                 x1: (r.maxX - bounds.minX) / bounds.width, y1: (r.maxY - bounds.minY) / bounds.height))
        }
        let mainRegion = slices.first { $0.0 == mainScreen }?.1 ?? .full
        spanState.withLock { $0 = (canvas, mainRegion) }

        if let ctx = mainView.openGLContext {
            for (screen, region) in slices where screen != mainScreen {
                let mirror = makeMirror(sharing: ctx)
                mirror.glView.setRegion(region)
                mirror.onExitSpan = { [weak self] in self?.setSpan(false) }
                mirror.setFrameOrigin(screen.frame.origin)
                mirror.makeKeyAndOrderFront(nil)
                mirror.enterBorderless(on: screen)
                spanWindows.append(mirror)
            }
        }
        mainView.reshape() // re-sizes the scene to the canvas
        onSpanChanged?(true)
    }

    /// One rectangle per screen (y up), in a unit shared by all of them.
    /// - `displays`: side by side at equal height, each at its own aspect ratio. Nothing is
    ///   cropped or left empty; arrangement and physical size are ignored.
    /// - `arrangement`: the frames from System Settings > Displays, in points, so vertical
    ///   offsets and gaps are honoured and uncovered canvas is simply not shown. Points are
    ///   not physical: a display in a scaled mode shows things bigger or smaller.
    private static func spanRects(for screens: [NSScreen], layout: String) -> [CGRect] {
        switch layout {
        case "arrangement":
            return screens.map(\.frame)
        default:
            var x = 0.0
            return screens.map { screen in
                let aspect = screen.frame.width / screen.frame.height
                defer { x += aspect }
                return CGRect(x: x, y: 0, width: aspect, height: 1)
            }
        }
    }

    @MainActor
    private func makeMirror(sharing ctx: NSOpenGLContext) -> MirrorWindow {
        let mirror = MirrorWindow(sharing: ctx)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: mirror, queue: .main
        ) { [weak self, weak mirror] _ in
            self?.windows.withLock { list in list.removeAll { $0 === mirror } }
        }
        windows.withLock { $0.append(mirror) }
        return mirror
    }

    @MainActor
    func openMirrorWindow() {
        guard let ctx = mainView?.openGLContext else { return }
        let mirror = makeMirror(sharing: ctx)
        // Start on another display if there is one, so it only needs fullscreening.
        if let other = NSScreen.screens.first(where: { $0 != mainView?.window?.screen }) {
            let frame = other.visibleFrame
            mirror.setFrameOrigin(NSPoint(x: frame.midX - mirror.frame.width / 2,
                                          y: frame.midY - mirror.frame.height / 2))
        }
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

    /// Set on span-mode windows: leaving fullscreen there means leaving span mode.
    var onExitSpan: (() -> Void)?

    /// Set while in borderless fullscreen: what to put back on exit.
    private var borderless: (frame: NSRect, style: NSWindow.StyleMask, level: NSWindow.Level)?

    // A borderless window refuses key status by default, which would kill the F key.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// With the "borderless fullscreen" setting: a plain window covering the whole screen
    /// frame (menu bar, Dock and notch area included) instead of a native Space.
    override func toggleFullScreen(_ sender: Any?) {
        if let onExitSpan {
            onExitSpan()
        } else if let saved = borderless {
            borderless = nil
            styleMask = saved.style
            level = saved.level
            setFrame(saved.frame, display: true)
            makeFirstResponder(glView)
        } else if UserDefaults.standard.bool(forKey: AppSettingsKeys.borderlessFullscreen),
                  !styleMask.contains(.fullScreen), let screen {
            enterBorderless(on: screen)
        } else {
            super.toggleFullScreen(sender)
        }
    }

    func enterBorderless(on screen: NSScreen) {
        borderless = (frame, styleMask, level)
        styleMask = .borderless
        level = .mainMenu + 1
        setFrame(screen.frame, display: true)
        makeFirstResponder(glView) // changing styleMask drops first responder, so F would go nowhere
    }

    // Titled windows get pushed below the menu bar; the borderless one must not be.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        borderless == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}

/// Aspect-fills the shared scene texture. All GL happens under the context lock.
private final class MirrorGLView: NSOpenGLView {
    private var readFramebuffer: GLuint = 0
    private var expandPass: ExpandPass? // HDR only; created lazily in this view's context
    private var backingSize = (width: GLint(1), height: GLint(1)) // under the context lock
    private var region = SceneRegion.full // under the context lock

    func setRegion(_ r: SceneRegion) {
        guard let ctx = openGLContext else { return }
        ctx.lock()
        region = r
        ctx.unlock()
    }

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

    private let cursorHider = CursorAutoHider()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        cursorHider.updateTracking(on: self)
    }

    override func mouseMoved(with event: NSEvent) { cursorHider.poke(self) }

    override func mouseDown(with event: NSEvent) {
        cursorHider.poke(self)
        if event.clickCount == 2 { window?.toggleFullScreen(nil) } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        cursorHider.poke(self)
        if event.charactersIgnoringModifiers?.lowercased() == "f" {
            window?.toggleFullScreen(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func reshape() {
        super.reshape()
        updateBackingSize()
    }

    // `reshape` can run before the view has a window/screen, which measures at 1x; these
    // re-measure once the real backing scale is known (and when it changes).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingSize()
    }

    private func updateBackingSize() {
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
        // This view's slice of the scene, centre-cropped to the destination's aspect ratio.
        let (sw, sh) = (Double(width), Double(height))
        let r = region.fillRect(scene: sw, sh, dest: Double(backingSize.width), Double(backingSize.height))

        if let expandPass {
            expandPass.draw(texture: texture,
                            uvOffset: (Float(r.x0) / Float(width), Float(r.y0) / Float(height)),
                            uvScale: (Float(r.x1 - r.x0) / Float(width), Float(r.y1 - r.y0) / Float(height)),
                            gain: gain, width: backingSize.width, height: backingSize.height)
        } else {
            if readFramebuffer == 0 { glGenFramebuffers(1, &readFramebuffer) }
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
            glFramebufferTexture2D(GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
            glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
            glBlitFramebuffer(
                r.x0, r.y0, r.x1, r.y1,
                0, 0, backingSize.width, backingSize.height,
                GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR)
            )
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        ctx.flushBuffer()
    }
}
