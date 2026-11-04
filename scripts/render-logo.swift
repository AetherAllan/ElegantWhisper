import AppKit
import CoreGraphics
import SwiftUI

// Draws ElegantWhisper's icons into Resources/. Run from the repository root:
//
//     swift scripts/render-logo.swift
//
// The mark is the floating bar's voice: dots that rise into bars, a little uneven like a real
// syllable. Three icons share it, and the app shows the one that matches its look (AppIconVariant):
//   Paper   ink bars on white          Standard theme, light mode
//   Pulse   white bars on graphite     Standard theme, dark mode
//   Prism   spectrum bars on black     Prism theme; also the bundle icon Finder shows
// plus a monochrome template of the mark for the menu bar.

let resources = URL(fileURLWithPath: "Resources", isDirectory: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let center = CGPoint(x: 512, y: 512)
let pulseHeights: [CGFloat] = [0.0, 0.26, 0.52, 0.86, 1.0, 0.66, 0.40, 0.18, 0.0]

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

func hex(_ value: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255, a)
}

/// PrismPalette.spectrum, blended continuously from red at 0 to violet at 1.
let spectrum: [CGColor] = [
    rgb(1.00, 0.23, 0.24), rgb(1.00, 0.58, 0.10), rgb(1.00, 0.86, 0.16),
    rgb(0.26, 0.84, 0.40), rgb(0.16, 0.55, 1.00), rgb(0.60, 0.36, 1.00),
]

func spectrumColor(_ t: CGFloat) -> CGColor {
    let x = min(max(t, 0), 1) * CGFloat(spectrum.count - 1)
    let i = min(Int(x), spectrum.count - 2)
    let f = x - CGFloat(i)
    let a = spectrum[i].components!, b = spectrum[i + 1].components!
    return rgb(a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f)
}

func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func capsule(_ rect: CGRect) -> CGPath {
    let r = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

enum Surface { case graphite, black, paper }

/// The squircle on Apple's 1024 grid with the standard drop shadow, a faint light from above,
/// and a hairline rim that is brightest at the top, like the edge of glass.
func drawBody(_ ctx: CGContext, _ surface: Surface) {
    let path = squircle(bodyRect, radius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.32))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors: [CGColor] = switch surface {
    case .graphite: [hex(0x2A2A31), hex(0x121216), hex(0x09090B)]
    case .black: [hex(0x17171C), hex(0x060608), hex(0x020203)]
    case .paper: [hex(0xFFFFFF), hex(0xF4F4F7), hex(0xE6E6EC)]
    }
    let fill = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: bodyRect.maxY), end: CGPoint(x: 512, y: bodyRect.minY), options: [])
    if surface != .paper {
        let light = CGGradient(colorsSpace: srgb, colors: [rgb(1, 1, 1, 0.07), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(light, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 860), endRadius: 620, options: [])
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle(bodyRect.insetBy(dx: 1.5, dy: 1.5), radius: 183.5))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let top: CGFloat = surface == .paper ? 0.9 : 0.22
    let bottom: CGFloat = surface == .paper ? 0.3 : 0.03
    let rim = CGGradient(colorsSpace: srgb, colors: [rgb(1, 1, 1, top), rgb(1, 1, 1, bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: bodyRect.maxY), end: CGPoint(x: 512, y: bodyRect.minY), options: [])
    ctx.restoreGState()
}

/// Rounded bars centered on `center`; a zero height is a dot.
func barRects(_ heights: [CGFloat], width: CGFloat, gap: CGFloat, maxHeight: CGFloat, center: CGPoint) -> [CGRect] {
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    return heights.enumerated().map { index, fraction in
        let height = max(width, maxHeight * fraction)
        return CGRect(x: center.x - total / 2 + CGFloat(index) * (width + gap), y: center.y - height / 2,
                      width: width, height: height)
    }
}

func fillBar(_ ctx: CGContext, _ rect: CGRect, top: CGColor, bottom: CGColor, glow: CGColor? = nil) {
    if let glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46, color: glow)
        ctx.addPath(capsule(rect))
        ctx.setFillColor(bottom)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(capsule(rect))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

func icon(_ surface: Surface) -> CGImage {
    let ctx = makeContext(1024)
    drawBody(ctx, surface)
    let rects = barRects(pulseHeights, width: 40, gap: 25, maxHeight: 430, center: center)
    for (index, rect) in rects.enumerated() {
        switch surface {
        case .graphite:
            fillBar(ctx, rect, top: rgb(1, 1, 1), bottom: hex(0xD6D6DE), glow: rgb(1, 1, 1, 0.18))
        case .paper:
            fillBar(ctx, rect, top: hex(0x2C2C34), bottom: hex(0x0E0E12))
        case .black:
            let color = spectrumColor(CGFloat(index) / CGFloat(rects.count - 1))
            let c = color.components!
            let lighter = rgb(c[0] * 0.55 + 0.45, c[1] * 0.55 + 0.45, c[2] * 0.55 + 0.45)
            fillBar(ctx, rect, top: lighter, bottom: color, glow: rgb(c[0], c[1], c[2], 0.55))
        }
    }
    return ctx.makeImage()!
}

/// Black on transparent; macOS tints it for the menu bar. 72 px is 18 pt at @4x.
func menuBarTemplate() -> CGImage {
    let ctx = makeContext(72)
    ctx.setFillColor(rgb(0, 0, 0))
    for rect in barRects([0.0, 0.42, 0.86, 1.0, 0.6, 0.28, 0.0], width: 6, gap: 5, maxHeight: 56, center: CGPoint(x: 36, y: 36)) {
        ctx.addPath(capsule(rect))
    }
    ctx.fillPath()
    return ctx.makeImage()!
}

let paper = icon(.paper)
let pulse = icon(.graphite)
let prism = icon(.black)

// Runtime variants: the Dock draws at most 256 px (128 pt @2x), so 512 px leaves headroom.
writePNG(resized(paper, to: 512), to: resources.appendingPathComponent("AppIcon-Paper.png"))
writePNG(resized(pulse, to: 512), to: resources.appendingPathComponent("AppIcon-Pulse.png"))
writePNG(resized(prism, to: 512), to: resources.appendingPathComponent("AppIcon-Prism.png"))
writePNG(prism, to: resources.appendingPathComponent("ElegantWhisperLogo.png"))
writePNG(menuBarTemplate(), to: resources.appendingPathComponent("StatusBarIcon.png"))

// The bundle icon (Finder, Launchpad, Spotlight) cannot follow the theme, so it is Prism.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(resized(prism, to: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(resized(prism, to: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("Wrote AppIcon.icns, AppIcon-{Paper,Pulse,Prism}.png, ElegantWhisperLogo.png, StatusBarIcon.png")
