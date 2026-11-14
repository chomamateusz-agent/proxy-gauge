import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconRenderer {
    let size: Int
    let roundedCorners: Bool

    func render() -> CGImage {
        let side = CGFloat(size)
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        let tile = roundedCorners ? canvas.insetBy(dx: side * 0.098, dy: side * 0.098) : canvas
        drawBackground(context, tile: tile)
        drawGauge(context, tile: tile)
        return context.makeImage()!
    }

    private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private func drawBackground(_ context: CGContext, tile: CGRect) {
        context.saveGState()
        if roundedCorners {
            let radius = tile.width * 0.225
            context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }
        let gradient = CGGradient(colorsSpace: nil, colors: [color(0x0F2A3D), color(0x14535C)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        context.restoreGState()
    }

    private func drawGauge(_ context: CGContext, tile: CGRect) {
        let unit = tile.width
        let center = CGPoint(x: tile.midX, y: tile.minY + unit * 0.42)
        let radius = unit * 0.32
        let width = unit * 0.085
        let start = CGFloat.pi * 1.0
        let end = CGFloat.pi * 0.0
        context.setLineCap(.round)
        context.setLineWidth(width)
        context.setStrokeColor(color(0xFFFFFF, 0.16))
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        context.strokePath()

        let segments: [(UInt32, CGFloat, CGFloat)] = [(0x34D399, 0.0, 0.42), (0xFBBF24, 0.42, 0.72), (0xF87171, 0.72, 1.0)]
        for (hex, from, to) in segments {
            context.setStrokeColor(color(hex))
            context.addArc(
                center: center, radius: radius,
                startAngle: start - .pi * from - (from == 0 ? 0 : 0.02),
                endAngle: start - .pi * to + (to == 1 ? 0 : 0.02),
                clockwise: true
            )
            context.strokePath()
        }

        let needleAngle = start - .pi * 0.33
        let tip = CGPoint(x: center.x + cos(needleAngle) * radius * 0.86, y: center.y + sin(needleAngle) * radius * 0.86)
        context.setStrokeColor(color(0xF8FAFC))
        context.setLineWidth(unit * 0.045)
        context.move(to: center)
        context.addLine(to: tip)
        context.strokePath()
        let hub = unit * 0.075
        context.setFillColor(color(0xF8FAFC))
        context.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
        context.setFillColor(color(0x0F2A3D))
        let inner = hub * 0.45
        context.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))

        let barWidth = unit * 0.5
        let barHeight = unit * 0.05
        let barY = tile.minY + unit * 0.2
        let track = CGRect(x: tile.midX - barWidth / 2, y: barY, width: barWidth, height: barHeight)
        context.setFillColor(color(0xFFFFFF, 0.16))
        context.addPath(CGPath(roundedRect: track, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        context.fillPath()
        var fill = track
        fill.size.width = barWidth * 0.62
        context.setFillColor(color(0x34D399))
        context.addPath(CGPath(roundedRect: fill, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        context.fillPath()
    }
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <AppIcon.appiconset directory>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var images: [[String: String]] = []
write(IconRenderer(size: 1024, roundedCorners: false).render(), to: directory.appending(path: "ios-1024.png"))
images.append(["filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        write(IconRenderer(size: points * scale, roundedCorners: true).render(), to: directory.appending(path: name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: directory.appending(path: "Contents.json"))
print("Rendered \(images.count) icon images into \(directory.path)")
