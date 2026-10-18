import HoneycombCore
import SwiftUI

/// One column: the meeting list, or the open meeting in its place. `model.selection` is the route,
/// so starting a recording or a new note opens that meeting, and clearing it goes back home.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showTranscript = false

    private var selected: Meeting? {
        model.selection.flatMap { id in model.meetings.first { $0.id == id } }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if let meeting = selected {
                // A plain HStack, not `.inspector` or HSplitView: on macOS 26 both of those count
                // a side column's width twice toward the window's minimum, which pushes the
                // content past the window's edges.
                HStack(spacing: 0) {
                    MeetingDetail(meeting: meeting)
                        .id(meeting.id)
                    if showTranscript {
                        Divider()
                        TranscriptPanel(meeting: meeting)
                            .containerRelativeFrame(.horizontal) { width, _ in min(360, max(260, width * 0.32)) }
                    }
                }
            } else {
                HomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: model.selection, initial: true) {
            showTranscript = model.selection != nil && model.selection == model.recordingMeetingID
        }
        .toolbar {
            if selected != nil {
                ToolbarItem(placement: .navigation) {
                    Button { model.selection = nil } label: { Label("All meetings", systemImage: "chevron.left") }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back to all meetings (⌘[)")
                }
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button { model.newNote() } label: { Label("New note", systemImage: "square.and.pencil") }
                    .help("New note for an upcoming call")
            }
            if selected != nil {
                ToolbarItem {
                    Button { showTranscript.toggle() } label: { Label("Transcript", systemImage: "text.bubble") }
                        .help(showTranscript ? "Hide the transcript" : "Show the transcript")
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                RecordButton()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $model.showAIChoice) {
            AIChoiceView()
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .overlay {
            if let error = model.startupError {
                ContentUnavailableView("Honeycomb can't start", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .background(.background)
            }
        }
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model
    var large = false

    var body: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            if model.isStartingRecording {
                Label("Starting…", systemImage: "hourglass")
            } else {
                Label(model.isRecording ? "Stop" : "Start notes", systemImage: model.isRecording ? "stop.fill" : "hexagon.fill")
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(HoneyButtonStyle(isRecording: model.isRecording, large: large))
        .help(model.isRecording ? "Stop recording (⇧⌘R)" : "Start taking notes (⇧⌘R)")
        .disabled(model.isStartingRecording)
    }
}
