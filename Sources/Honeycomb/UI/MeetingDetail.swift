import AVFoundation
import HoneycombCore
import SwiftUI

struct MeetingDetail: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var title = ""
    @State private var tab = NotesTab.mine
    @State private var versions: [EnhancedNote] = []
    @State private var pinned: UUID?

    enum NotesTab: Hashable {
        case ai
        case mine
    }

    /// A generating version left by a crash would lock the editor read-only, so it counts only
    /// while the meeting is really writing notes.
    private var generating: EnhancedNote? {
        versions.first { $0.status == .generating && meeting.state == .writingNotes }
    }

    private var current: EnhancedNote? {
        guard let generating else { return versions.first { $0.id == meeting.currentEnhancedId } }
        return versions.first { $0.id == pinned } ?? generating
    }

    private var hasAINotes: Bool { current != nil }

    /// "Oct 17, 6:53 PM", with the year only for meetings from another year.
    private var startedAt: String {
        let date = meeting.startAt ?? meeting.createdAt
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? date.formatted(format) : date.formatted(format.year())
    }

    private var statusFill: Color {
        switch meeting.state {
        case .failed, .interrupted: .warningSubtle
        case .recording, .transcribing, .writingNotes: .accentSubtle
        default: .clear
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.56)
                    .foregroundStyle(Color.textPrimary)
                    .onSubmit { model.rename(meeting, to: title) }
                HStack(spacing: 8) {
                    Chip { Label(startedAt, systemImage: "calendar") }
                    if let duration = meeting.durationMs {
                        Chip { Label(Duration.milliseconds(duration).formatted(.time(pattern: .hourMinuteSecond)), systemImage: "clock") }
                    }
                    if let label = meeting.state.label {
                        Chip(fill: statusFill) { Text(label) }
                    }
                    if meeting.id != model.recordingMeetingID, meeting.audioDir != nil {
                        AudioTracks(folder: model.paths.audioFolder(for: meeting.id))
                    }
                }
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 10) {
                    if meeting.id == model.recordingMeetingID {
                        LiveStatus(status: model.status)
                    }
                    MeetingStateBanner(meeting: meeting)
                    if current?.errorCode == ProviderError.truncated.code, meeting.state != .writingNotes {
                        Banner(text: "These notes were cut short because the model hit its length limit.", action: "Regenerate") {
                            model.regenerate(meeting, template: meeting.templateId ?? "general")
                        }
                    }
                    if hasAINotes {
                        HStack {
                            Picker("", selection: $tab) {
                                Text("AI notes").tag(NotesTab.ai)
                                Text("My notes").tag(NotesTab.mine)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            // macOS puts a white label on the selected segment; on `accentStrong` that is under 4.5:1.
                            .tint(.accentText)
                            Spacer()
                            if tab == .ai {
                                NotesMenu(meeting: meeting, versions: versions, shown: current, generating: generating?.id) { version in
                                    pinned = version.id
                                    if version.status == .done { model.useVersion(version, of: meeting) }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)

            NotesEditor(meeting: meeting, tab: hasAINotes ? tab : .mine, current: current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: Bindable(model).sourceQuote) { quote in
            VStack(alignment: .leading, spacing: 12) {
                Text("From the transcript").font(.headline)
                ForEach(quote.lines) { line in
                    TranscriptRow(channel: line.channel, text: line.text, isPartial: false)
                }
                HStack {
                    Spacer()
                    Button("Done") { model.sourceQuote = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .onAppear { title = meeting.title }
        .onChange(of: meeting.title) { old, new in if title == old { title = new } }
        .onDisappear { model.rename(meeting, to: title) }
        .onChange(of: generating?.id) { pinned = nil }
        // Switching while the user types in My notes would send their next keystrokes into the AI notes.
        .onChange(of: hasAINotes) { tab = hasAINotes && !EditorHost.shared.isFocused ? .ai : .mine }
        .task(id: meeting.id) {
            guard let database = model.database else { return }
            do {
                for try await versions in database.enhancedUpdates(meeting.id) { self.versions = versions }
            } catch {}
        }
    }
}

/// Loads the right document into the shared editor and saves edits back to SQLite.
struct NotesEditor: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let tab: MeetingDetail.NotesTab
    let current: EnhancedNote?

    /// My notes never depend on the AI version, so nothing about it reloads them under the user.
    private var key: String {
        switch tab {
        case .mine: "\(meeting.id)-mine"
        case .ai: "\(meeting.id)-ai-\(current?.id.uuidString ?? "none")-\(current?.status.rawValue ?? "")"
        }
    }

    var body: some View {
        EditorView()
            .onAppear(perform: load)
            .onChange(of: key) { load() }
            .onChange(of: current?.markdown) {
                guard tab == .ai, let current, current.status == .generating else { return }
                EditorHost.shared.streamUpdate(document(current))
            }
    }

    private func document(_ note: EnhancedNote) -> PMNode {
        note.doc.flatMap(PMNode.decode)
            ?? Authorship.apply(to: Markdown.document(note.markdown), userNotes: (try? model.database?.userNote(meeting.id))??.markdown ?? "")
    }

    private func load() {
        let host = EditorHost.shared
        guard let database = model.database else { return }
        switch tab {
        case .mine:
            let note = try? database.userNote(meeting.id)
            let doc = note?.doc.flatMap(PMNode.decode) ?? note.map { Markdown.document($0.markdown) }
            let id = meeting.id
            host.load(doc, editable: true,
                      placeholder: "Write notes if you like. Honeycomb writes the full notes when the call ends.") { doc in
                try? database.saveUserNote(UserNote(meetingId: id, doc: doc.encoded(), markdown: Markdown.markdown(doc)))
            }
            host.setSources([])
        case .ai:
            guard var note = current else { return }
            if note.status == .generating {
                host.load(document(note), editable: false, placeholder: "Writing notes…", onChange: nil)
                return
            }
            host.load(document(note), editable: true, placeholder: "", onChange: { doc in
                note.doc = doc.encoded()
                note.markdown = Markdown.markdown(doc)
                try? database.saveEnhanced(note)
            }, onSource: { block, _ in
                model.showSource(block, enhanced: note.id)
            })
            host.setSources((try? database.sourcedBlocks(note.id)) ?? [])
        }
    }
}

/// Versions of the AI notes, Regenerate, and the template to use.
struct NotesMenu: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let versions: [EnhancedNote]
    let shown: EnhancedNote?
    let generating: UUID?
    let pick: (EnhancedNote) -> Void

    var body: some View {
        Menu {
            Section("Regenerate with") {
                ForEach(model.templates) { template in
                    Button(template.name + (template.id == (meeting.templateId ?? "general") ? " ✓" : "")) {
                        model.regenerate(meeting, template: template.id)
                    }
                }
            }
            if versions.count > 1 {
                Section("Versions") {
                    ForEach(versions) { version in
                        Button(version.createdAt.formatted(date: .abbreviated, time: .shortened)
                               + (version.id == shown?.id ? " ✓" : "")) {
                            pick(version)
                        }
                        .disabled(version.status != .done && version.id != generating)
                    }
                }
            }
            Divider()
            Button("Copy notes") { if let shown { model.copyNotes(shown) } }
        } label: {
            Label("Notes options", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.iconOnly)
        .help("Notes options")
        .fixedSize()
        .disabled(meeting.id == model.recordingMeetingID)
    }
}

/// Explains a meeting that needs attention, with the one action that fixes it.
struct MeetingStateBanner: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        switch meeting.state {
        case .tooShort:
            Banner(text: "This meeting is under 50 words, so Honeycomb didn't write notes.", action: "Write notes anyway") {
                model.enhanceAnyway(meeting)
            }
        case .failed:
            Banner(text: meeting.stateDetail.flatMap(ProviderError.init(code:))?.message ?? "Something went wrong processing this meeting.",
                   action: "Retry", isWarning: true) { model.retry(meeting) }
        case .waiting:
            switch meeting.waitReason {
            case .modelMissing:
                modelMissing
            case .modelBusy, nil:
                Banner(text: "Waiting for the current recording to end.")
            }
        case .interrupted:
            Banner(text: "Honeycomb quit during this recording. The audio up to that point is being recovered.")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var modelMissing: some View {
        let id = model.notesModel
        let name = ModelCatalog.spec(id)?.name ?? "the AI model"
        switch model.modelStates[id] ?? .missing {
        case .missing:
            Banner(text: "Notes need \(name), which isn't downloaded yet.", action: "Download") { model.downloadModel(id) }
        case .failed(let code):
            Banner(text: "The \(name) download failed. \(ModelDownloadRow.failureMessage(code))", action: "Retry download", isWarning: true) {
                model.downloadModel(id)
            }
        default:
            Banner(text: "Waiting for \(name) to finish downloading.")
        }
    }
}

struct Banner: View {
    let text: String
    var action: String?
    var isWarning = false
    var perform: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isWarning ? Color.warning : Color.accentText)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(HoneyButtonStyle())
                    .fixedSize()
            }
        }
        .padding(12)
        .background(isWarning ? Color.warningSubtle : Color.accentSubtle, in: .rect(cornerRadius: 12))
    }
}

struct LiveStatus: View {
    let status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(status.isPaused ? "Paused" : "Recording")
                    .foregroundStyle(status.isHealthy ? Color.textPrimary : Color.recordingText)
            } icon: {
                Image(systemName: status.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(status.isPaused ? Color.accentStrong : Color.recording)
            }
            .font(.system(size: 13, weight: .semibold))
            LevelRow(label: "Me", track: status.tracks[.me] ?? .init())
            LevelRow(label: "Them", track: status.tracks[.them] ?? .init())
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct LevelRow: View {
    let label: String
    let track: RecordingStatus.Track

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 44, alignment: .leading)
            LevelMeter(level: track.level)
                .frame(height: 6)
            Text(track.health.label)
                .font(.caption)
                .foregroundStyle(track.health == .ok ? Color.textSecondary : Color.recordingText)
                .frame(width: 90, alignment: .trailing)
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentStrong).frame(width: proxy.size.width * CGFloat(min(1, sqrt(level) * 1.6)))
            }
        }
    }
}

extension TrackHealth {
    var label: String {
        switch self {
        case .ok: "OK"
        case .recovering: "Reconnecting"
        case .lost: "Capture lost"
        }
    }
}

/// Plays both recorded tracks together, so you can check they line up.
struct AudioTracks: View {
    let folder: URL
    @State private var player = TrackPlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle(folder: folder)
            } label: {
                Chip { Label(player.isPlaying ? "Pause" : "Play recording", systemImage: player.isPlaying ? "pause.fill" : "play.fill") }
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
            }
        }
        .onDisappear { player.stop() }
    }
}

@MainActor
@Observable
final class TrackPlayer {
    private(set) var isPlaying = false
    private(set) var error: String?
    private var engine: AVAudioEngine?
    private var playback = UUID()
    private var buffersLeft = 0

    func toggle(folder: URL) {
        if isPlaying {
            stop()
            return
        }
        guard let meta = try? SessionMeta.read(from: folder) else {
            error = "No audio for this meeting."
            return
        }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: AACSegmentWriter.sampleRate, channels: 1)!
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        let playback = UUID()
        var scheduled = 0
        var nodes: [AVAudioPlayerNode] = []
        for track in meta.tracks {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            node.pan = track.channel == .me ? -0.4 : 0.4
            for segment in track.segments {
                guard let samples = try? AudioSegmentReader.samples(of: segment, in: folder), !samples.isEmpty,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
                else { continue }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                let when = AVAudioTime(sampleTime: AVAudioFramePosition(Double(segment.startOffsetMs) * 16), atRate: AACSegmentWriter.sampleRate)
                node.scheduleBuffer(buffer, at: when, completionCallbackType: .dataPlayedBack) { _ in
                    Task { @MainActor [weak self] in self?.bufferPlayed(playback) }
                }
                scheduled += 1
            }
            nodes.append(node)
        }
        guard scheduled > 0 else {
            error = "No audio for this meeting."
            return
        }
        do {
            try engine.start()
            for node in nodes { node.play(at: start) }
            self.engine = engine
            self.playback = playback
            buffersLeft = scheduled
            isPlaying = true
            error = nil
        } catch {
            self.error = "Couldn't play the audio."
        }
    }

    /// Callbacks from a stopped or replaced playback carry an old ID and are ignored.
    private func bufferPlayed(_ id: UUID) {
        guard id == playback, isPlaying else { return }
        buffersLeft -= 1
        if buffersLeft == 0 { stop() }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isPlaying = false
    }
}
