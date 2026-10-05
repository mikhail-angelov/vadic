// Draws the Vadic app icon: a white waveform on a blue-violet squircle, following Apple's macOS icon grid
// (824 pt body on a 1024 pt canvas with a soft drop shadow).
// Usage: swift scripts/make-icon.swift <out.png> [size]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let scale = CGFloat(size) / 1024

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }
ctx.scaleBy(x: scale, y: scale)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Body: diagonal gradient, indigo to violet.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [
    CGColor(srgbRed: 0.20, green: 0.36, blue: 0.98, alpha: 1),
    CGColor(srgbRed: 0.45, green: 0.23, blue: 0.93, alpha: 1),
    CGColor(srgbRed: 0.62, green: 0.20, blue: 0.80, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

// Soft highlight on the upper half.
let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// Waveform: symmetric rounded bars.
let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.92, 0.68, 0.42, 0.22]
let barWidth: CGFloat = 58
let gap: CGFloat = 34
let maxHeight: CGFloat = 470
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(srgbRed: 0.1, green: 0.05, blue: 0.35, alpha: 0.45))
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
for (i, h) in heights.enumerated() {
    let height = maxHeight * h
    let x = body.midX - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
    let bar = CGRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
