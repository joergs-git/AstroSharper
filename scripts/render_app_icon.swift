#!/usr/bin/env swift
// Renders the AstroSharper app icon at every required macOS size
// (16/32/64/128/256/512/1024) and writes the PNGs into
// `AstroSharper/Assets.xcassets/AppIcon.appiconset/`.
//
// Run once: `swift scripts/render_app_icon.swift`
// Re-run after tweaking the design — Xcode's Assets catalog picks the new
// PNGs automatically on the next build.

import AppKit
import CoreGraphics
import Foundation

let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("AstroSharper/Assets.xcassets/AppIcon.appiconset")

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for size in sizes {
    let pixels = size
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }

    let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)

    // Rounded-square mask (macOS uses ~22.5% corner radius on its own).
    let radius = CGFloat(pixels) * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Brand gradient: dark blue → deeper blue.
    let colors = [
        CGColor(red: 0.16, green: 0.36, blue: 0.66, alpha: 1.0),
        CGColor(red: 0.08, green: 0.16, blue: 0.40, alpha: 1.0),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: pixels),
        end: CGPoint(x: pixels, y: 0),
        options: []
    )

    // Concentric eyepiece rings — subtle inner glow.
    let center = CGPoint(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
    let outerRadius = CGFloat(pixels) * 0.34
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.40))
    ctx.setLineWidth(CGFloat(pixels) * 0.018)
    ctx.strokeEllipse(in: CGRect(
        x: center.x - outerRadius, y: center.y - outerRadius,
        width: outerRadius * 2, height: outerRadius * 2
    ))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(CGFloat(pixels) * 0.010)
    let innerRadius = outerRadius * 0.62
    ctx.strokeEllipse(in: CGRect(
        x: center.x - innerRadius, y: center.y - innerRadius,
        width: innerRadius * 2, height: innerRadius * 2
    ))

    // Crosshair.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    ctx.setLineWidth(CGFloat(pixels) * 0.012)
    let chHalf = innerRadius * 0.50
    ctx.move(to: CGPoint(x: center.x - chHalf, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x + chHalf, y: center.y))
    ctx.move(to: CGPoint(x: center.x, y: center.y - chHalf))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + chHalf))
    ctx.strokePath()

    // Bright 4-point star at center — the "sharp" focus.
    let starSize = CGFloat(pixels) * 0.16
    let starPath = CGMutablePath()
    starPath.move(to: CGPoint(x: center.x, y: center.y - starSize))
    starPath.addLine(to: CGPoint(x: center.x + starSize * 0.18, y: center.y - starSize * 0.18))
    starPath.addLine(to: CGPoint(x: center.x + starSize, y: center.y))
    starPath.addLine(to: CGPoint(x: center.x + starSize * 0.18, y: center.y + starSize * 0.18))
    starPath.addLine(to: CGPoint(x: center.x, y: center.y + starSize))
    starPath.addLine(to: CGPoint(x: center.x - starSize * 0.18, y: center.y + starSize * 0.18))
    starPath.addLine(to: CGPoint(x: center.x - starSize, y: center.y))
    starPath.addLine(to: CGPoint(x: center.x - starSize * 0.18, y: center.y - starSize * 0.18))
    starPath.closeSubpath()
    ctx.setShadow(offset: .zero, blur: CGFloat(pixels) * 0.05,
                  color: CGColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 0.9))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    ctx.addPath(starPath)
    ctx.fillPath()

    // Three orbiting "lucky frame" sparkles.
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.92, blue: 0.55, alpha: 1.0))
    let sparkleSize = CGFloat(pixels) * 0.04
    for angle in stride(from: -0.5, through: 0.6, by: 0.55) {
        let a = angle * .pi
        let x = center.x + cos(a) * outerRadius * 0.92
        let y = center.y + sin(a) * outerRadius * 0.92
        ctx.fillEllipse(in: CGRect(
            x: x - sparkleSize, y: y - sparkleSize,
            width: sparkleSize * 2, height: sparkleSize * 2
        ))
    }

    guard let cgImage = ctx.makeImage() else { continue }
    let url = outDir.appendingPathComponent("icon_\(size).png")
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: pixels, height: pixels)
    if let data = bitmap.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("Wrote \(url.path)")
    }
}

print("Done.")
