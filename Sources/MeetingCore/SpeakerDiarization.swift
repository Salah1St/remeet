import Foundation

struct SpeakerSpan: Sendable {
    let start: Double
    let end: Double
    let speaker: Int
}

enum SpeakerDiarization {
    private static let segmentation = ModelAsset(
        filename: "pyannote-segmentation-3.0.onnx",
        url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.onnx")!,
        sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
        overrideVariable: "REMEET_SEGMENTATION_MODEL"
    )

    private static let embedding = ModelAsset(
        filename: "3dspeaker-eres2net-base.onnx",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")!,
        sha256: "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b",
        overrideVariable: "REMEET_EMBEDDING_MODEL"
    )

    static var modelsReady: Bool {
        segmentation.isReady && embedding.isReady
    }

    static func prepareModels() async throws {
        _ = try await ModelDownloads.shared.resolve(segmentation)
        _ = try await ModelDownloads.shared.resolve(embedding)
    }

    // The pipeline passes the same 16 kHz mono PCM WAV to both Whisper and Sherpa.
    static func run(audio: URL) async throws -> [SpeakerSpan] {
        let executable = try EngineTool.locate("sherpa-onnx-offline-speaker-diarization")
        let segmentationURL = try await ModelDownloads.shared.resolve(segmentation)
        let embeddingURL = try await ModelDownloads.shared.resolve(embedding)
        let threads = min(4, ProcessInfo.processInfo.activeProcessorCount)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remeet-diarization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let output = try await EngineTool.run(executable, arguments: [
            "--print-args=false",
            "--segmentation.num-threads=\(threads)",
            "--embedding.num-threads=\(threads)",
            "--segmentation.pyannote-model=\(segmentationURL.path)",
            "--embedding.model=\(embeddingURL.path)",
            audio.path,
        ], scratch: scratch)
        return try parse(output)
    }

    private static func parse(_ output: String) throws -> [SpeakerSpan] {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let startIndex = lines.firstIndex(of: "Started") else {
            throw PipelineError("The speaker separation engine did not return a recognized result.")
        }
        return try lines.dropFirst(startIndex + 1).map { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 4, fields[1] == "--",
                  let start = Double(fields[0]), start.isFinite, start >= 0,
                  let end = Double(fields[2]), end.isFinite, end >= start,
                  fields[3].hasPrefix("speaker_"),
                  let speaker = Int(fields[3].dropFirst("speaker_".count)), speaker >= 0 else {
                throw PipelineError("The speaker separation engine returned an invalid time span.")
            }
            return SpeakerSpan(start: start, end: end, speaker: speaker)
        }
    }
}
