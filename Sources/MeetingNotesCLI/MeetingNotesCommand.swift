import AppKit
import Darwin
import Dispatch
import Foundation
import MeetingCore

@main
struct MeetingNotesCommand {
    private enum Command {
        case record(language: String)
        case process(file: URL, language: String)
        case resume(directory: URL)
        case setup
        case help
    }

    private struct UsageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let help = """
    Usage:
      remeet record [--language auto|th|en|…]
      remeet process <audio-file> [--language auto|th|en|…]
      remeet resume <session-folder>
      remeet setup

    record    Record system audio and the default microphone. Press Ctrl+C to stop.
    process   Copy an audio file into a new session, then transcribe and summarize it.
    resume    Finish a saved session, reusing its transcript if available.
    setup     Download and verify the local models.

    Recordings and results: ~/Library/Application Support/ReMeet/Recordings
    """

    @MainActor
    static func main() async {
        do {
            let command = try parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .record(let language):
                try await record(language: language)
            case .process(let file, let language):
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw UsageError(message: "Audio file does not exist or is not a file: \(file.path)")
                }
                let session = try MeetingSession.create(language: language, importing: file)
                try await complete(session)
            case .resume(let directory):
                let session = try MeetingSession.open(directory)
                try await complete(session)
            case .setup:
                try await MeetingPipeline().prepareModels { progress($0) }
                print("Models ready.")
            case .help:
                print(help)
            }
        } catch let error as UsageError {
            progress(error.message)
            progress("Run remeet --help for usage.")
            exit(2)
        } catch {
            progress(error.localizedDescription)
            exit(1)
        }
    }

    @MainActor
    private static func record(language: String) async throws {
        guard let application = appURL() else {
            throw UsageError(message: "ReMeet.app is missing. Install the ReMeet Homebrew cask.")
        }
        let job = try RecordingJob.submit(language: language)
        defer { job.remove() }

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler { try? job.requestStop() }
        signalSource.resume()
        defer {
            signalSource.cancel()
            signal(SIGINT, SIG_DFL)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        var lastPhase: RecordingJob.Phase?
        let launched = ContinuousClock.now
        while !app.isTerminated {
            if let status = job.status, status.phase != lastPhase {
                lastPhase = status.phase
                switch status.phase {
                case .starting:
                    if let folder = status.directory { progress("Session: \(folder.path)") }
                    progress("Starting capture. Allow the macOS permissions if prompted.")
                case .recording:
                    progress("Recording system audio and microphone. Press Ctrl+C to stop.")
                case .paused:
                    progress("Recording paused.")
                case .saving:
                    progress("Saving recording…")
                case .transcribing:
                    progress("Transcribing and identifying speaker turns locally…")
                case .summarizing:
                    progress("Summarizing locally…")
                case .finished:
                    guard let directory = status.directory else { throw RecordingFailure(message: "ReMeet returned no session folder.") }
                    let session = try MeetingSession.open(directory)
                    print(session.transcript.path)
                    print(session.summary.path)
                    return
                case .failed:
                    if let directory = status.directory,
                       let session = try? MeetingSession.open(directory), session.canResume {
                        suggestRetry(directory)
                    }
                    throw RecordingFailure(message: status.message ?? "ReMeet could not finish this recording.")
                }
            }
            if lastPhase == nil, launched.duration(to: .now) > .seconds(20) {
                throw RecordingFailure(message: "ReMeet.app did not accept the recording request.")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw RecordingFailure(message: "ReMeet.app closed before the recording finished.")
    }

    @MainActor
    private static func appURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if Bundle(url: bundled)?.bundleIdentifier == "app.remeet.mac" { return bundled }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.remeet.mac")
    }

    private struct RecordingFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private static func complete(_ session: MeetingSession) async throws {
        progress("Session: \(session.directory.path)")
        do {
            try await session.complete(using: MeetingPipeline()) { stage in
                switch stage {
                case .transcribing: progress("Transcribing and identifying speaker turns locally…")
                case .summarizing: progress("Summarizing locally…")
                }
            }
        } catch {
            if session.canResume {
                suggestRetry(session.directory)
            }
            throw error
        }
        print(session.transcript.path)
        print(session.summary.path)
    }

    private static func parse(_ arguments: [String]) throws -> Command {
        guard let command = arguments.first, !arguments.contains("--help"), !arguments.contains("-h") else {
            return .help
        }

        var remaining = arguments.dropFirst()
        var positional: [String] = []
        var language: String?
        while let next = remaining.popFirst() {
            if next == "--language" {
                guard language == nil, let code = remaining.popFirst() else {
                    throw UsageError(message: "Supply one language code with --language.")
                }
                let normalized = code.lowercased()
                guard normalized == "auto" || ((2...3).contains(normalized.utf8.count) &&
                      normalized.utf8.allSatisfy({ (97...122).contains($0) })) else {
                    throw UsageError(message: "Use auto or a Whisper language code such as th, en, or ja.")
                }
                language = normalized
            } else if next.hasPrefix("-") {
                throw UsageError(message: "Unknown option: \(next)")
            } else {
                positional.append(next)
            }
        }

        switch (command, positional.count) {
        case ("record", 0):
            return .record(language: language ?? "auto")
        case ("process", 1):
            return .process(file: URL(fileURLWithPath: positional[0]).resolvingSymlinksInPath(), language: language ?? "auto")
        case ("resume", 1) where language == nil:
            return .resume(directory: URL(fileURLWithPath: positional[0], isDirectory: true))
        case ("setup", 0) where language == nil:
            return .setup
        default:
            throw UsageError(message: "Invalid command or arguments: \(command)")
        }
    }

    private static func suggestRetry(_ directory: URL) {
        progress("Retry with: remeet resume '\(directory.path.replacingOccurrences(of: "'", with: "'\\''"))'")
    }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
