import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
public final class MeetingRecorder {
    public var onInterruption: ((Error) -> Void)?

    private struct Capture {
        let id: UUID
        let stream: SCStream
        let output: CaptureOutput
        let ffmpeg: URL
        let destination: URL
        var streamStopped = false
        var interruption: Error?
    }

    private var capture: Capture?
    private var transitioning = false

    public init() {}

    public func start(in directory: URL) async throws {
        guard capture == nil, !transitioning else { throw CaptureError.busy }
        transitioning = true
        defer { transitioning = false }

        guard let ffmpeg = AudioMix.ffmpeg() else { throw CaptureError.missingFFmpeg }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let systemAudio = directory.appendingPathComponent("system.caf")
        let microphoneAudio = directory.appendingPathComponent("microphone.caf")
        let destination = directory.appendingPathComponent("recording.wav")
        for path in [systemAudio, microphoneAudio, destination] {
            guard !FileManager.default.fileExists(atPath: path.path) else {
                throw CaptureError.outputExists(path)
            }
        }

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.microphonePermission
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.screenPermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 32
        config.height = 32
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let id = UUID()
        let output = CaptureOutput(systemAudio: systemAudio, microphoneAudio: microphoneAudio) { [weak self] error, stopped in
            Task { @MainActor in
                self?.handleInterruption(id: id, error: error, streamStopped: stopped)
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        capture = Capture(id: id, stream: stream, output: output, ffmpeg: ffmpeg, destination: destination)

        do {
            try await stream.startCapture()
        } catch {
            await output.finish()
            capture = nil
            throw error
        }

        if let interruption = capture?.interruption {
            if capture?.streamStopped == false { try? await stream.stopCapture() }
            await output.finish()
            capture = nil
            throw interruption
        }
    }

    public func stop() async throws -> URL {
        guard !transitioning else { throw CaptureError.busy }
        guard let capture else { throw CaptureError.notRecording }
        transitioning = true
        defer {
            self.capture = nil
            transitioning = false
        }

        var stopError: Error?
        if !capture.streamStopped {
            do { try await capture.stream.stopCapture() }
            catch { stopError = error }
        }
        try? capture.stream.removeStreamOutput(capture.output, type: .audio)
        try? capture.stream.removeStreamOutput(capture.output, type: .microphone)
        let tracks = await capture.output.finish()
        guard !tracks.isEmpty else {
            throw self.capture?.interruption ?? stopError ?? CaptureError.noAudio
        }

        let ffmpeg = capture.ffmpeg
        let destination = capture.destination
        return try await Task.detached(priority: .userInitiated) {
            try AudioMix.render(tracks, ffmpeg: ffmpeg, destination: destination)
        }.value
    }

    private func handleInterruption(id: UUID, error: Error, streamStopped: Bool) {
        guard capture?.id == id else { return }
        if streamStopped { capture?.streamStopped = true }
        guard capture?.interruption == nil else { return }
        capture?.interruption = error
        if !transitioning { onInterruption?(error) }
    }
}

private struct CapturedTrack: Sendable {
    let url: URL
    let firstTimestamp: CMTime
}

private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "meeting-notes.capture", qos: .userInitiated)
    private let onInterruption: @Sendable (Error, Bool) -> Void

    // Track state is only read or written on the stream's serial sample-handler queue.
    private var system: TrackWriter
    private var microphone: TrackWriter
    private var finished = false

    init(systemAudio: URL, microphoneAudio: URL, onInterruption: @escaping @Sendable (Error, Bool) -> Void) {
        system = TrackWriter(url: systemAudio)
        microphone = TrackWriter(url: microphoneAudio)
        self.onInterruption = onInterruption
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready,
              sampleBuffer.numSamples > 0 else { return }
        let timestamp = sampleBuffer.presentationTimeStamp
        do {
            switch type {
            case .audio: try system.append(sampleBuffer, at: timestamp)
            case .microphone: try microphone.append(sampleBuffer, at: timestamp)
            default: return
            }
        } catch {
            onInterruption(error, false)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterruption(error, true)
    }

    @discardableResult
    func finish() async -> [CapturedTrack] {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                continuation.resume(returning: [self.system.close(), self.microphone.close()].compactMap { $0 })
            }
        }
    }
}

private struct TrackWriter {
    let url: URL
    private var file: AVAudioFile?
    private var inputFormat: AVAudioFormat?
    private var firstTimestamp: CMTime?
    private var wroteAudio = false
    private var failed = false

    init(url: URL) { self.url = url }

    mutating func append(_ sample: CMSampleBuffer, at timestamp: CMTime) throws {
        guard !failed else { return }
        do {
            try write(sample, at: timestamp)
        } catch {
            failed = true
            throw CaptureError.trackFailure(url, error)
        }
    }

    private mutating func write(_ sample: CMSampleBuffer, at timestamp: CMTime) throws {
        guard timestamp.isNumeric,
              let description = sample.formatDescription?.audioStreamBasicDescription,
              description.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: [description]),
              format.sampleRate > 0 else {
            throw CaptureError.invalidAudio
        }

        if file == nil {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            inputFormat = format
            firstTimestamp = timestamp
        }
        guard let file, let firstTimestamp, format == inputFormat else { throw CaptureError.formatChanged }

        // Both outputs use the stream clock. Preserve gaps and discard overlapping samples.
        let seconds = CMTimeSubtract(timestamp, firstTimestamp).seconds
        let exactFrame = (seconds * format.sampleRate).rounded()
        guard let expectedFrame = Int64(exactly: exactFrame) else { throw CaptureError.invalidAudio }
        let distance = expectedFrame - file.framePosition
        let tolerance = Int64(format.sampleRate * 0.002)
        if distance > tolerance { try writeSilence(distance, to: file) }

        let overlap = distance < -tolerance ? min(-distance, Int64(sample.numSamples)) : 0
        let frames = sample.numSamples - Int(overlap)
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw CaptureError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: Int32(overlap), frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw CaptureError.copyAudio(status) }
        try file.write(from: buffer)
        wroteAudio = true
    }

    private func writeSilence(_ frames: Int64, to file: AVAudioFile) throws {
        guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
            throw CaptureError.invalidAudio
        }
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int64(silence.frameCapacity)))
            try file.write(from: silence)
            remaining -= Int64(silence.frameLength)
        }
    }

    mutating func close() -> CapturedTrack? {
        file = nil
        guard let firstTimestamp, wroteAudio else { return nil }
        return CapturedTrack(url: url, firstTimestamp: firstTimestamp)
    }
}

private enum AudioMix {
    private static let sampleRate = 16_000
    private static let downmix = "aresample=\(sampleRate):out_chlayout=mono:rematrix_maxval=1,aformat=sample_fmts=fltp"

    static func ffmpeg() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func render(_ tracks: [CapturedTrack], ffmpeg: URL, destination: URL) throws -> URL {
        let folder = destination.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".mix-\(UUID().uuidString).wav")
        let files = FileManager.default
        defer { try? files.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = ffmpeg
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n"] +
                tracks.flatMap { ["-i", $0.url.path] } +
                (try mixArguments(for: tracks)) +
                ["-ar", String(sampleRate), "-ac", "1", "-c:a", "pcm_s16le", "-rf64", "auto", temporary.path]
            try process.run()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CaptureError.ffmpegFailure(message.isEmpty ? "Exit code \(process.terminationStatus)." : message)
            }
            try files.moveItem(at: temporary, to: destination)
        } catch {
            throw CaptureError.mixFailure(folder, error)
        }

        for track in tracks { try? files.removeItem(at: track.url) }
        return destination
    }

    private static func mixArguments(for tracks: [CapturedTrack]) throws -> [String] {
        guard tracks.count > 1, let origin = tracks.map(\.firstTimestamp).min() else { return ["-af", downmix] }
        let filters = try tracks.enumerated().map { index, track in
            let offset = CMTimeSubtract(track.firstTimestamp, origin).seconds * Double(sampleRate)
            guard let samples = Int64(exactly: offset.rounded()), samples >= 0 else { throw CaptureError.invalidAudio }
            return "[\(index):a]\(downmix),adelay=\(samples)S:all=1[a\(index)]"
        }
        let inputs = tracks.indices.map { "[a\($0)]" }.joined()
        let mix = "\(inputs)amix=inputs=\(tracks.count):duration=longest:dropout_transition=0[out]"
        return ["-filter_complex", (filters + [mix]).joined(separator: ";"), "-map", "[out]"]
    }
}

private enum CaptureError: LocalizedError {
    case busy, notRecording, missingFFmpeg, microphonePermission, screenPermission, noDisplay, noAudio
    case invalidAudio, formatChanged, copyAudio(OSStatus), outputExists(URL), trackFailure(URL, Error)
    case ffmpegFailure(String), mixFailure(URL, Error)

    var errorDescription: String? {
        switch self {
        case .busy: return "A recording is active or changing state."
        case .notRecording: return "There is no active recording."
        case .missingFFmpeg: return "ffmpeg is required to mix the recording. Install it with `brew install ffmpeg`."
        case .microphonePermission: return "Enable Microphone access in System Settings > Privacy & Security, then reopen the app or terminal."
        case .screenPermission: return "Enable Screen & System Audio Recording in System Settings > Privacy & Security, then reopen the app or terminal."
        case .noDisplay: return "ScreenCaptureKit could not find a display for system audio capture."
        case .noAudio: return "The recording ended before macOS delivered any audio."
        case .invalidAudio: return "macOS returned an invalid audio buffer."
        case .formatChanged: return "The audio device changed its format during capture."
        case .copyAudio(let status): return "Could not copy captured audio (OSStatus \(status))."
        case .outputExists(let url): return "A recording file already exists at \(url.path)."
        case .trackFailure(let url, let error): return "Could not write \(url.lastPathComponent). \(error.localizedDescription)"
        case .ffmpegFailure(let message): return message
        case .mixFailure(let folder, let error): return "Could not mix the recording. Source tracks are in \(folder.path). \(error.localizedDescription)"
        }
    }
}
