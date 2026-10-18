import AppKit
import ClaudeBubbleCore
import MetalKit

final class OrbView: MTKView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?
    /// The island's orb stays put; only the floating orb drags its window.
    var allowsDrag = true
    /// The island's orb leaves the mouse to the island around it (which handles clicks and dragging).
    var passesMouseThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { passesMouseThrough ? nil : super.hitTest(point) }
    /// Tiny orbs (the island's): finer dots and a softer glow, ring and brightness, as the design's `crisp` does.
    var crisp = false
    /// Squashes against the screen's edges like liquid (the floating orb; not the island's).
    var squashesAtEdges = false
    private var renderer: OrbRenderer?
    private var pendingClick: NSEvent?
    /// The centre guides shown while dragging, and the snap to the screen's middle.
    var guides: SnapGuidePanel?
    private var snap = SnapGuide()

    init(frame: NSRect, animator: OrbAnimator) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        wantsLayer = true
        layer?.isOpaque = false
        // When the window resizes (flying between styles, quiet), the last frame stays its size, centred, until the
        // next is drawn; stretched, a small orb's frame flashed up as a full-size orb.
        layer?.contentsGravity = .center
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 60
        renderer = OrbRenderer(view: self, animator: animator)
        delegate = renderer
        if renderer == nil {
            isPaused = true
            NSLog("ClaudeBubble: Metal unavailable; orb disabled")
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A press becomes a drag once it moves a few points; otherwise it's a click.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {   // Control-click is a right-click on macOS
            onRightClick?(event, self)
            return
        }
        pendingClick = event
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event, self) }

    /// Where the pointer and the window started a drag (screen space). Our own drag, not the system's, so the
    /// orb can hang partly off the screen's edges.
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    override func mouseDragged(with event: NSEvent) {
        guard let window, allowsDrag else { return }
        if let down = pendingClick {
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 9 else { return }
            pendingClick = nil
            dragStart = (window.convertPoint(toScreen: down.locationInWindow), window.frame.origin)
        }
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        var wanted = CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        guard let screen = BubblePanel.screen(nearest: mouse) else { return }
        let side = window.frame.width, centre = screen.visibleFrame.midX
        // Snap to the middle of the screen, with a guide either side of the orb itself (not its glow).
        wanted.x = snap.apply(wanted.x + side / 2, centre: centre) - side / 2
        guides?.show(on: screen.frame, axis: .vertical, at: SnapGuide.lines(centre: centre, extent: side * 0.6),
                     snapped: snap.snapped, below: window)
        window.setFrameOrigin(BubblePlacement.clampedOrigin(wanted, side: side, screen: screen.frame,
                                                            visible: screen.visibleFrame))
    }

    override func mouseUp(with event: NSEvent) {
        if pendingClick != nil { onClick?() }
        pendingClick = nil
        dragStart = nil
        snap.reset()
        guides?.hide()
    }
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    private let animator: OrbAnimator
    private let queue: MTLCommandQueue
    private let quadPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private var points: MTLBuffer
    private var pointCount = OrbGeometry.pointCount
    private let device: MTLDevice
    private var lastTime = CACurrentMediaTime()

    init?(view: MTKView, animator: OrbAnimator) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        let pts = OrbGeometry.fibonacciSphere()
        guard let points = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<Float>.stride) else { return nil }
        do {
            let library = try device.makeLibrary(source: OrbShaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = view.colorPixelFormat
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .one
                return try device.makeRenderPipelineState(descriptor: d)
            }
            quadPipeline = try pipeline("quadVertex", "quadFragment")
            pointPipeline = try pipeline("pointVertex", "pointFragment")
        } catch {
            NSLog("ClaudeBubble: shader setup failed: \(error)")
            return nil
        }
        self.animator = animator
        self.queue = queue
        self.points = points
        self.device = device
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var squash = EdgeSquash.Spring()

    /// How far the screen's edges are from the orb (in its radii, as drawn), springing toward where they are now.
    /// Far for an orb that doesn't squash, or one flying between styles.
    private func edgeSquash(_ view: MTKView, scale: Float, dt: Float) -> SIMD4<Float> {
        var target = SIMD4<Float>(repeating: EdgeSquash.far)
        if (view as? OrbView)?.squashesAtEdges == true, let window = view.window as? BubblePanel, !window.isFlying {
            let frame = window.frame
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            if let screen = BubblePanel.screen(nearest: centre) {
                let others = NSScreen.screens.filter { $0 != screen }.map(\.frame)
                target = EdgeSquash.edges(centre: centre, radius: frame.width * 0.3 * CGFloat(max(scale, 0.05)),
                                          screen: screen.frame, top: screen.visibleFrame.maxY,
                                          shared: EdgeLight.sharedEdges(of: screen.frame, among: others))
            }
        }
        squash.step(toward: target, dt: dt)
        return squash.value
    }

    func draw(in view: MTKView) {
        PerfMeter.shared.count(.orbFrame)
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        let f = animator.step(dt: dt)
        lastTime = now
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let dpr = Float(min(view.window?.backingScaleFactor ?? 2, 2))
        let px = Float(view.bounds.width)
        let crisp = (view as? OrbView)?.crisp ?? false
        let cr: Float = crisp && px < 120 ? px / 120 : 1
        // A big orb gets more dots rather than bigger ones.
        let wanted = OrbGeometry.pointCount(diameter: Double(px) * 0.6)
        if wanted != pointCount {
            let pts = OrbGeometry.fibonacciSphere(count: wanted)
            if let buffer = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<Float>.stride) {
                points = buffer
                pointCount = wanted
            }
        }
        // Dots sized for the orb as drawn: shrunk (quiet, popping in or out), they shrink too, or they'd pile up.
        let dotPx = Float(OrbGeometry.dotSizingSide(Double(px) * Double(min(1, f.scale))))
        let pointSize = (crisp ? max(0.42, min(1, dotPx / 200)) : max(1, dotPx / 200)) * dpr * 1.6
        var u = OrbUniforms(
            c1: SIMD4(f.params.c1, 0), c2: SIMD4(f.params.c2, 0), c3: SIMD4(f.params.c3, 0), halo: SIMD4(f.params.halo, 0),
            a: [f.phase, f.scale, f.glow * (0.35 + 0.65 * cr), f.ring * (0.6 + 0.4 * cr)],
            b: [f.params.glitch, f.params.wave, f.params.bright * (0.75 + 0.25 * cr), pointSize],
            c: [Float(view.drawableSize.width), Float(view.drawableSize.height), f.shakeX, 0],
            d: [f.pointer.x, f.pointer.y, f.attention, f.completion],
            e: [f.pop, f.pull, f.pullAngle, 0],
            f: [f.workA, f.workB, f.workMix, f.settle],
            g: [f.sub, f.failAge, f.skillAge, 0],
            h: SIMD4(f.tickAges, 0),
            i: SIMD4(f.tickAmps, 0),
            j: SIMD4(f.fanFrom.c1, 0), k: SIMD4(f.fanFrom.c2, 0), l: SIMD4(f.fanFrom.c3, 0), m: SIMD4(f.fanFrom.halo, 0),
            n: [f.fan, 0, 0, 0],
            o: edgeSquash(view, scale: f.scale, dt: Float(dt))
        )
        let len = MemoryLayout<OrbUniforms>.stride

        enc.setRenderPipelineState(quadPipeline)
        enc.setFragmentBytes(&u, length: len, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(pointPipeline)
        enc.setVertexBytes(&u, length: len, index: 0)
        enc.setVertexBuffer(points, offset: 0, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
