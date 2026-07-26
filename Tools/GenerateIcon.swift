import AppKit
import Foundation

@main
struct IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: GenerateIcon <iconset-directory>\n", stderr)
            exit(2)
        }

        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for variant in variants {
            let data = try renderIcon(pixels: variant.pixels)
            try data.write(to: outputDirectory.appendingPathComponent(variant.name))
        }
    }

    private static func renderIcon(pixels: Int) throws -> Data {
        let size = NSSize(width: pixels, height: pixels)
        guard let bitmap = NSBitmapImageRep(
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
            throw NSError(domain: "IconGenerator", code: 1)
        }

        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "IconGenerator", code: 2)
        }
        NSGraphicsContext.current = context

        let inset = CGFloat(pixels) * 0.055
        let radius = CGFloat(pixels) * 0.225
        let backgroundRect = NSRect(
            x: inset,
            y: inset,
            width: CGFloat(pixels) - inset * 2,
            height: CGFloat(pixels) - inset * 2
        )
        let background = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: radius,
            yRadius: radius
        )

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.25, green: 0.24, blue: 0.73, alpha: 1),
            NSColor(calibratedRed: 0.55, green: 0.22, blue: 0.72, alpha: 1)
        ])
        gradient?.draw(in: background, angle: -45)

        NSColor.white.withAlphaComponent(0.12).setStroke()
        background.lineWidth = max(1, CGFloat(pixels) * 0.012)
        background.stroke()

        let symbolConfig = NSImage.SymbolConfiguration(
            pointSize: CGFloat(pixels) * 0.43,
            weight: .semibold
        )
        if let symbol = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfig) {
            let symbolSize = symbol.size
            let symbolRect = NSRect(
                x: (CGFloat(pixels) - symbolSize.width) / 2,
                y: (CGFloat(pixels) - symbolSize.height) / 2 - CGFloat(pixels) * 0.015,
                width: symbolSize.width,
                height: symbolSize.height
            )
            NSColor.white.set()
            symbol.draw(in: symbolRect)
        }

        let dotSize = CGFloat(pixels) * 0.19
        let dotRect = NSRect(
            x: CGFloat(pixels) * 0.69,
            y: CGFloat(pixels) * 0.68,
            width: dotSize,
            height: dotSize
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -CGFloat(pixels) * 0.018, dy: -CGFloat(pixels) * 0.018)).fill()
        NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.46, alpha: 1).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGenerator", code: 3)
        }
        return png
    }
}
