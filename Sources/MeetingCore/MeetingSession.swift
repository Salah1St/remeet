import Foundation

public struct MeetingSession: Sendable {
    public enum Stage: Sendable {
        case transcribing
        case summarizing
    }

    public let directory: URL
    public let language: String

    public static var recordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReMeet/Recordings", isDirectory: true)
    }

    private let dateStamp: String

    public var transcript: URL { directory.appendingPathComponent("transcript-\(dateStamp).txt") }
    public var summary: URL { directory.appendingPathComponent("ai-summary.md") }

    public var audio: URL? {
        let recording = directory.appendingPathComponent("recording.wav")
        if Self.isFile(recording) { return recording }

        let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        )
        return files?.first { $0.deletingPathExtension().lastPathComponent == "source" && Self.isFile($0) }
    }

    public var hasTranscript: Bool { Self.isFile(transcript) }
    public var hasSummary: Bool { Self.isFile(summary) }
    public var canResume: Bool { !hasSummary && (hasTranscript || audio != nil) }

    public static func create(language: String, importing source: URL? = nil) throws -> MeetingSession {
        let now = Date()
        let date = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let directory = recordingsDirectory.appendingPathComponent("\(date)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "ddMMyyyy"
        let session = MeetingSession(directory: directory, language: language, dateStamp: formatter.string(from: now))
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            if let source {
                let ext = source.pathExtension
                let name = ext.isEmpty ? "source.audio" : "source.\(ext)"
                try files.copyItem(at: source, to: directory.appendingPathComponent(name))
            }
            let metadata = Metadata(language: language, dateStamp: session.dateStamp)
            try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
            return session
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    public static func open(_ directory: URL) throws -> MeetingSession {
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        guard metadata.dateStamp.utf8.count == 8, metadata.dateStamp.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw SessionError.invalidMetadata
        }
        return MeetingSession(directory: directory, language: metadata.language, dateStamp: metadata.dateStamp)
    }

    public static func latest() -> MeetingSession? {
        let directories = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        for directory in (directories ?? []).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if let session = try? open(directory), session.hasSummary || session.canResume {
                return session
            }
        }
        return nil
    }

    @MainActor
    public func complete(using pipeline: MeetingPipeline, audio recording: URL? = nil, onStage: (Stage) -> Void) async throws {
        if hasSummary { return }

        let text: URL
        if hasTranscript {
            text = transcript
        } else {
            guard let input = recording ?? audio else { throw SessionError.missingRecording }
            onStage(.transcribing)
            text = try await pipeline.transcribe(audio: input, into: directory, language: language, transcriptFilename: transcript.lastPathComponent)
        }

        onStage(.summarizing)
        _ = try await pipeline.summarize(transcript: text, into: directory, language: language)
    }

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private enum SessionError: LocalizedError {
        case missingRecording

        case invalidMetadata

        var errorDescription: String? {
            switch self {
            case .missingRecording: "This session has no recording or transcript to process."
            case .invalidMetadata: "Invalid ReMeet session date."
            }
        }
    }

    private struct Metadata: Codable {
        let language: String
        let dateStamp: String
    }
}
