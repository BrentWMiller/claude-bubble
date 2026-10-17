import AppKit
import ClaudeBubbleCore
import MetalKit
import SwiftUI

/// The island's glow drawn with Metal: the same picture as `IslandGlowView` (its two radial glows, edge strip and
/// dot-wave) and `IslandRim`, worked out on the GPU. In SwiftUI each 20-30fps frame rebuilt and committed the
/// island's display list on the main thread (most of the app's idle CPU); here a frame is a few uniforms and a draw.
/// Offscreen snapshots, which can't draw Metal, still use the SwiftUI views.
struct GlowUniforms {
    /// width, height (pt), backing scale, wave time.
    var frame: SIMD4<Float>
    /// orb x, y (pt, top-left origin), r0 (wave falloff radius), fan front (pt; huge when not fanning).
    var orb: SIMD4<Float>
    /// The wave's colour (rgb) and its amplitude.
    var to: SIMD4<Float>
    /// The colour it's fanning away from (rgb) and the fan's progress (1 = done).
    var from: SIMD4<Float>
    /// The glows' blended colour (rgb) and the breath (0...1).
    var mixed: SIMD4<Float>
    /// Soft glow opacity, dotted glow opacity, edge strip on (0/1), docked at the bottom (0/1).
    var layers: SIMD4<Float>
    /// Corner radii: top-left, top-right, bottom-right, bottom-left (pt).
    var radii: SIMD4<Float>
    /// Orb size (pt), rim opacity, grid columns, glow pulse radius scale.
    var misc: SIMD4<Float>
}

enum GlowShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlowUniforms { float4 frame; float4 orb; float4 to; float4 from; float4 mixed; float4 layers; float4 radii; float4 misc; };

    struct QuadOut { float4 position [[position]]; };

    vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        QuadOut o; o.position = float4(p * 2.0 - 1.0, 0, 1); return o;
    }

    // Coverage of the pill (rounded on its open side) at p (pt, top-left origin), antialiased over a pixel.
    static float pill(float2 p, constant GlowUniforms &u, float inset) {
        float2 half_ = u.frame.xy * 0.5 - inset;
        float2 c = p - u.frame.xy * 0.5;
        float r = c.x > 0 ? (c.y > 0 ? u.radii.z : u.radii.y) : (c.y > 0 ? u.radii.w : u.radii.x);
        r = max(0.0, r - inset);
        float2 q = abs(c) - half_ + r;
        float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
        return clamp(0.5 - d * u.frame.z, 0.0, 1.0);
    }

    // A gradient's alpha at t through stops (location, alpha), clear past the last.
    static float ramp(float t, float2 a, float2 b, float2 c, float2 d, float2 e) {
        if (t <= a.x) return a.y;
        if (t <= b.x) return mix(a.y, b.y, (t - a.x) / max(b.x - a.x, 1e-5));
        if (t <= c.x) return mix(b.y, c.y, (t - b.x) / max(c.x - b.x, 1e-5));
        if (t <= d.x) return mix(c.y, d.y, (t - c.x) / max(d.x - c.x, 1e-5));
        if (t <= e.x) return mix(d.y, e.y, (t - d.x) / max(e.x - d.x, 1e-5));
        return e.y;
    }

    // The two glows behind the orb and the edge strip, in the glows' blended colour (premultiplied).
    fragment float4 glowFragment(QuadOut in [[stage_in]], constant GlowUniforms &u [[buffer(0)]]) {
        float2 p = in.position.xy / u.frame.z;
        float2 o = u.orb.xy;
        float2 dv = p - o;
        float d = length(dv);
        float r = u.misc.w;
        float breath = u.mixed.w;
        float inBox = (abs(dv.x) <= 220.0 && abs(dv.y) <= 220.0) ? 1.0 : 0.0;
        float t = d / 311.0;
        float soft = ramp(t, float2(0, 0.35), float2(0.14 * r, 0.1), float2(0.36 * r, 0), float2(0.36 * r, 0), float2(0.36 * r, 0));
        float aS = soft * u.layers.x * inBox;
        float dotted = ramp(t, float2(0, 0.9), float2(0.09 * r, 0.55), float2(0.22 * r, 0.2), float2(0.36 * r, 0.05), float2(0.5 * r, 0));
        // Seen through a 4pt dot grid laid from the glow box's corner: a dot solid to 1.05pt, soft to 1.6pt.
        float2 cell = fmod(p - (o - 220.0) + 4000.0, 4.0) - 2.0;
        float dd = length(cell);
        float mask = dd <= 1.05 ? 1.0 : (dd >= 1.6 ? 0.0 : 1.0 - (dd - 1.05) / 0.55);
        float aI = dotted * mask * u.layers.y * inBox;
        float aE = 0;
        if (u.layers.z > 0.5 && p.x <= 26.0) {
            float along = ramp(p.x / 26.0, float2(0, 0.55 + 0.25 * breath), float2(1.5 / 26.0, 0.5 + 0.2 * breath),
                               float2(3.0 / 26.0, 0.22 + 0.12 * breath), float2(12.0 / 26.0, 0.06), float2(1, 0));
            float y = u.layers.w > 0.5 ? u.frame.y - p.y : p.y;
            float fade = y <= 48.0 ? 1.0 : (y >= 140.0 ? 0.0 : 1.0 - (y - 48.0) / 92.0);
            aE = along * fade;
        }
        float a = 1.0 - (1.0 - aS) * (1.0 - aI) * (1.0 - aE);
        a *= pill(p, u, 0.0);
        return float4(u.mixed.rgb * a, a);
    }

    // The pill's 1pt inner rim (drawn above the island's content).
    fragment float4 rimFragment(QuadOut in [[stage_in]], constant GlowUniforms &u [[buffer(0)]]) {
        float2 p = in.position.xy / u.frame.z;
        float a = (pill(p, u, 0.0) - pill(p, u, 1.0)) * u.misc.y;
        return float4(u.mixed.rgb * a, a);
    }

    struct DotOut {
        float4 position [[position]];
        float pointSize [[point_size]];
        float diameter;    // the point's size in pixels again: [[point_size]] doesn't reach the fragment stage
        float radius;      // pt
        float4 color;      // premultiplied
    };

    // One dot of the wave per instance: the design's 4pt grid, each dot pushed out from the orb and lit by two
    // travelling waves (IslandGlowView.drawWaves, line for line).
    vertex DotOut dotVertex(uint iid [[instance_id]], constant GlowUniforms &u [[buffer(0)]]) {
        DotOut out;
        out.position = float4(-2, -2, 0, 1);
        out.pointSize = 0;
        out.diameter = 0;
        out.radius = 0;
        out.color = float4(0);
        uint cols = uint(u.misc.z);
        float gx = 2.0 + 4.0 * float(iid % cols), gy = 2.0 + 4.0 * float(iid / cols);
        if (gx >= u.frame.x || gy >= u.frame.y) return out;
        float tt = u.frame.w, amp = u.to.w, oz = u.misc.x, r0 = u.orb.z, front = u.orb.w, fan = u.from.w;
        float breath = u.mixed.w;
        float dx = gx - u.orb.x, dy = gy - u.orb.y;
        float d0 = sqrt(dx * dx + dy * dy);
        if (d0 < oz / 2 + 1) return out;
        float an = atan2(dy, dx);
        float warp = sin(an * 3 + tt * 0.45) * 0.55 + sin(gx * 0.019 - gy * 0.043 + tt * 0.35) * 0.7;
        float w1 = sin(d0 * 0.085 - tt * 2.3 + warp), w2 = sin(d0 * 0.045 - tt * 1.2 + an * 2 + warp * 0.5);
        float patch_ = 0.5 + 0.5 * (0.5 + 0.5 * sin(an * 2.3 + tt * 0.3) * sin(d0 * 0.03 - tt * 0.2));
        float born = min(1.0, (d0 - oz / 2 - 1) / 16);
        float crest = (pow(0.5 + 0.5 * w1, 2.6) * 0.9 + pow(0.5 + 0.5 * w2, 3.0) * 0.3) * patch_ * born;
        float push = crest * 1.8 + sin(d0 * 0.06 - tt * 1.6) * 0.5;
        float px = gx + cos(an) * push, py = gy + sin(an) * push, dist = d0 + push;
        float fall = max(0.0, 1 - dist / r0);
        if (fall <= 0) return out;
        float a = min(1.0, fall * fall * (0.16 + crest * amp) * (0.7 + 0.3 * breath));
        float edge = front < 1e8 ? exp(-pow((d0 - front + 8) / 10, 2.0)) * (1 - fan) : 0.0;
        a = min(1.0, a + edge * 0.5);
        if (a < 0.02) return out;
        float rad = 0.6 + crest * 0.6 + edge * 0.5;
        // Drawn in 8 brightness steps, as the SwiftUI version batches its paths.
        float stepped = (min(7.0, floor(a * 8)) + 0.75) / 8;
        float3 rgb = d0 < front ? u.to.rgb : u.from.rgb;
        out.position = float4(px / u.frame.x * 2 - 1, 1 - py / u.frame.y * 2, 0, 1);
        out.pointSize = (rad * 2 + 2) * u.frame.z;
        out.diameter = out.pointSize;
        out.radius = rad;
        out.color = float4(rgb * stepped, stepped);
        return out;
    }

    fragment float4 dotFragment(DotOut in [[stage_in]], float2 pc [[point_coord]], constant GlowUniforms &u [[buffer(0)]]) {
        float d = length(pc - 0.5) * in.diameter;               // pixels from the centre
        float cover = clamp(in.radius * u.frame.z - d + 0.5, 0.0, 1.0);
        cover *= pill(in.position.xy / u.frame.z, u, 0.0);
        return in.color * cover;
    }
    """
}

/// One of the island's Metal layers: the glow (behind the content) or the rim (above it). Never takes the mouse.
final class GlowMetalView: MTKView {
    enum Kind { case glow, rim }

    /// What it draws from, kept current by `GlowHost`.
    var model: IslandModel?
    var palette: OrbPalette = .agentsView
    var orbCentre: CGPoint = .zero
    var edge = true
    var waves = true
    private var renderer: GlowRenderer?

    init?(kind: Kind) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        super.init(frame: .zero, device: device)
        wantsLayer = true
        layer?.isOpaque = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 20
        guard let renderer = GlowRenderer(view: self, kind: kind) else { return nil }
        self.renderer = renderer
        delegate = renderer
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GlowRenderer: NSObject, MTKViewDelegate {
    private let kind: GlowMetalView.Kind
    private let queue: MTLCommandQueue
    private let quad: MTLRenderPipelineState
    private let dots: MTLRenderPipelineState?

    init?(view: MTKView, kind: GlowMetalView.Kind) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        self.kind = kind
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: GlowShaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = view.colorPixelFormat
                ca.isBlendingEnabled = true
                // Premultiplied source-over, like SwiftUI's fills.
                ca.sourceRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            quad = try pipeline("quadVertex", kind == .glow ? "glowFragment" : "rimFragment")
            dots = kind == .glow ? try pipeline("dotVertex", "dotFragment") : nil
        } catch {
            NSLog("ClaudeBubble: glow shader setup failed: \(error)")
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let view = view as? GlowMetalView, let model = view.model else { return }
        if kind == .glow { PerfMeter.shared.count(.glowFrame) }
        let size = view.bounds.size
        guard size.width > 1, size.height > 1,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        // As IslandGlowView and IslandRim work them out each frame.
        let now = Date().timeIntervalSinceReferenceDate
        let media = CACurrentMediaTime()
        let fast = model.state == .needs || model.state == .error
        view.preferredFramesPerSecond = fast ? 30 : 20
        let breath = 0.5 + 0.5 * sin(now * (fast ? 4.2 : 1.7))
        let kick = min(1, model.ticks.reduce(0) { $0 + exp(-(media - $1) * 7) })
        let idle = model.state == .idle && model.mode != .done
        let pace = (idle ? 0.45 : fast ? 1.35 : 1) * (1 + 0.5 * kick)
        let fan = model.colors(palette: view.palette, at: media)
        let eased = 1 - pow(1 - fan.progress, 3)
        let mixed = fan.from + (fan.to - fan.from) * eased
        let r0 = max(Double(size.width) * 0.9, 160)
        let front = fan.progress < 1 ? fan.progress * (r0 * 1.15 + 20) : 1e9
        let amp = (idle ? 0.45 : 1) * (1 + 0.6 * kick) * 1.8
        let tt = now * IslandGlowView.waveSpeed(idle: idle, fast: fast)
        let scale = view.drawableSize.width / size.width
        let R = Float(IslandLayout.cornerRadius)
        let radii: SIMD4<Float> = switch model.dock {
        case .top: [0, 0, R, R]
        case .bottom: [R, R, 0, 0]
        case .left: [0, R, R, 0]
        case .right: [R, 0, 0, R]
        }
        let cols = Int((size.width - 2) / 4) + 1, rows = Int((size.height - 2) / 4) + 1
        func f3(_ v: SIMD3<Double>, _ w: Double) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        var u = GlowUniforms(
            // Every rate the waves turn at is a multiple of 0.05, so wrapping time every 40π changes nothing on screen
            // and keeps Float precise (seconds since 2001 don't fit).
            frame: [Float(size.width), Float(size.height), Float(scale), Float(tt.truncatingRemainder(dividingBy: 40 * .pi))],
            orb: [Float(view.orbCentre.x), Float(view.orbCentre.y), Float(r0), Float(front)],
            to: f3(fan.to, amp), from: f3(fan.from, fan.progress), mixed: f3(mixed, breath),
            layers: [Float(min(1, (0.5 + 0.3 * breath) * pace)), Float(min(1, (0.6 + 0.3 * breath) * pace)),
                     view.edge ? 1 : 0, model.dock == .bottom ? 1 : 0],
            radii: radii,
            misc: [Float(IslandLayout.orbSize), Float(0.06 + 0.04 * breath), Float(cols), Float(1 + 0.12 * breath + 0.1 * kick)])
        enc.setRenderPipelineState(quad)
        enc.setFragmentBytes(&u, length: MemoryLayout<GlowUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let dots, view.waves {
            enc.setRenderPipelineState(dots)
            enc.setVertexBytes(&u, length: MemoryLayout<GlowUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<GlowUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1, instanceCount: cols * rows)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// A Metal glow layer in the island's SwiftUI tree.
struct GlowHost: NSViewRepresentable {
    let kind: GlowMetalView.Kind
    let model: IslandModel
    let palette: OrbPalette
    var orbCentre: CGPoint = .zero
    var edge = true
    var waves = true

    func makeNSView(context: Context) -> NSView {
        guard let view = GlowMetalView(kind: kind) else { return NSView() }
        model.glowLayers.add(view)
        view.isPaused = !model.rendering
        update(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? GlowMetalView { update(view) }
    }

    private func update(_ view: GlowMetalView) {
        view.model = model
        view.palette = palette
        view.orbCentre = orbCentre
        view.edge = edge
        view.waves = waves
    }
}
