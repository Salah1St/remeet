import Darwin
import Foundation

public struct RecordingJob: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case starting, recording, paused, saving, transcribing, summarizing, finished, failed
    }

    public struct Status: Codable, Sendable {
        public let phase: Phase
        public let directory: URL?
        public let message: String?
    }

    public let id: UUID
    public let language: String
    private let processID: Int32

    private static var inbox: URL {
        MeetingSession.recordingsDirectory.deletingLastPathComponent().appendingPathComponent("Recording Requests", isDirectory: true)
    }

    private var directory: URL { Self.inbox.appendingPathComponent(id.uuidString, isDirectory: true) }
    private var request: URL { directory.appendingPathComponent("request.json") }
    private var stop: URL { directory.appendingPathComponent("stop") }
    private var statusFile: URL { directory.appendingPathComponent("status.json") }

    public static func submit(language: String) throws -> RecordingJob {
        let job = RecordingJob(id: UUID(), language: language, processID: getpid())
        try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try JSONEncoder().encode(job).write(to: job.request, options: .atomic)
        } catch {
            job.remove()
            throw error
        }
        return job
    }

    public static func takePending() -> [RecordingJob] {
        let files = FileManager.default
        let folders = (try? files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let request = folder.appendingPathComponent("request.json")
            guard let data = try? Data(contentsOf: request),
                  let job = try? JSONDecoder().decode(RecordingJob.self, from: data),
                  folder.lastPathComponent == job.id.uuidString,
                  (try? files.removeItem(at: request)) != nil else { return nil }
            guard kill(job.processID, 0) == 0 else {
                job.remove()
                return nil
            }
            return job
        }
    }

    public func requestStop() throws {
        try Data().write(to: stop, options: .atomic)
    }

    public var stopRequested: Bool { FileManager.default.fileExists(atPath: stop.path) }

    public func publish(_ phase: Phase, directory: URL? = nil, message: String? = nil) {
        let status = Status(phase: phase, directory: directory, message: message)
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: statusFile, options: .atomic)
    }

    public var status: Status? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
