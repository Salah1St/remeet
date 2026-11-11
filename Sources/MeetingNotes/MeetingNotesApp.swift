import AppKit
import MeetingCore
import SwiftUI

@main
@MainActor
struct ReMeetApp: App {
    @NSApplicationDelegateAdaptor(ReMeetDelegate.self) private var delegate
    @StateObject private var model = MeetingViewModel.shared

    var body: some Scene {
        MenuBarExtra("ReMeet", systemImage: model.isRecording ? "record.circle.fill" : "waveform") {
            MeetingPanel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class ReMeetDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { MeetingViewModel.shared.handle(url) }
    }
}

@MainActor
private struct MeetingPanel: View {
    @ObservedObject var model: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ReMeetMark(size: 36)
                Text("ReMeet").font(.headline)
                Spacer()
                Button { model.openSettings() } label: {
                    ReMeetIconLabel("ตั้งค่า", systemImage: "gearshape", compact: true)
                }
                .buttonStyle(.plain)
                .help("ตั้งค่า")
            }

            HStack(spacing: 8) {
                Label("After Stop", systemImage: "checkmark")
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(ReMeetWaveform.tint.opacity(0.16), in: Capsule())
                Text("Live · เร็ว ๆ นี้")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(ReMeetControls.controlFill, in: Capsule())
            }
            .font(.caption.weight(.medium))

            HStack(spacing: 8) {
                if model.isRecording, let started = model.started {
                    Image(systemName: model.isPaused ? "pause.circle" : "record.circle.fill")
                        .foregroundStyle(model.isPaused ? Color.secondary : .red)
                    Text(model.isPaused ? "พักการอัดเสียง" : "กำลังอัดเสียง")
                    Spacer()
                    if let pausedAt = model.pausedAt {
                        Text(Duration.seconds(pausedAt.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    } else {
                        Text(started, style: .timer).monospacedDigit()
                    }
                } else {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.status)
                    Spacer()
                }
            }
            .font(.callout)
            .padding(10)
            .background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

            if let issue = model.issue {
                ScrollView {
                    Text(issue).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxHeight: 82)
            }

            HStack(spacing: 12) {
                if model.isRecording {
                    primaryAction("หยุดและถอดเสียง", systemImage: "stop.fill") {
                        Task { await model.finishRecording() }
                    }
                    Button {
                        Task { await model.togglePause() }
                    } label: {
                        ReMeetIconLabel(model.isPaused ? "อัดต่อ" : "พัก", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.plain)
                    .help(model.isPaused ? "อัดต่อ" : "พัก")
                } else {
                    primaryAction("เริ่มอัดเสียง", systemImage: "record.circle") {
                        Task { await model.start(language: model.language) }
                    }
                    Button { model.importAudio() } label: {
                        ReMeetIconLabel("นำเข้าไฟล์", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("นำเข้าไฟล์")
                }
            }
            .disabled(model.isBusy && !model.isRecording)

            if !model.isBusy, let session = model.session {
                Divider()
                HStack(spacing: 8) {
                    if session.hasTranscript {
                        Button("บทถอดเสียง") { model.open(session.transcript) }
                    }
                    if session.hasSummary {
                        Button("สรุป") { model.open(session.summary) }
                    }
                    if session.canResume {
                        Button(session.hasTranscript ? "ลองสรุปอีกครั้ง" : "ลองถอดเสียงอีกครั้ง") {
                            Task { await model.retry() }
                        }
                    }
                    Button("ไฟล์การประชุม") { model.open(session.directory) }
                }
            }

            HStack {
                Button("โฟลเดอร์การบันทึก", systemImage: "folder") { model.openLibrary() }
                Spacer()
                Button("ออก") { NSApp.terminate(nil) }.disabled(model.isBusy)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 380)
    }

    private func primaryAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(ReMeetWaveform.tint)
                Text(title).font(.body.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .frame(height: ReMeetControls.actionSize)
            .background(ReMeetControls.controlFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct ReMeetSettings: View {
    @ObservedObject var model: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("ภาษาที่พูด", selection: $model.language) {
                Text("ตรวจจับอัตโนมัติ").tag("auto")
                Text("ไทย").tag("th")
                Text("English").tag("en")
                Text("中文").tag("zh")
                Text("日本語").tag("ja")
                Text("한국어").tag("ko")
                Text("Tiếng Việt").tag("vi")
                Text("Bahasa Indonesia").tag("id")
                Text("Bahasa Melayu").tag("ms")
                Text("Français").tag("fr")
                Text("Deutsch").tag("de")
                Text("Español").tag("es")
            }
            Divider()
            Text(model.modelStatus).font(.callout).textSelection(.enabled)
            HStack {
                Button("เตรียมโมเดล") { Task { await model.prepareModels() } }
                    .disabled(model.isPreparingModels || model.isBusy)
                Button("โฟลเดอร์ผลลัพธ์", systemImage: "folder") { model.openLibrary() }
            }
            Divider()
            HStack {
                Text("เวอร์ชันปัจจุบัน \(model.currentVersion)")
                    .font(.callout.monospacedDigit())
                Spacer()
                if model.isUpdating { ProgressView().controlSize(.small) }
                Button(model.updateButtonTitle, systemImage: "arrow.clockwise") {
                    Task { await model.updateVersion() }
                }
                .disabled(model.isBusy || model.isPreparingModels)
            }
            if let updateStatus = model.updateStatus {
                Text(updateStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
