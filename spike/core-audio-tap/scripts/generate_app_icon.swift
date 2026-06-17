import AppKit
import CoreGraphics
import Foundation

struct IconSlot {
    let filename: String
    let pixels: Int
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "CoreAudioTapPoC/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let slots = [
    IconSlot(filename: "icon_16x16.png", pixels: 16),
    IconSlot(filename: "icon_16x16@2x.png", pixels: 32),
    IconSlot(filename: "icon_32x32.png", pixels: 32),
    IconSlot(filename: "icon_32x32@2x.png", pixels: 64),
    IconSlot(filename: "icon_128x128.png", pixels: 128),
    IconSlot(filename: "icon_128x128@2x.png", pixels: 256),
    IconSlot(filename: "icon_256x256.png", pixels: 256),
    IconSlot(filename: "icon_256x256@2x.png", pixels: 512),
    IconSlot(filename: "icon_512x512.png", pixels: 512),
    IconSlot(filename: "icon_512x512@2x.png", pixels: 1024)
]

func path(_ points: [CGPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.close()
    return path
}

func strokeWave(_ rect: CGRect, color: NSColor, alpha: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.curve(
        to: CGPoint(x: rect.minX, y: rect.maxY),
        controlPoint1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.24),
        controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.24)
    )
    path.lineWidth = width
    path.lineCapStyle = .round
    color.withAlphaComponent(alpha).setStroke()
    path.stroke()
}

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap representation")
    }
    representation.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(true)
    NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

    let scale = CGFloat(size) / 128.0
    func p(_ value: CGFloat) -> CGFloat { value * scale }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: p(x), y: p(y)) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: p(x), y: p(y), width: p(width), height: p(height))
    }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = p(29)
    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: p(3), dy: p(3)), xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.972, green: 0.780, blue: 0.835, alpha: 1.0), 0.00),
        (NSColor.white, 0.46),
        (NSColor(calibratedRed: 0.416, green: 0.663, blue: 0.561, alpha: 1.0), 1.00)
    )
    gradient?.draw(in: background, angle: -45)

    NSColor(calibratedWhite: 0.0, alpha: 0.08).setStroke()
    background.lineWidth = max(1, p(1))
    background.stroke()

    let speakerColor = NSColor(calibratedRed: 0.125, green: 0.188, blue: 0.184, alpha: 1.0)
    speakerColor.setFill()
    path([
        point(23, 70),
        point(41, 70),
        point(69, 93),
        point(69, 35),
        point(41, 58),
        point(23, 58)
    ]).fill()

    strokeWave(rect(79, 49, 15, 30), color: speakerColor, alpha: 1.0, width: p(9))
    strokeWave(rect(92, 37, 20, 54), color: speakerColor, alpha: 0.68, width: p(7))

    NSColor(calibratedRed: 0.910, green: 0.373, blue: 0.514, alpha: 1.0).setFill()
    let pinkLeaf = NSBezierPath()
    pinkLeaf.move(to: point(88, 28))
    pinkLeaf.curve(to: point(54, 8), controlPoint1: point(70, 30), controlPoint2: point(59, 18))
    pinkLeaf.curve(to: point(88, 28), controlPoint1: point(69, 11), controlPoint2: point(82, 19))
    pinkLeaf.close()
    pinkLeaf.fill()

    NSColor(calibratedRed: 0.416, green: 0.663, blue: 0.561, alpha: 1.0).setFill()
    let greenLeaf = NSBezierPath()
    greenLeaf.move(to: point(78, 30))
    greenLeaf.curve(to: point(49, 14), controlPoint1: point(63, 31), controlPoint2: point(53, 23))
    greenLeaf.curve(to: point(78, 30), controlPoint1: point(62, 16), controlPoint2: point(73, 22))
    greenLeaf.close()
    greenLeaf.fill()

    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(representation)
    return image
}

for slot in slots {
    let image = drawIcon(size: slot.pixels)
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(slot.filename)")
    }
    try png.write(to: outputDirectory.appendingPathComponent(slot.filename))
}

print("Generated \(slots.count) app icon images in \(outputDirectory.path)")
