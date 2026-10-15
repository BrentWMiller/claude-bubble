// Renders the working-state orb with the app's Metal shaders onto a macOS icon tile.
// Usage: make-icon.sh (compiles this with the shader + core sources).
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct Uniforms { var c1, c2, c3, halo, a, b, c: SIMD4<Float> }

func renderOrb(size: Int) -> CGImage {
    let device = MTLCreateSystemDefaultDevice()!
    let library = try! device.makeLibrary(source: OrbShaders.source, options: nil)
    func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: v)
        d.fragmentFunction = library.makeFunction(name: f)
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
        return try! device.makeRenderPipelineState(descriptor: d)
    }
    let pts = OrbGeometry.fibonacciSphere()
    let points = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<Float>.stride)!

    // Let the wave settle into a pleasing frame.
    let animator = OrbAnimator(state: .working, random: { 0.35 })
    var f = animator.step(dt: 0.016)
    for _ in 0..<90 { f = animator.step(dt: 0.016) }

    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
    td.usage = .renderTarget; td.storageMode = .shared
    let texture = device.makeTexture(descriptor: td)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store

    var u = Uniforms(c1: SIMD4(f.params.c1, 0), c2: SIMD4(f.params.c2, 0), c3: SIMD4(f.params.c3, 0), halo: SIMD4(f.params.halo, 0),
                     a: [f.phase, f.scale, f.glow, f.ring],
                     b: [f.params.glitch, f.params.wave, f.params.bright, Float(size) / 200 * 1.6],
                     c: [Float(size), Float(size), 0, 0])
    let cmd = device.makeCommandQueue()!.makeCommandBuffer()!
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    enc.setRenderPipelineState(pipeline("quadVertex", "quadFragment"))
    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.setRenderPipelineState(pipeline("pointVertex", "pointFragment"))
    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    enc.setVertexBuffer(points, offset: 0, index: 1)
    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: OrbGeometry.pointCount)
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()

    var px = [UInt8](repeating: 0, count: size * size * 4)
    texture.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    return ctx.makeImage()!
}

// Apple's icon grid: 824pt tile centred on a 1024 canvas, ~185pt corner radius.
let canvas = 1024, tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red: 0.09, green: 0.07, blue: 0.16, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Orb diameter is 0.6 of its render, so a 1000px render gives a ~600px orb inside the tile.
ctx.draw(renderOrb(size: 1000), in: CGRect(x: 12, y: 12, width: 1000, height: 1000))

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
