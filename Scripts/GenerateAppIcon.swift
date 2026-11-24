#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Assets/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The first five segments of the plain dragon, doubled the same way the map stores them.
let path: [(CGFloat, CGFloat)] = [
    (0, 0), (2, 0), (2, 2), (0, 2), (0, 4), (-2, 4),
]
let marks: [(CGFloat, CGFloat)] = [
    (1, 0), (2, 1), (1, 2), (0, 3), (-1, 4),
]

func render(size: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(size)
    ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    let margin = s * 0.08
    let corner = s * 0.22
    let plate = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let clip = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(clip)
    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.12, blue: 0.10, alpha: 1))
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(srgbRed: 0.86, green: 0.68, blue: 0.36, alpha: 0.9))
    ctx.setLineWidth(max(1, s * 0.018))
    ctx.addPath(clip)
    ctx.strokePath()

    let xs = path.map(\.0) + marks.map(\.0)
    let ys = path.map(\.1) + marks.map(\.1)
    let minX = xs.min() ?? 0
    let maxX = xs.max() ?? 1
    let minY = ys.min() ?? 0
    let maxY = ys.max() ?? 1
    let spanX = max(maxX - minX, 1)
    let spanY = max(maxY - minY, 1)
    let pad = s * 0.24
    let scale = min((s - pad * 2) / spanX, (s - pad * 2) / spanY)
    let originX = (s - spanX * scale) / 2
    let originY = (s - spanY * scale) / 2
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: originX + (x - minX) * scale, y: originY + (y - minY) * scale)
    }

    ctx.setStrokeColor(CGColor(srgbRed: 0.86, green: 0.68, blue: 0.36, alpha: 1))
    ctx.setLineWidth(max(2, s * 0.045))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let start = point(path[0].0, path[0].1)
    ctx.move(to: start)
    for vertex in path.dropFirst() {
        ctx.addLine(to: point(vertex.0, vertex.1))
    }
    ctx.strokePath()

    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.91, blue: 0.82, alpha: 1))
    let dot = max(1.5, s * 0.035)
    for mark in marks {
        let center = point(mark.0, mark.1)
        ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    }
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DragonCurveIcon", code: 1)
    }
    try data.write(to: url)
}

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in specs {
    guard let image = render(size: size) else {
        fputs("render failed\n", stderr)
        exit(1)
    }
    try writePNG(image, to: iconset.appendingPathComponent(name))
}

let icns = root.appendingPathComponent("Assets/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(1) }
print(icns.path)
