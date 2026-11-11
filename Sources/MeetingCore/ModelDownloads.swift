import CryptoKit
import Foundation

struct ModelAsset: Sendable {
    let filename: String
    let url: URL
    let sha256: String
    var overrideVariable: String? = nil

    static let whisper = ModelAsset(
        filename: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin")!,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        overrideVariable: "REMEET_WHISPER_MODEL"
    )

    static let summary = ModelAsset(
        filename: "Qwen3-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/a9a60d009fa7ff9606305047c2bf77ac25dbec49/Qwen3-4B-Q4_K_M.gguf")!,
        sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
        overrideVariable: "REMEET_SUMMARY_MODEL"
    )

    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["REMEET_MODELS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ReMeet/Models", directoryHint: .isDirectory)
    }

    var override: URL? {
        guard let overrideVariable, let path = ProcessInfo.processInfo.environment[overrideVariable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var destination: URL {
        Self.directory.appending(path: String(sha256.prefix(12)), directoryHint: .isDirectory).appending(path: filename)
    }

    var isReady: Bool {
        let file = override ?? destination
        return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

actor ModelDownloads {
    static let shared = ModelDownloads()
    private var pending: [URL: Task<URL, Error>] = [:]

    func resolve(_ model: ModelAsset) async throws -> URL {
        if let override = model.override {
            guard model.isReady else { throw PipelineError("Model file is missing: \(override.path)") }
            return override
        }
        if model.isReady { return model.destination }
        if let running = pending[model.destination] { return try await running.value }

        let download = Task.detached(priority: .utility) { try await Self.download(model) }
        pending[model.destination] = download
        defer { pending.removeValue(forKey: model.destination) }
        return try await download.value
    }

    private static func download(_ model: ModelAsset) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7_200
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(from: model.url)
        } catch {
            throw PipelineError("Download failed for \(model.filename). \(error.localizedDescription)")
        }
        let files = FileManager.default
        defer { try? files.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PipelineError("Model host returned HTTP \(code) for \(model.filename).")
        }
        guard try checksum(file) == model.sha256 else {
            throw PipelineError("Checksum verification failed for \(model.filename). Please retry the model download.")
        }

        let folder = model.destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = folder.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try files.moveItem(at: file, to: staging)
        do {
            try files.moveItem(at: staging, to: model.destination)
        } catch {
            // A separate CLI or app process may have finished the same verified download first.
            guard model.isReady else { throw error }
        }
        return model.destination
    }

    private static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
