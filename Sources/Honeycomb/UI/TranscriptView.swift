import HoneycombCore
import SwiftUI

/// The transcript beside the notes. While recording it stays pinned to the newest line unless
/// the user scrolls up.
struct TranscriptPanel: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            Text("Transcript")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                TranscriptView(meeting: meeting)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
            }
            .defaultScrollAnchor(meeting.id == model.recordingMeetingID ? .bottom : .top, for: .sizeChanges)
        }
    }
}

/// "Me" on the right and "Them" on the left, like a chat. While recording, an unfilled bubble
/// shows words still being spoken.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var lines: [TranscriptSegment] = []

    /// A time label starts a chunk at the first line, after a 30 s pause, or 2 minutes after the last label.
    static func chunkStarts(_ lines: [TranscriptSegment]) -> Set<Int> {
        var starts: Set<Int> = []
        var shownMs: Int64?
        for (index, line) in lines.enumerated() {
            let pause = index == 0 ? Int64.max : line.startMs - lines[index - 1].endMs
            if shownMs.map({ line.startMs - $0 >= 120_000 }) ?? true || pause >= 30_000 {
                starts.insert(index)
                shownMs = line.startMs
            }
        }
        return starts
    }

    var body: some View {
        let starts = Self.chunkStarts(lines)
        VStack(spacing: 16) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if starts.contains(index) {
                    Text(Duration.milliseconds(line.startMs).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                TranscriptRow(channel: line.channel, text: line.text, isPartial: false)
            }
            if meeting.id == model.recordingMeetingID {
                ForEach(Channel.allCases, id: \.self) { channel in
                    if let partial = model.partials[channel] {
                        TranscriptRow(channel: channel, text: partial.text, isPartial: true)
                    }
                }
                if lines.isEmpty && model.partials.isEmpty {
                    placeholder("Listening… lines appear a few seconds after people speak.")
                }
            } else if lines.isEmpty {
                placeholder(meeting.state == .transcribing ? "Transcribing…" : "No transcript.")
            }
        }
        .textSelection(.enabled)
        .task(id: meeting.id) {
            guard let database = model.database else { return }
            do {
                for try await lines in database.transcriptUpdates(meeting.id) { self.lines = lines }
            } catch {}
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TranscriptRow: View {
    let channel: Channel
    let text: String
    let isPartial: Bool

    private var isMe: Bool { channel == .me }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(3)
            .foregroundStyle(isPartial ? Color.textSecondary : Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isPartial ? Color.clear : isMe ? Color.accentSubtle : Color.primary.opacity(0.06), in: .rect(cornerRadius: 12))
            .overlay {
                if isPartial {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            .padding(isMe ? .leading : .trailing, 40)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isMe ? "Me" : "Them"): \(text)")
    }
}
