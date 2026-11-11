import Foundation

public struct WidgetState: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, recording, paused, processing, finished, failed

        public var label: String {
            switch self {
            case .idle: "พร้อมอัดเสียง"
            case .recording: "กำลังอัดเสียง"
            case .paused: "พักการอัดเสียง"
            case .processing: "กำลังประมวลผล"
            case .finished: "สรุปพร้อมแล้ว"
            case .failed: "ตรวจสอบใน ReMeet"
            }
        }
    }

    public static let kind = "ReMeetRecording"
    public let phase: Phase
    public let timerStart: Date?
    public let controlToken: UUID?

    public init(phase: Phase, timerStart: Date? = nil, controlToken: UUID? = nil) {
        self.phase = phase
        self.timerStart = timerStart
        self.controlToken = controlToken
    }

    public static func load() -> WidgetState {
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(WidgetState.self, from: data) else {
            return WidgetState(phase: .idle)
        }
        return snapshot
    }

    public func save() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static var file: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ReMeetAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("RecordingState.json")
    }
}
