import ClaudeBubbleCore
import CoreGraphics
import Metal

/// Still frame of the orb rendered offscreen with the live shaders; used for list mini orbs and the app icon.
enum OrbSnapshot {
    /// Device, compiled shaders and pipelines are built once; palette changes re-render often.
    private struct Renderer {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let quad: MTLRenderPipelineState
        let dots: MTLRenderPipelineState
        let points: MTLBuffer

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: OrbShaders.source, options: nil) else { return nil }
            func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                guard let ca = d.colorAttachments[0] else { return nil }
                ca.pixelFormat = .bgra8Unorm
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .one
                return try? device.makeRenderPipelineState(descriptor: d)
            }
            let pts = OrbGeometry.fibonacciSphere()
            guard let quad = pipeline("quadVertex", "quadFragment"),
                  let dots = pipeline("pointVertex", "pointFragment"),
                  let points = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<Float>.stride) else { return nil }
            self.device = device
            self.queue = queue
            self.quad = quad
            self.dots = dots
            self.points = points
        }
    }

    private static let shared = Renderer()

    /// `prepare` can set up the animator (a motion, layers) before the frame is taken; `steps` is how long it runs.
    static func render(state: BubbleState, size: Int, palette: OrbPalette = .agentsView, steps: Int = 90,
                       prepare: ((OrbAnimator) -> Void)? = nil) -> CGImage? {
        guard let r = shared else { return nil }
        let device = r.device, queue = r.queue, quad = r.quad, dots = r.dots, points = r.points

        // Let the wave settle into a pleasing frame.
        let animator = OrbAnimator(state: state, palette: palette, random: { 0.35 })
        prepare?(animator)
        var f = animator.step(dt: 0.016)
        for _ in 0..<steps { f = animator.step(dt: 0.016) }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        td.usage = .renderTarget
        td.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: td) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        var u = OrbUniforms(
            c1: SIMD4(f.params.c1, 0), c2: SIMD4(f.params.c2, 0), c3: SIMD4(f.params.c3, 0), halo: SIMD4(f.params.halo, 0),
            a: [f.phase, f.scale, f.glow, f.ring],
            b: [f.params.glitch, f.params.wave, f.params.bright, max(1, Float(size) / 400) * 3.2],
            c: [Float(size), Float(size), 0, 0],
            d: [0, 0, 0, -1],
            e: [-1, 0, 0, 0],
            f: [f.workA, f.workB, f.workMix, f.settle],
            g: [f.sub, f.failAge, f.skillAge, 0],
            h: SIMD4(f.tickAges, 0),
            i: SIMD4(f.tickAmps, 0)
        )
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let len = MemoryLayout<OrbUniforms>.stride
        enc.setRenderPipelineState(quad)
        enc.setFragmentBytes(&u, length: len, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.setRenderPipelineState(dots)
        enc.setVertexBytes(&u, length: len, index: 0)
        enc.setVertexBuffer(points, offset: 0, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: OrbGeometry.pointCount)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
    }
}
