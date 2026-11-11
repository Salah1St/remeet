import SwiftUI

public struct ReMeetWaveform: Shape {
    public static let markScale = 0.53
    public static var tint: Color { Color(cgColor: ink) }
    static let ink = CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [193.0 / 255.0, 95.0 / 255.0, 60.0 / 255.0, 1]
    )!

    private static let bars = [
        CGRect(x: 0, y: 12, width: 3, height: 8),
        CGRect(x: 7, y: 7, width: 3, height: 15),
        CGRect(x: 14, y: 0, width: 4, height: 18),
        CGRect(x: 14, y: 21, width: 4, height: 11),
        CGRect(x: 22, y: 5, width: 3, height: 20),
        CGRect(x: 29, y: 10, width: 3, height: 8),
    ]

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 32
        let origin = CGPoint(x: rect.midX - 16 * unit, y: rect.midY - 16 * unit)
        var path = Path()
        for bar in Self.bars {
            let frame = CGRect(
                x: origin.x + bar.minX * unit,
                y: origin.y + bar.minY * unit,
                width: bar.width * unit,
                height: bar.height * unit
            )
            let radius = frame.width / 2
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
