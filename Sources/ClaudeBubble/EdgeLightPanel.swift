import AppKit
import ClaudeBubbleCore
import MetalKit

/// A thin click-through strip along one screen edge, lit near the orb.
final class EdgeLightPanel: NSPanel {
    static let thickness: CGFloat = 16
    let edge: EdgeStrip.Edge
    /// Nil only where Metal isn't available (nothing is drawn then).
    let glow: EdgeGlowMetalView?

    init(edge: EdgeStrip.Edge) {
        self.edge = edge
        glow = EdgeGlowMetalView(edge: edge)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        contentView = glow ?? NSView()
    }

    override var canBecomeKey: Bool { false }

    override func orderOut(_ sender: Any?) {
        glow?.isPaused = true
        super.orderOut(sender)
    }
}

/// Owns the four edge panels and places them each tick.
final class EdgeLightController {
    private var panels: [EdgeStrip.Edge: EdgeLightPanel] = [:]
    /// Strength shown per edge, eased so the light fades in and out while dragging.
    private var shown: [EdgeStrip.Edge: Double] = [:]

    /// `orb` is the orb panel; nil (orb hidden, popping out, or the light turned off) hides everything at once.
    /// `screen` is the visible frame the light runs along; `shared` are its edges that meet another display.
    func update(orb: NSWindow?, screen: CGRect?, shared: Set<EdgeStrip.Edge>, color: SIMD3<Float>, state: BubbleState,
                opacity: Double, dt: Double) {
        guard let orb, let screen else {
            for (edge, panel) in panels where panel.isVisible { panel.orderOut(nil); shown[edge] = 0 }
            return
        }
        let centre = CGPoint(x: orb.frame.midX, y: orb.frame.midY)
        let strips = EdgeLight.strips(orbCentre: centre, orbRadius: orb.frame.width * 0.3, screen: screen, skipping: shared)
        let k = 1 - exp(-dt / 0.25)
        for edge in [EdgeStrip.Edge.left, .right, .bottom, .top] {
            let strip = strips.first { $0.edge == edge }
            let value = (shown[edge] ?? 0) + ((strip?.strength ?? 0) - (shown[edge] ?? 0)) * k
            shown[edge] = value
            guard value > 0.01 else {
                panels[edge]?.orderOut(nil)
                continue
            }
            let panel = panels[edge] ?? EdgeLightPanel(edge: edge)
            panels[edge] = panel
            guard let strip else {
                // Fading out after the orb moved away: stay where it was (even if the orb changed displays).
                if panel.isVisible { panel.glow?.strength = Float(value * opacity) } else { panel.orderOut(nil) }
                continue
            }
            let centre = strip.centre
            let length = edge == .left || edge == .right ? screen.height : screen.width
            let reach = length / 3 * 2
            let t = EdgeLightPanel.thickness
            let frame: CGRect
            switch edge {
            case .bottom: frame = CGRect(x: max(screen.minX, centre - reach), y: screen.minY, width: 0, height: t)
            case .top: frame = CGRect(x: max(screen.minX, centre - reach), y: screen.maxY - t, width: 0, height: t)
            case .left: frame = CGRect(x: screen.minX, y: max(screen.minY, centre - reach), width: t, height: 0)
            case .right: frame = CGRect(x: screen.maxX - t, y: max(screen.minY, centre - reach), width: t, height: 0)
            }
            var f = frame
            if edge == .bottom || edge == .top { f.size.width = min(screen.maxX, centre + reach) - f.minX }
            else { f.size.height = min(screen.maxY, centre + reach) - f.minY }
            guard f.width > 1, f.height > 1 else { panel.orderOut(nil); continue }
            if panel.frame != f { panel.setFrame(f, display: true) }
            if let g = panel.glow {
                let along = edge == .bottom || edge == .top ? centre - f.minX : centre - f.minY
                if abs(g.centre - Float(along)) > 0.5 { g.centre = Float(along) }
                if g.length != Float(length) { g.length = Float(length) }
                if abs(g.strength - Float(value * opacity)) > 0.005 { g.strength = Float(value * opacity) }
                if g.state != state { g.state = state }
                if g.color != color { g.color = color }
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
                panel.order(.below, relativeTo: orb.windowNumber)
                panel.glow?.resume()
            }
        }
    }
}

/// The light, drawn with Metal: a bright line on the edge with a hot near-white core and a soft glow fading inward,
/// brightest at the orb and fading along the edge. Working shimmers, needs breathes and error flickers; idle is
/// still (drawn only when something changes). In SwiftUI each frame rebuilt ~100-stop gradients and committed them
/// on the main thread, most of its time while the orb worked.
final class EdgeGlowMetalView: MTKView {
    let edge: EdgeStrip.Edge
    /// The light's centre, measured along the panel from its start (from the bottom on a side edge).
    var centre: Float = 0 { didSet { redraw() } }
    /// The edge's full length (sets the falloff).
    var length: Float = 1 { didSet { redraw() } }
    var strength: Float = 0 { didSet { redraw() } }
    var color = SIMD3<Float>(1, 1, 1) { didSet { redraw() } }
    var state: BubbleState = .idle { didSet { resume() } }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    init?(edge: EdgeStrip.Edge) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.edge = edge
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "edgeVertex")
            d.fragmentFunction = library.makeFunction(name: "edgeFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("ClaudeBubble: edge light shader setup failed: \(error)")
            return nil
        }
        super.init(frame: .zero, device: device)
        wantsLayer = true
        layer?.isOpaque = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = true
        isPaused = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Animating states run at 30fps while shown; idle draws once.
    func resume() {
        isPaused = state == .idle || window?.isVisible != true
        redraw()
    }

    private func redraw() { if isPaused { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.size
        guard size.width > 1, size.height > 1, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let t = Date().timeIntervalSinceReferenceDate
        let level: Double = switch state {
        case .working: 1
        case .needs: 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4))
        case .error: 0.8 * (Int(t * 14) % 7 == 0 ? 0.55 : 1)
        case .idle: 0.35
        }
        let side: Float = switch edge {
        case .bottom: 0
        case .top: 1
        case .left: 2
        case .right: 3
        }
        var u = EdgeUniforms(
            // The shimmer turns at 3 rad/s: wrapping time every 2π/3 × 1000 s changes nothing and keeps Float precise.
            frame: [Float(size.width), Float(size.height), Float(drawableSize.width / size.width),
                    Float(t.truncatingRemainder(dividingBy: 2000 * .pi / 3))],
            along: [centre, length, state == .working ? 1 : 0, side],
            color: SIMD4(color, strength * Float(level)))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<EdgeUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private struct EdgeUniforms {
        /// width, height (pt), backing scale, time.
        var frame: SIMD4<Float>
        /// centre, edge length, shimmering (0/1), which edge (bottom, top, left, right).
        var along: SIMD4<Float>
        /// The colour (rgb) and overall opacity.
        var color: SIMD4<Float>
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct EdgeUniforms { float4 frame; float4 along; float4 color; };
    struct QuadOut { float4 position [[position]]; };

    vertex QuadOut edgeVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        QuadOut o; o.position = float4(p * 2.0 - 1.0, 0, 1); return o;
    }

    // Premultiplied, as the SwiftUI layers composited: the inward glow, the 3pt line over it, the 1.5pt line added
    // on (plus-lighter), and a white core over that.
    fragment float4 edgeFragment(QuadOut in [[stage_in]], constant EdgeUniforms &u [[buffer(0)]]) {
        float2 p = in.position.xy / u.frame.z;
        float w = u.frame.x, h = u.frame.y;
        int side = int(u.along.w);
        // s: along the edge from the panel's start (bottom up on a side edge); d: in from the screen's edge.
        float s = side < 2 ? p.x : h - p.y;
        float d = side == 0 ? h - p.y : side == 1 ? p.y : side == 2 ? p.x : w - p.x;
        float x = s - u.along.x;
        float l = u.along.y / 3.0;
        float a = abs(x) <= 2.0 * l ? exp(-(x / l) * (x / l)) : 0.0;
        if (u.along.z > 0.5) a *= 0.8 + 0.2 * sin(abs(x) / 38.0 - u.frame.w * 3.0);
        float depth = d / 16.0;
        float m = depth <= 0.3 ? mix(1.0, 0.35, depth / 0.3) : mix(0.35, 0.0, (depth - 0.3) / 0.7);
        float3 c = u.color.rgb;
        float4 out = float4(c, 1) * a * clamp(m, 0.0, 1.0);
        if (d < 3.0) out = float4(c, 1) * a + out * (1.0 - a);
        if (d < 1.5) {
            out = min(out + float4(c, 1) * a, 1.0);
            float core = 0.35 * a;
            out = float4(1, 1, 1, 1) * core + out * (1.0 - core);
        }
        return out * u.color.a;
    }
    """
}
