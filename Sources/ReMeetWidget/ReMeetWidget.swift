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
    @Environment(\.colorScheme) private var colorScheme
    private var headerInk: Color { colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.12) }
    private var statusInk: Color { colorScheme == .dark ? Color(white: 0.68) : Color(white: 0.42) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ReMeetMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ReMeet").font(.system(size: 14, weight: .semibold)).foregroundColor(headerInk)
                    Text(entry.state.phase.label)
                        .font(.system(size: 11))
                        .foregroundColor(statusInk)
                        .lineLimit(1)
                }
                Spacer()
                action("ตั้งค่า", icon: "gearshape", route: "settings", compact: true)
            }

            HStack(spacing: 6) {
                Label("After Stop", systemImage: "checkmark")
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(ReMeetWaveform.tint.opacity(0.16), in: Capsule())
                Text("Live · เร็ว ๆ นี้").foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(ReMeetControls.controlFill, in: Capsule())
                Spacer()
                if let start = entry.state.timerStart {
                    Text(start, style: .timer).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
            .font(.caption)
            .lineLimit(1)

            HStack(spacing: 12) {
                if entry.state.phase == .recording {
                    action("พัก", icon: "pause.fill", route: "pause", token: entry.state.controlToken)
                } else if entry.state.phase == .paused {
                    action("อัดต่อ", icon: "play.fill", route: "resume", token: entry.state.controlToken)
                } else {
                    action("เริ่มอัด", icon: "record.circle", route: "record", emphasized: true)
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
        .containerBackground(for: .widget) {
            if colorScheme == .dark {
                Color(red: 0.09, green: 0.09, blue: 0.09)
            } else {
                Rectangle().fill(.background)
            }
        }
    }

    private func action(_ label: String, icon: String, route: String, token: UUID? = nil,
                        compact: Bool = false, emphasized: Bool = false) -> some View {
        let suffix = token.map { "?token=\($0.uuidString)" } ?? ""
        return Link(destination: URL(string: "remeet://\(route)\(suffix)")!) {
            ReMeetIconLabel(label, systemImage: icon, compact: compact, emphasized: emphasized)
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
