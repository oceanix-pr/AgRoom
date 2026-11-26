import Foundation

public enum NoteSubtitleExporter {
    public static func srt(_ segments: [NoteSegment]) -> String {
        let sorted = segments.filter { $0.timestamp.isFinite && $0.timestamp >= 0 }.sorted { $0.timestamp < $1.timestamp }
        return sorted.enumerated().map { index, segment in
            let fallback = index + 1 < sorted.count ? max(segment.timestamp + 0.001, sorted[index + 1].timestamp) : segment.timestamp + 3
            let end = segment.endTimestamp.flatMap { $0.isFinite && $0 > segment.timestamp ? $0 : nil } ?? fallback
            let speaker = segment.speaker.isEmpty ? "" : segment.speaker + ": "
            let text = (speaker + segment.text).replacingOccurrences(of: "\r", with: "").components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: "\n")
            return "\(index + 1)\n\(time(segment.timestamp)) --> \(time(end))\n\(text)\n"
        }.joined(separator: "\n")
    }
    private static func time(_ seconds: Double) -> String {
        let milliseconds = Int(min(seconds * 1000, Double(Int.max / 2)).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
