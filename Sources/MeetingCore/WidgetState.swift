import Darwin
import Foundation

public struct WidgetState: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, recording, processing

        public var label: String {
            switch self {
            case .idle: "IDLE"
            case .recording: "REC"
            case .processing: "SAVE…"
            }
        }
    }

    public static let kind = "ReMeetRecording"
    public let phase: Phase
    public let timerStart: Date?
    public let controlToken: UUID?
    private let writerPID: pid_t?

    public init(phase: Phase, timerStart: Date? = nil, controlToken: UUID? = nil) {
        self.phase = phase
        self.timerStart = timerStart
        self.controlToken = controlToken
        self.writerPID = phase == .idle ? nil : getpid()
    }

    public static func load() -> WidgetState {
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(WidgetState.self, from: data) else {
            return WidgetState(phase: .idle)
        }
        if snapshot.phase != .idle {
            guard let pid = snapshot.writerPID, pid > 0 else { return WidgetState(phase: .idle) }
            if kill(pid, 0) == -1 && errno == ESRCH { return WidgetState(phase: .idle) }
        }
        return snapshot
    }

    public func save() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // WidgetKit falls back to IDLE if the snapshot is unavailable.
        }
    }

    private static var file: URL? {
        let manager = FileManager.default
        if let group = Bundle.main.object(forInfoDictionaryKey: "ReMeetAppGroup") as? String {
            return manager.containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("RecordingState.json")
        }

        // Internal builds use the file named in Widget.entitlements. Resolve the account's
        // home from the user database because sandboxed Foundation home paths may point at the container.
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home = buffer.withUnsafeMutableBufferPointer { memory -> String? in
            guard getpwuid_r(getuid(), &entry, memory.baseAddress, memory.count, &result) == 0,
                  result != nil, let path = entry.pw_dir else { return nil }
            return String(cString: path)
        }
        guard let home else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/ReMeet/RecordingState.json")
    }
}
