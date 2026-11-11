import SwiftUI
import WidgetKit

private struct RecordingEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

private struct RecordingProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingEntry {
        RecordingEntry(date: .now, state: WidgetState(phase: .idle))
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordingEntry) -> Void) {
        completion(RecordingEntry(date: .now, state: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingEntry>) -> Void) {
        let now = Date()
        let entry = RecordingEntry(date: now, state: .load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900))))
    }
}

private struct RecordingWidgetView: View {
    let entry: RecordingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ReMeet", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                action("ตั้งค่า", icon: "gearshape", route: "settings")
            }

            HStack {
                Label("After Stop", systemImage: "checkmark")
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.indigo.opacity(0.13), in: Capsule())
                Text("Live · เร็ว ๆ นี้").foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
            .font(.caption)
            .lineLimit(1)

            HStack {
                Text(entry.state.phase.label).lineLimit(1)
                Spacer()
                if let start = entry.state.timerStart {
                    Text(start, style: .timer).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
            .font(.callout)

            HStack(spacing: 14) {
                if entry.state.phase == .recording {
                    action("พัก", icon: "pause.fill", route: "pause", token: entry.state.controlToken)
                } else if entry.state.phase == .paused {
                    action("อัดต่อ", icon: "play.fill", route: "resume", token: entry.state.controlToken)
                } else {
                    action("เริ่มอัด", icon: "record.circle", route: "record")
                }
                if entry.state.phase == .recording || entry.state.phase == .paused {
                    action("หยุด", icon: "stop.fill", route: "stop", token: entry.state.controlToken)
                }
                if Bundle.main.object(forInfoDictionaryKey: "ReMeetAppGroup") == nil {
                    action("พักหรืออัดต่อ", icon: "pause.fill", route: "toggle")
                    action("หยุด", icon: "stop.fill", route: "stop")
                }
                action("นำเข้าไฟล์", icon: "square.and.arrow.up", route: "import")
                Spacer()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func action(_ label: String, icon: String, route: String, token: UUID? = nil) -> some View {
        let suffix = token.map { "?token=\($0.uuidString)" } ?? ""
        return Link(destination: URL(string: "remeet://\(route)\(suffix)")!) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 24, height: 24)
                .accessibilityLabel(label)
        }
    }
}

@main
struct ReMeetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.kind, provider: RecordingProvider()) { entry in
            RecordingWidgetView(entry: entry)
        }
        .configurationDisplayName("ReMeet")
        .description("ควบคุมการบันทึกการประชุม")
        .supportedFamilies([.systemMedium])
    }
}
