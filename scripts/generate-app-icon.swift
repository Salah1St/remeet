import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct GenerateAppIcon {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/ReMeet.icns")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let iconset = temporary.appendingPathComponent("ReMeet.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let destination = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                try render(pixelSize: size * scale, to: destination)
            }
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else { throw IconError.conversionFailed }
    }

    private static func render(pixelSize: Int, to url: URL) throws {
        let size = CGFloat(pixelSize)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw IconError.renderFailed }

        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)

        let circle = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.045, dy: size * 0.045)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: circle)

        let inset = circle.width * (1 - ReMeetWaveform.markScale) / 2
        let glyph = ReMeetWaveform().path(in: circle.insetBy(dx: inset, dy: inset))
        context.setFillColor(ReMeetWaveform.ink)
        context.addPath(glyph.cgPath)
        context.fillPath()

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw IconError.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconError.renderFailed }
    }

    private enum IconError: Error {
        case renderFailed
        case conversionFailed
    }
}
