import HoneycombCore
import SwiftUI

/// The home screen: every meeting, newest day first, in one centred column.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Meetings")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.56)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                if model.meetings.isEmpty {
                    HomeEmpty()
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(groups, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.horizontal, 8)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.meetings) { meeting in
                                    MeetingRow(meeting: meeting, isRecording: meeting.id == model.recordingMeetingID) {
                                        model.selection = meeting.id
                                    }
                                    .contextMenu {
                                        Button("Delete", role: .destructive) { model.delete(meeting) }
                                            .disabled(meeting.id == model.recordingMeetingID)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if let activity = model.modelActivity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.callout).foregroundStyle(Color.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(in: .capsule)
                .padding(.bottom, 16)
            }
        }
    }

    private struct Group {
        let day: Date
        let title: String
        let meetings: [Meeting]
    }

    private var groups: [Group] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: model.meetings) { calendar.startOfDay(for: $0.startAt ?? $0.createdAt) }
        return byDay.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = day.formatted(.dateTime.weekday(.abbreviated).month(.wide).day())
            }
            return Group(day: day, title: title, meetings: byDay[day] ?? [])
        }
    }
}

private struct HomeEmpty: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accent)
            Text("No meetings yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Start notes when a call begins. Honeycomb records both sides and writes the notes for you.")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            RecordButton(large: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    let open: () -> Void
    @State private var hovering = false

    private var subtitle: String {
        var parts: [String] = []
        if let duration = meeting.durationMs {
            parts.append(Duration.milliseconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        if let label = meeting.state.label { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    private var symbol: (name: String, color: Color) {
        if isRecording { return ("record.circle.fill", .recording) }
        switch meeting.state {
        case .draft: return ("square.and.pencil", .textSecondary)
        case .transcribing, .writingNotes: return ("sparkles", .accentText)
        case .failed, .interrupted: return ("exclamationmark.triangle", .warning)
        default: return ("doc.text", .textSecondary)
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: symbol.name)
                    .font(.system(size: 15))
                    .foregroundStyle(symbol.color)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(meeting.title)
                        .font(.system(size: 16))
                        .tracking(-0.32)
                        .foregroundStyle(Color.textPrimary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                Text((meeting.startAt ?? meeting.createdAt).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 48)
            .background(hovering ? Color.accentSubtle : .clear, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(meeting.title)
    }
}

extension MeetingState {
    /// Short status shown under a meeting's title. Nil when nothing needs saying.
    var label: String? {
        switch self {
        case .draft: "Draft"
        case .recording: "Recording"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .transcribing: "Transcribing"
        case .tooShort: "Too short for notes"
        case .waiting: "Waiting"
        case .writingNotes: "Writing notes"
        case .indexing, .ready: nil
        case .failed: "Failed"
        }
    }
}
