// Draws Altiro's app icon (a notification in flight: a white dot with a blue trail on navy)
// and writes the asset catalogs for both apps. Run from the repository root:
//
//     swift tools/make-icons.swift
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The artwork, designed on a 120×120 grid (y pointing down) and scaled to fill `rect`.
func drawArtwork(in ctx: CGContext, rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / 120, y: rect.height / 120)

    ctx.setFillColor(color(0x0E1B3D))
    ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))

    // The trail: one long streak and two shorter, fainter ones beside it.
    ctx.setLineCap(.round)
    let streaks: [(from: CGPoint, to: CGPoint, width: CGFloat, alpha: CGFloat)] = [
        (CGPoint(x: 76, y: 54), CGPoint(x: 30, y: 100), 10, 0.9),
        (CGPoint(x: 64, y: 42), CGPoint(x: 36, y: 70), 7, 0.45),
        (CGPoint(x: 88, y: 66), CGPoint(x: 60, y: 94), 7, 0.45),
    ]
    for s in streaks {
        ctx.setStrokeColor(color(0x5B8CFF, alpha: s.alpha))
        ctx.setLineWidth(s.width)
        ctx.move(to: s.from)
        ctx.addLine(to: s.to)
        ctx.strokePath()
    }

    // The notification itself.
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 84 - 15, y: 40 - 15, width: 30, height: 30))
    ctx.restoreGState()
}

enum Shape {
    /// Full-bleed square: iOS rounds the corners itself.
    case iOS
    /// macOS icon grid: a rounded square inset in the canvas, with a soft shadow.
    case mac
}

func render(size: Int, shape: Shape) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (shape == .iOS ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    ctx.interpolationQuality = .high
    // Flip so y points down, like the design grid.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    let s = CGFloat(size)
    switch shape {
    case .iOS:
        drawArtwork(in: ctx, rect: CGRect(x: 0, y: 0, width: s, height: s))
    case .mac:
        // Apple's template: an 824pt rounded square centred on a 1024pt canvas.
        let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        let outline = CGPath(roundedRect: body, cornerWidth: s * 185.4 / 1024, cornerHeight: s * 185.4 / 1024, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024, color: color(0x000000, alpha: 0.3))
        ctx.setFillColor(color(0x0E1B3D))
        ctx.addPath(outline)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(outline)
        ctx.clip()
        drawArtwork(in: ctx, rect: body)
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

func writeJSON(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalogInfo: [String: Any] = ["info": ["author": "xcode", "version": 1]]

// iPhone: one 1024px image.
let iosCatalog = root.appendingPathComponent("ios/Altiro/Assets.xcassets")
let iosIcon = iosCatalog.appendingPathComponent("AppIcon.appiconset")
try writeJSON(catalogInfo, to: iosCatalog.appendingPathComponent("Contents.json"))
try write(render(size: 1024, shape: .iOS), to: iosIcon.appendingPathComponent("icon-1024.png"))
try writeJSON([
    "images": [["filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1],
], to: iosIcon.appendingPathComponent("Contents.json"))

// Mac: every size from 16pt to 512pt, at 1x and 2x.
let macCatalog = root.appendingPathComponent("mac/App/AltiroMac/Assets.xcassets")
let macIcon = macCatalog.appendingPathComponent("AppIcon.appiconset")
try writeJSON(catalogInfo, to: macCatalog.appendingPathComponent("Contents.json"))
var macImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon-\(pixels).png"
        try write(render(size: pixels, shape: .mac), to: macIcon.appendingPathComponent(name))
        macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
try writeJSON(["images": macImages, "info": ["author": "xcode", "version": 1]],
              to: macIcon.appendingPathComponent("Contents.json"))

print("Wrote \(iosIcon.path) and \(macIcon.path)")
