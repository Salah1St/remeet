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
                if entry.state.phase == .idle {
                    Link(destination: URL(string: "remeet://mode")!) { ReMeetModeChip() }
                } else {
                    ReMeetModeChip().opacity(0.55)
                }
                Spacer()
                if let start = entry.state.timerStart {
                    Text(start, style: .timer).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
            .font(.caption)
            .lineLimit(1)

            HStack(spacing: 12) {
                switch entry.state.phase {
                case .idle:
                    action("เริ่มอัด", icon: "record.circle", route: "record", emphasized: true)
                    action("นำเข้าไฟล์", icon: "square.and.arrow.up", route: "import")
                case .recording:
                    action("หยุดและถอดเสียง", icon: "stop.fill", route: "stop", token: entry.state.controlToken, emphasized: true)
                    ReMeetIconLabel("นำเข้าไฟล์", systemImage: "square.and.arrow.up").opacity(0.5)
                case .processing:
                    ReMeetIconLabel("กำลังบันทึก", systemImage: "stop.fill").opacity(0.5)
                    ReMeetIconLabel("นำเข้าไฟล์", systemImage: "square.and.arrow.up").opacity(0.5)
                }
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
