#!/usr/bin/env swift
// Renders the app's icon assets from code so they can be regenerated without
// design tooling. Run from the repo root (requires only Command Line Tools):
//
//   swift Scripts/generate-icons.swift
//
// Outputs:
//   SoundsRight/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-*.png
//   SoundsRight/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon{,@2x}.png
//
// Design: a cinnabar seal (Chinese chop) carrying 声 ("sound") in porcelain,
// with two sound-wave arcs — the same mark used by WelcomeView's AppMark.

import AppKit

// MARK: - Palette

let cinnabarTop = NSColor(calibratedRed: 0.78, green: 0.31, blue: 0.22, alpha: 1)
let cinnabarBottom = NSColor(calibratedRed: 0.63, green: 0.20, blue: 0.13, alpha: 1)
let porcelain = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.93, alpha: 1)

// MARK: - Drawing helpers

func makeBitmap(_ pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap rep (\(pixels)px)")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    return rep
}

func glyphFont(size: CGFloat) -> NSFont {
    // Songti gives the seal a carved, dictionary feel; PingFang is the fallback.
    NSFont(name: "STSongti-SC-Bold", size: size)
        ?? NSFont(name: "PingFangSC-Semibold", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .semibold)
}

/// Draws `text` horizontally centered on `centerX` and vertically centered on
/// `centerY`, using glyph bounds (not line-height) so CJK centering is optical.
func drawGlyph(_ text: String, font: NSFont, color: NSColor, centerX: CGFloat, centerY: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin])
    let origin = NSPoint(
        x: centerX - bounds.width / 2 - bounds.minX,
        y: centerY - bounds.height / 2 - bounds.minY
    )
    string.draw(at: origin)
}

// MARK: - App icon

func drawAppIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = makeBitmap(pixels)
    let n = CGFloat(pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not create graphics context")
    }
    NSGraphicsContext.current = context
    let cg = context.cgContext

    // macOS icon grid: content squircle inset 100/1024 with ~185/1024 corner radius.
    let inset = n * 100.0 / 1024.0
    let radius = n * 185.0 / 1024.0
    let box = NSRect(x: inset, y: inset, width: n - 2 * inset, height: n - 2 * inset)
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    // Soft drop shadow inside the transparent margin.
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -n * 0.012),
        blur: n * 0.024,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    cinnabarBottom.setFill()
    squircle.fill()
    cg.restoreGState()

    // Seal body: vertical cinnabar gradient with a faint top sheen.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [cinnabarTop, cinnabarBottom])?.draw(in: box, angle: -90)
    let sheen = NSRect(x: box.minX, y: box.midY + box.height * 0.2, width: box.width, height: box.height * 0.3)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])?
        .draw(in: sheen, angle: -90)

    // 声 — "sound". Shifted left when the sound waves are drawn; at tiny sizes
    // the waves are dropped and the glyph grows so it stays legible.
    let drawWaves = pixels >= 64
    let glyphCenterX = drawWaves ? n * 0.44 : n * 0.5
    let glyphScale: CGFloat = drawWaves ? 0.46 : 0.58
    drawGlyph(
        "声",
        font: glyphFont(size: n * glyphScale),
        color: porcelain,
        centerX: glyphCenterX,
        centerY: n * 0.5
    )

    // Two sound-wave arcs radiating right, dropped at small sizes where they'd smear.
    if drawWaves {
        let waveCenter = NSPoint(x: n * 0.66, y: n * 0.5)
        for (radiusFactor, alpha) in [(0.115, 0.9), (0.185, 0.5)] {
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: waveCenter,
                radius: n * radiusFactor,
                startAngle: -42,
                endAngle: 42
            )
            arc.lineWidth = n * 0.030
            arc.lineCapStyle = .round
            porcelain.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Menu bar icon (template: alpha only)

func drawMenuBarIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = makeBitmap(pixels)
    let n = CGFloat(pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not create graphics context")
    }
    NSGraphicsContext.current = context

    // Bare 声, sized to the standard 18pt status-item image. Black is arbitrary:
    // the imageset is marked template, so only the alpha channel matters.
    drawGlyph(
        "声",
        font: glyphFont(size: n * 0.86),
        color: .black,
        centerX: n * 0.5,
        centerY: n * 0.5
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(path)")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    } catch {
        fatalError("Could not write \(path): \(error)")
    }
}

let appIconDir = "SoundsRight/Resources/Assets.xcassets/AppIcon.appiconset"
let menuBarDir = "SoundsRight/Resources/Assets.xcassets/MenuBarIcon.imageset"

// The standard macOS icon set: (point size, scale) pairs.
let appIconSpecs: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for spec in appIconSpecs {
    let pixels = spec.points * spec.scale
    let suffix = spec.scale == 2 ? "@2x" : ""
    let path = "\(appIconDir)/AppIcon-\(spec.points)x\(spec.points)\(suffix).png"
    write(drawAppIcon(pixels: pixels), to: path)
}

write(drawMenuBarIcon(pixels: 18), to: "\(menuBarDir)/MenuBarIcon.png")
write(drawMenuBarIcon(pixels: 36), to: "\(menuBarDir)/MenuBarIcon@2x.png")

print("Done.")
