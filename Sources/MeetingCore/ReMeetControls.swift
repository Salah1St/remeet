import SwiftUI

public enum ReMeetControls {
    public static let actionSize: CGFloat = 48
    public static let utilitySize: CGFloat = 32
    public static let controlFill = Color.primary.opacity(0.08)
}

public struct ReMeetMark: View {
    private let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        ReMeetWaveform()
            .fill(ReMeetWaveform.tint)
            .frame(width: size * ReMeetWaveform.markScale, height: size * ReMeetWaveform.markScale)
            .frame(width: size, height: size)
            .background(.black, in: Circle())
            .accessibilityHidden(true)
    }
}

public struct ReMeetIconLabel: View {
    private let title: String
    private let symbol: String
    private let compact: Bool
    private let emphasized: Bool

    public init(_ title: String, systemImage: String, compact: Bool = false, emphasized: Bool = false) {
        self.title = title
        self.symbol = systemImage
        self.compact = compact
        self.emphasized = emphasized
    }

    public var body: some View {
        let size = compact ? ReMeetControls.utilitySize : ReMeetControls.actionSize
        Image(systemName: symbol)
            .font(.system(size: compact ? 15 : 20, weight: .medium))
            .foregroundStyle(emphasized ? ReMeetWaveform.tint : Color.primary)
            .frame(width: size, height: size)
            .background(emphasized ? ReMeetWaveform.tint.opacity(0.15) : ReMeetControls.controlFill, in: Circle())
            .contentShape(Circle())
            .accessibilityLabel(title)
    }
}

public struct ReMeetModeChip: View {
    public init() {}

    public var body: some View {
        Label("After Stop", systemImage: "arrow.left.arrow.right")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(ReMeetWaveform.tint.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
    }
}
