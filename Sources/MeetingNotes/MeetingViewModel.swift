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
    @Published private(set) var recordingPhase: WidgetState.Phase = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var session: MeetingSession?
    @Published private(set) var modelStatus = ""
    @Published private(set) var isPreparingModels = false
    @Published private(set) var updateStatus: String?
    @Published private(set) var isUpdating = false
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "meetingLanguage") }
    }

    private let recorder = MeetingRecorder()
    private let pipeline = MeetingPipeline()
    private let localInstallation = LocalInstallation.load()
    private var job: RecordingJob?
    private var controlToken: UUID?
    private var settingsWindow: NSWindow?
    private var confirmingExternal = false

    var isRecording: Bool { started != nil }
    var currentVersion: String { LocalInstallation.currentVersion }
    var updateButtonTitle: String { localInstallation == nil ? "ตรวจอัปเดต" : "อัปเดตเวอร์ชัน" }

    private init() {
        language = UserDefaults.standard.string(forKey: "meetingLanguage") ?? "auto"
        modelStatus = pipeline.modelsReady ? "โมเดลพร้อมใช้" : "ดาวน์โหลดโมเดลเมื่อเริ่มประมวลผลครั้งแรก"
        session = MeetingSession.latest()
        recorder.onInterruption = { [weak self] error in
            Task { await self?.finishRecording(interruption: error.localizedDescription) }
        }
        updateWidget(.idle)
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

    func finishRecording(interruption: String? = nil) async {
        guard isRecording, let session else { return }
        started = nil
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
        updateWidget(.processing)
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
        guard !isPreparingModels, !isUpdating else { return }
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

    func updateVersion() async {
        guard !isBusy, !isPreparingModels else { return }
        guard let localInstallation else {
            updateStatus = "ดูเวอร์ชันที่เผยแพร่บน GitHub หากติดตั้งผ่าน Brew ให้อัปเดตผ่าน Homebrew"
            open(LocalInstallation.releases)
            return
        }

        let previousStatus = status
        isBusy = true
        isUpdating = true
        status = "กำลังตรวจซอร์สสำหรับอัปเดต…"
        updateStatus = status
        defer {
            isBusy = false
            isUpdating = false
            status = previousStatus
        }

        do {
            updateStatus = try await localInstallation.update()
        } catch {
            updateStatus = error.localizedDescription
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
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: ReMeetSettings(model: self)))
            window.title = "ReMeet Settings"
            window.styleMask = [.titled, .closable]
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func handle(_ url: URL) {
        guard url.scheme == "remeet" else { return }
        switch url.host {
        case "settings": openSettings()
        case "mode": explainMode()
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
        case "stop":
            guard isRecording, let controlToken else { return }
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value
            guard token == controlToken.uuidString else { return }
            Task { await finishRecording() }
        default: break
        }
    }

    func explainMode() {
        guard !isBusy, !confirmingExternal else { return }
        confirmingExternal = true
        defer { confirmingExternal = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Live ยังไม่พร้อม"
        alert.informativeText = "ตอนนี้ ReMeet ใช้ After Stop เพื่อถอดเสียงและสรุปหลังหยุดอัด"
        alert.addButton(withTitle: "ตกลง")
        alert.runModal()
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
        updateWidget(.idle)
    }

    private func fail(_ error: Error) {
        status = "ทำรายการไม่สำเร็จ"
        issue = error.localizedDescription
        job?.publish(.failed, directory: session?.directory, message: error.localizedDescription)
        updateWidget(.idle)
    }

    private func updateWidget(_ phase: WidgetState.Phase) {
        guard phase != recordingPhase || phase == .idle else { return }
        recordingPhase = phase
        WidgetState(phase: phase, timerStart: phase == .recording ? started : nil,
                    controlToken: controlToken).save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetState.kind)
    }
}
