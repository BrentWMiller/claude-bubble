import AppKit
import ClaudeBubbleCore
import MetalKit

final class OrbView: MTKView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?
    private var renderer: OrbRenderer?
    private var pendingClick: NSEvent?

    init(frame: NSRect, animator: OrbAnimator) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        wantsLayer = true
        layer?.isOpaque = false
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

    override func mouseDragged(with event: NSEvent) {
        guard let down = pendingClick else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        pendingClick = nil
        window?.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        if pendingClick != nil { onClick?() }
        pendingClick = nil
    }
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    private let animator: OrbAnimator
    private let queue: MTLCommandQueue
    private let quadPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let points: MTLBuffer
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
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let f = animator.step(dt: now - lastTime)
        lastTime = now
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let dpr = Float(min(view.window?.backingScaleFactor ?? 2, 2))
        let pointSize = max(1, Float(view.bounds.width) / 200) * dpr * 1.6
        var u = OrbUniforms(
            c1: SIMD4(f.params.c1, 0), c2: SIMD4(f.params.c2, 0), c3: SIMD4(f.params.c3, 0), halo: SIMD4(f.params.halo, 0),
            a: [f.phase, f.scale, f.glow, f.ring],
            b: [f.params.glitch, f.params.wave, f.params.bright, pointSize],
            c: [Float(view.drawableSize.width), Float(view.drawableSize.height), f.shakeX, 0],
            d: [f.pointer.x, f.pointer.y, f.attention, 0]
        )
        let len = MemoryLayout<OrbUniforms>.stride

        enc.setRenderPipelineState(quadPipeline)
        enc.setFragmentBytes(&u, length: len, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(pointPipeline)
        enc.setVertexBytes(&u, length: len, index: 0)
        enc.setVertexBuffer(points, offset: 0, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: OrbGeometry.pointCount)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
