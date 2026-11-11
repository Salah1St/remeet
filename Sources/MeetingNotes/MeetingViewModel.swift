import AppKit
import Combine
import MeetingCore
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

@MainActor
final class MeetingViewModel: ObservableObject {
    static let shared = MeetingViewModel()

    @Published private(set) var status = "พร้อมอัดเสียง"
    @Published private(set) var issue: String?
    @Published private(set) var started: Date?
    @Published private(set) var pausedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var session: MeetingSession?
    @Published private(set) var modelStatus = ""
    @Published private(set) var isPreparingModels = false
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "meetingLanguage") }
    }

    private let recorder = MeetingRecorder()
    private let pipeline = MeetingPipeline()
    private var job: RecordingJob?
    private var controlToken: UUID?
    private var settingsWindow: NSWindow?
    private var confirmingExternal = false
    private var changingPause = false

    var isRecording: Bool { started != nil }
    var isPaused: Bool { pausedAt != nil }

    private init() {
        language = UserDefaults.standard.string(forKey: "meetingLanguage") ?? "auto"
        modelStatus = pipeline.modelsReady ? "โมเดลพร้อมใช้" : "ดาวน์โหลดโมเดลเมื่อเริ่มประมวลผลครั้งแรก"
        session = MeetingSession.latest()
        recorder.onInterruption = { [weak self] error in
            Task { await self?.finishRecording(interruption: error.localizedDescription) }
        }
        updateWidget(session?.hasSummary == true ? .finished : .idle)
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        for pending in RecordingJob.takePending() {
            Task { await start(language: pending.language, job: pending) }
        }
        if isRecording, job?.stopRequested == true {
            Task { await finishRecording() }
        }
    }

    func start(language: String, job request: RecordingJob? = nil) async {
        guard !isBusy else {
            request?.publish(.failed, message: "ReMeet already has an active recording or processing job.")
            return
        }
        if request?.stopRequested == true {
            request?.publish(.failed, message: "Recording canceled before it started.")
            return
        }
        job = request
        isBusy = true
        issue = nil
        status = "กำลังเริ่มอัดเสียง…"
        do {
            let current = try MeetingSession.create(language: language)
            session = current
            request?.publish(.starting, directory: current.directory)
            try await recorder.start(in: current.directory)
            started = Date()
            controlToken = UUID()
            request?.publish(.recording, directory: current.directory)
            updateWidget(.recording)
        } catch {
            fail(error)
            isBusy = false
            job = nil
        }
    }

    func togglePause() async {
        guard isRecording, !changingPause else { return }
        changingPause = true
        defer { changingPause = false }
        do {
            let pause = !isPaused
            try await recorder.setPaused(pause)
            guard isRecording else { return }
            if pause {
                pausedAt = Date()
            } else if let pausedAt, let started {
                self.started = started.addingTimeInterval(Date().timeIntervalSince(pausedAt))
                self.pausedAt = nil
            }
            job?.publish(pause ? .paused : .recording, directory: session?.directory)
            updateWidget(pause ? .paused : .recording)
        } catch {
            issue = error.localizedDescription
        }
    }

    func finishRecording(interruption: String? = nil) async {
        guard isRecording, let session else { return }
        started = nil
        pausedAt = nil
        controlToken = nil
        status = "กำลังบันทึกไฟล์เสียง…"
        job?.publish(.saving, directory: session.directory)
        updateWidget(.processing)
        defer {
            isBusy = false
            job = nil
        }

        do {
            let audio = try await recorder.stop()
            try await process(session, audio: audio)
            if let interruption {
                issue = "การอัดเสียงหยุดก่อนกำหนด รายงานใช้เสียงที่บันทึกไว้แล้ว\n\(interruption)"
            }
        } catch {
            fail(error)
        }
    }

    func importAudio() {
        guard !isBusy else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self.processImportedAudio(url) }
        }
    }

    private func processImportedAudio(_ url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        issue = nil
        status = "กำลังนำเข้าไฟล์…"
        defer { isBusy = false }
        do {
            let selectedLanguage = language
            let imported = try await Task.detached(priority: .userInitiated) {
                try MeetingSession.create(language: selectedLanguage, importing: url)
            }.value
            session = imported
            try await process(imported)
        } catch {
            fail(error)
        }
    }

    func retry() async {
        guard !isBusy, let session, session.canResume else { return }
        isBusy = true
        issue = nil
        defer { isBusy = false }

        do {
            try await process(session)
        } catch {
            fail(error)
        }
    }

    func prepareModels() async {
        guard !isPreparingModels else { return }
        isPreparingModels = true
        defer { isPreparingModels = false }
        do {
            try await pipeline.prepareModels { [weak self] progress in
                Task { @MainActor in
                    if self?.isPreparingModels == true { self?.modelStatus = progress }
                }
            }
            modelStatus = "โมเดลพร้อมใช้"
        } catch {
            modelStatus = error.localizedDescription
        }
    }

    func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            issue = "เปิดไฟล์หรือโฟลเดอร์นี้ไม่ได้\n\(url.path)"
        }
    }

    func openLibrary() {
        let library = MeetingSession.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            open(library)
        } catch {
            issue = error.localizedDescription
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReMeetSettings(model: self)))
            window.title = "ReMeet Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func handle(_ url: URL) {
        guard url.scheme == "remeet" else { return }
        switch url.host {
        case "settings": openSettings()
        case "import": importAudio()
        case "record":
            guard !isBusy, !confirmingExternal else { return }
            confirmingExternal = true
            defer { confirmingExternal = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "เริ่มอัดเสียงใน ReMeet"
            alert.informativeText = "ReMeet จะอัดเสียงระบบและไมโครโฟน"
            alert.addButton(withTitle: "เริ่มอัด")
            alert.addButton(withTitle: "ยกเลิก")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await start(language: language) }
            }
        case "pause", "resume", "stop", "toggle":
            guard isRecording else { return }
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value
            if token != controlToken?.uuidString {
                guard Bundle.main.object(forInfoDictionaryKey: "ReMeetAppGroup") == nil,
                      !confirmingExternal, url.host == "toggle" || url.host == "stop" else { return }
                confirmingExternal = true
                defer { confirmingExternal = false }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = url.host == "stop" ? "หยุดและประมวลผลการบันทึกนี้" :
                    (isPaused ? "อัดเสียงต่อ" : "พักการอัดเสียง")
                alert.addButton(withTitle: "ยืนยัน")
                alert.addButton(withTitle: "ยกเลิก")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            if url.host == "stop" {
                Task { await finishRecording() }
            } else if url.host == "toggle" || (url.host == "pause" && !isPaused) || (url.host == "resume" && isPaused) {
                Task { await togglePause() }
            }
        default: break
        }
    }

    private func process(_ session: MeetingSession, audio: URL? = nil) async throws {
        updateWidget(.processing)
        try await session.complete(using: pipeline, audio: audio) { stage in
            switch stage {
            case .transcribing:
                status = "กำลังถอดเสียงและแยกผู้พูด…"
                job?.publish(.transcribing, directory: session.directory)
            case .summarizing:
                status = "กำลังสรุปการประชุม…"
                job?.publish(.summarizing, directory: session.directory)
            }
        }
        status = "สรุปการประชุมพร้อมแล้ว"
        if pipeline.modelsReady && !isPreparingModels { modelStatus = "โมเดลพร้อมใช้" }
        job?.publish(.finished, directory: session.directory)
        updateWidget(.finished)
    }

    private func fail(_ error: Error) {
        status = "ทำรายการไม่สำเร็จ"
        issue = error.localizedDescription
        job?.publish(.failed, directory: session?.directory, message: error.localizedDescription)
        updateWidget(.failed)
    }

    private func updateWidget(_ phase: WidgetState.Phase) {
        WidgetState(phase: phase, timerStart: phase == .recording ? started : nil,
                    controlToken: controlToken).save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetState.kind)
    }
}
