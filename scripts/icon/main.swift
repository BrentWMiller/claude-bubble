// Renders the working-state orb with the app's Metal shaders onto a macOS icon tile.
// Usage: make-icon.sh (compiles this with the shader + core sources).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
ctx.draw(OrbSnapshot.render(state: .working, size: 1000)!, in: CGRect(x: 12, y: 12, width: 1000, height: 1000))

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
