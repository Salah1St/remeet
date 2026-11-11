import Foundation

enum EngineTool {
    static func locate(_ name: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        if let override = environment["REMEET_HELPERS_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else if let executable = Bundle.main.executableURL {
            directory = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Helpers", directoryHint: .isDirectory)
        } else {
            throw PipelineError("Unable to locate the ReMeet app bundle.")
        }
        let tool = directory.appending(path: name)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw PipelineError("The ReMeet package is missing \(name). Reinstall the app or check REMEET_HELPERS_DIR.")
        }
        return tool
    }

    static func run(_ executable: URL, arguments: [String], scratch: URL, captureOutput: Bool = true) async throws -> String {
        try Task.checkCancellation()
        let files = FileManager.default
        let key = UUID().uuidString
        let output = scratch.appending(path: "\(key).stdout")
        let log = scratch.appending(path: "\(key).stderr")
        defer {
            try? files.removeItem(at: output)
            try? files.removeItem(at: log)
        }
        guard files.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              files.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PipelineError("Could not create local processing logs.")
        }
        let outHandle = try FileHandle(forWritingTo: output)
        let logHandle = try FileHandle(forWritingTo: log)
        defer {
            try? outHandle.close()
            try? logHandle.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LLAMA_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = captureOutput ? outHandle : FileHandle.nullDevice
        process.standardError = logHandle

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        guard exitCode == 0 else {
            let reason = (try? logTail(log)).flatMap { $0.isEmpty ? nil : $0 } ?? "Exit status \(exitCode)."
            throw PipelineError("\(executable.lastPathComponent) failed. \(reason)")
        }
        return try String(contentsOf: output, encoding: .utf8)
    }

    private static func logTail(_ log: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length - min(length, 2_000))
        let data = try handle.read(upToCount: 2_000) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PipelineError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
