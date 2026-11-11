import AVFoundation
import Foundation

public struct MeetingPipeline: Sendable {
    public init() {}

    public var modelsReady: Bool {
        ModelAsset.whisper.isReady && SpeakerDiarization.modelsReady && ModelAsset.summary.isReady
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("กำลังเตรียมโมเดลถอดเสียง Whisper…")
        _ = try await ModelDownloads.shared.resolve(.whisper)
        onProgress?("กำลังเตรียมโมเดลแยกผู้พูด…")
        try await SpeakerDiarization.prepareModels()
        onProgress?("กำลังเตรียมโมเดลสรุป Qwen…")
        _ = try await ModelDownloads.shared.resolve(.summary)
    }

    public func transcribe(audio: URL, into directory: URL, language: String, transcriptFilename: String) async throws -> URL {
        let code = try Self.languageCode(language)
        guard !transcriptFilename.isEmpty, !transcriptFilename.contains("/"),
              transcriptFilename.hasPrefix("transcript-"), transcriptFilename.hasSuffix(".txt") else {
            throw PipelineError("Invalid transcript filename.")
        }
        let tool = try EngineTool.locate("whisper-cli")
        let model = try await ModelDownloads.shared.resolve(.whisper)
        let files = FileManager.default
        let scratch = try Self.scratchDirectory(in: directory)
        defer { try? files.removeItem(at: scratch) }

        let pcm = scratch.appending(path: "audio.wav")
        try Self.prepareAudio(audio, output: pcm)
        let resultBase = scratch.appending(path: "whisper")
        _ = try await EngineTool.run(tool, arguments: [
            "-m", model.path, "-f", pcm.path, "-l", code, "-oj", "-of", resultBase.path, "-ml", "42", "-sow", "-np",
        ], scratch: scratch, captureOutput: false)
        let result = resultBase.appendingPathExtension("json")
        guard files.isReadableFile(atPath: result.path) else {
            throw PipelineError("Whisper did not write a transcript. Verify that the audio file is readable.")
        }
        let data = try Data(contentsOf: result)
        // Upstream can emit a split UTF-8 token in otherwise valid JSON.
        let json = try JSONDecoder().decode(WhisperTranscript.self, from: Data(String(decoding: data, as: UTF8.self).utf8))
        let segments = json.transcription.compactMap { segment -> TranscriptSegment? in
            let start = Double(segment.offsets.from) / 1_000
            let end = Double(segment.offsets.to) / 1_000
            guard start >= 0, end >= start, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return TranscriptSegment(start: start, end: end, text: segment.text)
        }
        guard !segments.isEmpty else {
            throw PipelineError("Whisper detected no speech. The original audio is still available at \(audio.path).")
        }

        let speakers = try await SpeakerDiarization.run(audio: pcm)
        let text = SpeakerTranscript.render(segments: segments, speakers: speakers)
        let output = directory.appending(path: transcriptFilename)
        try (text + "\n").write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    public func summarize(transcript: URL, into directory: URL, language _: String) async throws -> URL {
        guard transcript.isFileURL else { throw PipelineError("Choose a local transcript file.") }
        let text = try String(contentsOf: transcript, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PipelineError("The transcript is empty.") }

        let scratch = try Self.scratchDirectory(in: directory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let summary = try await LocalSummary().summarize(text, scratch: scratch)
        let output = directory.appending(path: "ai-summary.md")
        try (summary + "\n").write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    public static func prepareAudio(_ input: URL, output: URL) throws {
        guard input.isFileURL, (try? input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: input.path) else {
            throw PipelineError("Cannot read audio file at \(input.path).")
        }
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: input)
        } catch {
            throw PipelineError("Could not open audio. Choose a supported audio file such as WAV or M4A. \(error.localizedDescription)")
        }
        let format = source.processingFormat
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw PipelineError("Unable to configure 16 kHz mono audio.")
        }
        let destination = try AVAudioFile(forWriting: output, settings: pcm.settings)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw PipelineError("Unable to allocate an audio conversion buffer.")
        }
        if format == destination.processingFormat {
            let length = source.length
            while source.framePosition < length {
                let frames = min(length - source.framePosition, Int64(inputBuffer.frameCapacity))
                try source.read(into: inputBuffer, frameCount: AVAudioFrameCount(frames))
                guard inputBuffer.frameLength > 0 else { break }
                try destination.write(from: inputBuffer)
            }
        } else {
            try Self.convert(source, to: destination, inputBuffer: inputBuffer)
        }
        guard destination.length > 0 else { throw PipelineError("The audio file is empty.") }
    }

    private static func convert(_ source: AVAudioFile, to destination: AVAudioFile, inputBuffer: AVAudioPCMBuffer) throws {
        guard let converter = AVAudioConverter(from: source.processingFormat, to: destination.processingFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: destination.processingFormat, frameCapacity: 8_192) else {
            throw PipelineError("Unable to convert the input to 16 kHz mono audio.")
        }
        let stream = AudioConverterInput(source: source, buffer: inputBuffer)
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, status in
                stream.read(requested: requested, status: status)
            }
            if let inputError = stream.failure { throw inputError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try destination.write(from: outputBuffer) }
            if status == .endOfStream { break }
            guard status == .haveData else { throw PipelineError("Audio conversion stopped unexpectedly.") }
        }
    }

    private static func languageCode(_ language: String) throws -> String {
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code == "auto" || ((2...3).contains(code.utf8.count) && code.utf8.allSatisfy({ (97...122).contains($0) })) else {
            throw PipelineError("Use auto or a Whisper language code such as th or en.")
        }
        return code
    }

    private static func scratchDirectory(in directory: URL) throws -> URL {
        let scratch = directory.appending(path: ".processing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return scratch
    }
}

// AVAudioConverter calls its input block synchronously during convert(to:error:withInputFrom:).
private final class AudioConverterInput: @unchecked Sendable {
    let source: AVAudioFile
    let buffer: AVAudioPCMBuffer
    let length: AVAudioFramePosition
    private(set) var failure: Error?

    init(source: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.source = source
        self.buffer = buffer
        self.length = source.length
    }

    func read(requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let frames = min(length - source.framePosition, Int64(min(requested, buffer.frameCapacity)))
        guard frames > 0 else {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try source.read(into: buffer, frameCount: AVAudioFrameCount(frames))
            if buffer.frameLength > 0 {
                status.pointee = .haveData
                return buffer
            }
        } catch {
            failure = error
        }
        status.pointee = .endOfStream
        return nil
    }
}

private struct WhisperTranscript: Decodable {
    struct Segment: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }

        let offsets: Offsets
        let text: String
    }

    let transcription: [Segment]
}
