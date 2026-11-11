import Foundation

struct TranscriptSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

enum SpeakerTranscript {
    private struct Line {
        let start: Double
        var end: Double
        let speaker: Int?
        var text: String
    }

    static func render(segments: [TranscriptSegment], speakers: [SpeakerSpan]) -> String {
        let names = [
            "มะลิ", "ฟ้า", "ใบชา", "ดาว", "ข้าวหอม", "ภูผา", "น้ำใส", "ตะวัน",
            "เมฆ", "สายลม", "แก้ว", "อิงฟ้า", "แสงจันทร์", "ต้นกล้า", "ชบา", "ไออุ่น",
        ].shuffled()
        let turns = speakers.sorted { $0.start < $1.start }
        var firstCandidate = turns.startIndex
        var lines: [Line] = []
        var aliases: [Int: String] = [:]

        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            while firstCandidate < turns.endIndex && turns[firstCandidate].end <= segment.start {
                firstCandidate += 1
            }
            let speaker = speaker(for: segment, candidates: turns[firstCandidate...])
            if let speaker, aliases[speaker] == nil {
                let index = aliases.count
                aliases[speaker] = index < names.count ? names[index] : "ผู้พูด \(index + 1)"
            }

            let text = segment.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            if let previous = lines.last, speaker != nil, previous.speaker == speaker,
               segment.start - previous.end <= 0.8, previous.text.count + text.count <= 96 {
                let index = lines.count - 1
                lines[index].end = max(previous.end, segment.end)
                lines[index].text += text
            } else {
                lines.append(Line(start: segment.start, end: segment.end, speaker: speaker, text: text))
            }
        }

        return lines.map { line in
            let alias = line.speaker.flatMap { aliases[$0] } ?? "ผู้พูดไม่ชัด"
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(timestamp(line.start))–\(timestamp(line.end))] \(alias) | \(text)"
        }.joined(separator: "\n")
    }

    private static func speaker(for segment: TranscriptSegment, candidates: ArraySlice<SpeakerSpan>) -> Int? {
        var durations: [Int: Double] = [:]
        for turn in candidates {
            if turn.start >= segment.end { break }
            let overlap = min(turn.end, segment.end) - max(turn.start, segment.start)
            if overlap > 0 { durations[turn.speaker, default: 0] += overlap }
        }
        guard let strongest = durations.max(by: { $0.value < $1.value }) else { return nil }
        let runnerUp = durations.filter { $0.key != strongest.key }.values.max() ?? 0
        return strongest.value > runnerUp * 1.1 ? strongest.key : nil
    }

    private static func timestamp(_ time: Double) -> String {
        let seconds = max(0, Int(exactly: time.rounded(.down)) ?? 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
