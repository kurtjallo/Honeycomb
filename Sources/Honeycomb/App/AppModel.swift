import AppKit
import HoneycombCore
import Observation
import SwiftUI

/// The app's state for SwiftUI. Logic lives in HoneycombCore; this only wires it to the UI.
@MainActor
@Observable
final class AppModel {
    private(set) var database: AppDatabase?
    private(set) var meetings: [Meeting] = []
    var selection: UUID?
    private(set) var lifecycle = RecordingLifecycle()
    private(set) var status = RecordingStatus()
    var showConsent = false
    var alert: AppAlert?
    var startupError: String?

    private(set) var partials: [Channel: TranscriptLine] = [:]
    private(set) var templates: [TemplateRecord] = BuiltInTemplates.all
    var sourceQuote: SourceQuote?
    private(set) var modelStates: [String: ModelStore.State] = [:]
    private(set) var providers: [ProviderRecord] = []
    private(set) var routes: [AITask: Route] = [:]
    var showAIChoice = false
    private static let aiChoiceAskedKey = "honeycomb.aiChoiceAsked"

    let paths = Paths.standard
    private(set) var store: ModelStore?
    private(set) var host: ModelHost?
    private(set) var pipeline: Pipeline?
    private var router: ProviderRouter?
    private var recorder: MeetingRecorder?
    private var modelTask: Task<Void, Never>?
    private var detector: CallDetector?
    private var routeChanges = 0
    /// Seconds left before an automatic stop, while the user can still keep recording.
    private(set) var autoStopCountdown: Int?
    private let launchedAt = ContinuousClock.now
    private var starting: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    let pill = RecordingPillController()

    var isRecording: Bool { lifecycle.phase.meetingID != nil }
    var isStartingRecording: Bool { lifecycle.phase.isStarting }
    var isStoppingRecording: Bool { lifecycle.phase.isStopping }
    var recordingMeetingID: UUID? { lifecycle.phase.meetingID }

    func launch() {
        do {
            try paths.createFolders()
            let database = try AppDatabase.open(at: paths.database, backups: paths.backups)
            self.database = database
            let store = ModelStore(root: paths.models, database: database)
            let host = ModelHost(store: store)
            let pipeline = Pipeline(database: database, paths: paths, host: host)
            let router = ProviderRouter(database: database, keychain: Keychain(), builtIn: BuiltInLLM(store: store, host: host))
            let writer = NoteWriter(database: database) { try router.resolve($0) }
            var handlers = Pipeline.Handlers()
            handlers.enhance = { try await writer.write($0) }
            self.store = store
            self.host = host
            self.pipeline = pipeline
            self.router = router
            recorder = MeetingRecorder(database: database, paths: paths, makeRecorders: Self.makeRecorders, host: host)
            try database.seedBuiltIns()
            templates = (try? database.templates()) ?? BuiltInTemplates.all
            reloadAISetup()
            showAIChoice = routes[.enhance] == nil && !UserDefaults.standard.bool(forKey: Self.aiChoiceAskedKey)
            Task {
                await pipeline.setHandlers(handlers)
                await pipeline.start()
            }
            watchModels(store)
            let detector = CallDetector(model: self, callApps: (try? database.callApps()) ?? CallAppCatalog.builtIn)
            detector.start()
            self.detector = detector
            listTask = Task { [weak self] in
                do {
                    for try await meetings in database.meetingList() { self?.meetings = meetings }
                } catch {
                    Log.error("ui.meeting_list_failed")
                }
            }
            Log.info("app.launched")
        } catch AppDatabase.OpenError.newerThanApp {
            startupError = "This database was created by a newer version of Honeycomb. Update Honeycomb to open it."
        } catch {
            startupError = "Honeycomb couldn't open its database."
            Log.error("app.database_open_failed")
        }
        pill.model = self
    }

    private func watchModels(_ store: ModelStore) {
        modelTask = Task { [weak self] in
            self?.modelStates = await store.allStates
            for await states in store.updates { self?.modelStates = states }
        }
        Task {
            // Speech first: it's small, and every recording needs it.
            for id in [ModelCatalog.vad, ModelCatalog.parakeet] where !(await store.isReady(id)) {
                try? await store.install(id)
            }
            await pipeline?.nudge()
            installRoutedModels()
        }
    }

    /// Downloads the built-in models a route uses, and only those, so choosing a cloud or Ollama
    /// model never starts a multi-gigabyte download. Running installs are joined, not repeated.
    private func installRoutedModels() {
        for id in Set(routes.values.filter { $0.providerId == ProviderRecord.builtIn.id }.map(\.model)) { downloadModel(id) }
    }

    private func reloadAISetup() {
        guard let database else { return }
        providers = (try? database.providers()) ?? []
        routes = Dictionary(uniqueKeysWithValues: ((try? database.routes()) ?? []).map { ($0.task, $0) })
    }

    var notesProvider: ProviderRecord? {
        routes[.enhance].flatMap { route in providers.first { $0.id == route.providerId } }
    }

    /// The built-in model notes need, or nil when notes use another provider.
    var notesBuiltInModel: String? {
        routes[.enhance].flatMap { $0.providerId == ProviderRecord.builtIn.id ? $0.model : nil }
    }

    func aiChoiceClosed() {
        UserDefaults.standard.set(true, forKey: Self.aiChoiceAskedKey)
    }

    func useBuiltInAI() {
        setRoutes([.enhance, .chat], provider: ProviderRecord.builtIn.id, model: ModelCatalog.builtInLLM)
    }

    func setRoute(_ task: AITask, provider: String, model: String) {
        setRoutes([task], provider: provider, model: model)
    }

    private func setRoutes(_ tasks: [AITask], provider: String, model: String) {
        guard let database else { return }
        for task in tasks { try? database.saveRoute(Route(task: task, providerId: provider, model: model)) }
        routeChanges += 1
        reloadAISetup()
        installRoutedModels()
        // Meetings waiting on consent were waiting for the old notes provider. A re-run asks again
        // only if the new one is a cloud provider without consent.
        if tasks.contains(.enhance) { requeue(waitingFor: [.aiNotChosen, .cloudConsent]) }
    }

    private func requeue(waitingFor reasons: Set<WaitReason>) {
        let waiting = meetings.filter { $0.waitReason.map(reasons.contains) == true }.map(\.id)
        Task { for id in waiting { await pipeline?.enhanceAnyway(id) } }
    }

    /// Saves a provider and its key. With `routeModel`, notes and chat switch to it.
    func addProvider(_ draft: ProviderDraft, routeModel: String?) throws {
        guard let router else { return }
        let record = try router.save(draft)
        reloadAISetup()
        if let routeModel { setRoutes([.enhance, .chat], provider: record.id, model: routeModel) }
    }

    func deleteProvider(_ record: ProviderRecord) {
        try? router?.delete(record)
        reloadAISetup()
    }

    /// "Test connection" for a provider that isn't saved yet.
    func models(for draft: ProviderDraft) async throws -> [ModelInfo] {
        guard let router else { return [] }
        return try await router.adapter(for: try draft.record(), apiKey: draft.apiKey).models()
    }

    func models(for record: ProviderRecord) async throws -> [ModelInfo] {
        guard let router else { return [] }
        return try await router.adapter(for: record).models()
    }

    /// The one-time consent for the notes provider, then the notes for every meeting waiting on it.
    /// With no cloud provider left to allow, the jobs run again and pick up whatever route is set now.
    func allowCloudAndWrite() {
        if let provider = notesProvider, !provider.isLocal { try? database?.grantCloudConsent(provider.id) }
        requeue(waitingFor: [.cloudConsent])
    }

    /// A failure lands in `modelStates` as `.failed`, where the Settings row and the meeting banner offer a retry.
    func downloadModel(_ id: String) {
        guard let store else { return }
        Task {
            do {
                try await store.install(id)
            } catch {
                Log.error("model.install_failed")
                return
            }
            await pipeline?.nudge()
        }
    }

    func downloadLargeModel() {
        guard let store else { return }
        let changesAtStart = routeChanges
        Task {
            do {
                try await store.install(ModelCatalog.largeLLM)
            } catch {
                return
            }
            if routeChanges == changesAtStart, routes[.enhance]?.providerId == ProviderRecord.builtIn.id {
                setRoute(.enhance, provider: ProviderRecord.builtIn.id, model: ModelCatalog.largeLLM)
            }
        }
    }

    nonisolated static func makeRecorders() -> [any TrackRecorder] {
        let apps = Set(CallAppCatalog.builtIn.map(\.bundleId))
        let picked = InputDevicePicker.pick(devices: InputDevices.all(), defaultInput: InputDevices.defaultInput,
                                            callAppInputs: InputDevices.inputsInUse(of: apps))
        let tapIncludesOutput = UserDefaults.standard.bool(forKey: "systemAudioIncludesOutput")
        return [MicRecorder(deviceID: picked?.id), SystemAudioRecorder(includeOutputDevice: tapIncludesOutput)]
    }

    func toggleRecording() {
        send(isRecording ? .stop : .start(startTarget))
    }

    func startFromPrompt(_ prompt: CallPrompt) {
        send(.start(.call(prompt)))
    }

    func stopRecording() {
        send(.stop)
    }

    func pauseOrResume() {
        send(lifecycle.phase.isPaused ? .resume : .pause)
    }

    func keepRecording() {
        send(.resume)
    }

    /// The call app let go of the mic. Pause now, then stop after a short window to undo.
    func callEnded() {
        send(.callEnded(atMs: nowMs))
    }

    func callResumed() {
        send(.callResumed)
    }

    func tick() {
        send(.tick(atMs: nowMs))
    }

    func quitRequested() {
        send(.quitRequested)
    }

    private var startTarget: StartTarget {
        guard let selection, (try? database?.meeting(selection))??.state == .draft else { return .newMeeting }
        return .draft(selection)
    }

    private var nowMs: Int64 {
        Int64((ContinuousClock.now - launchedAt) / .milliseconds(1))
    }

    private func send(_ event: RecordingEvent) {
        let commands = lifecycle.handle(event)
        if let host, host.gate.isRecording != lifecycle.phase.holdsModels {
            host.gate.set(lifecycle.phase.holdsModels)
            if !lifecycle.phase.holdsModels { Task { await pipeline?.nudge() } }
        }
        autoStopCountdown = lifecycle.secondsUntilAutoStop(atMs: nowMs)
        for command in commands { run(command) }
    }

    private func run(_ command: RecordingCommand) {
        switch command {
        case .startCapture(let target):
            status = RecordingStatus()
            pill.show()
            starting = Task { await openCapture(target) }
        case .cancelStart:
            starting?.cancel()
        case .began(let active):
            partials = [:]
            selection = active.meetingID
            showConsent = true
            pill.show()
            detector?.recordingStarted(fromCall: active.callKey)
        case .pauseCapture:
            Task { await recorder?.pause() }
        case .resumeCapture:
            Task {
                do {
                    try await recorder?.resume()
                } catch {
                    send(.resumeFailed)
                }
            }
        case .stopCapture:
            Task { await closeCapture() }
        case .askToQuit:
            Task { send(confirmQuit() ? .quitConfirmed : .quitCancelled) }
        case .quit:
            Task {
                await EditorHost.shared.flush()
                await pipeline?.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        case .cancelQuit:
            NSApp.reply(toApplicationShouldTerminate: false)
        case .alert(let error):
            alert = AppAlert(error)
            showMainWindow()
        }
    }

    private func openCapture(_ target: StartTarget) async {
        guard let recorder else { return send(.captureFailed(.captureFailed)) }
        await pipeline?.recordingStarted()
        let existing: UUID?
        let callApp: CallApp?
        switch target {
        case .newMeeting: (existing, callApp) = (nil, nil)
        case .draft(let id): (existing, callApp) = (id, nil)
        case .call(let prompt): (existing, callApp) = (nil, prompt.app)
        }
        do {
            let (id, session) = try await recorder.start(existing: existing, callApp: callApp) { update in
                Task { @MainActor [weak self] in self?.apply(update) }
            }
            statusTask = Task { [weak self] in
                for await status in session.status { self?.status = status }
            }
            send(.captureOpened(meetingID: id))
        } catch {
            pill.hide()
            send(.captureFailed(error is CancellationError ? nil : (error as? RecordingError) ?? .captureFailed))
        }
    }

    private func closeCapture() async {
        detector?.recordingStopped()
        statusTask?.cancel()
        showConsent = false
        pill.hide()
        let id = await recorder?.stop()
        partials = [:]
        if let id { await pipeline?.meetingStopped(id) }
        send(.stopFinished)
    }

    private func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop and save the recording?"
        alert.informativeText = "Honeycomb is recording a meeting. Quitting stops the recording and keeps what was captured."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func apply(_ update: LiveUpdate) {
        switch update {
        case .partial(let line):
            partials[line.channel] = line
        case .final(let line):
            partials[line.channel] = nil
        case .gap:
            break
        }
    }

    func regenerate(_ meeting: Meeting, template: String) {
        try? database?.setTemplate(meeting.id, template)
        Task { await pipeline?.enqueue(.enhance, meeting: meeting.id) }
    }

    func useVersion(_ version: EnhancedNote, of meeting: Meeting) {
        try? database?.setCurrentEnhanced(meeting.id, version.id)
    }

    func copyNotes(_ note: EnhancedNote) {
        let doc = note.doc.flatMap(PMNode.decode) ?? Markdown.document(note.markdown)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(NoteExport.html(doc), forType: .html)
        pasteboard.setString(Markdown.markdown(doc), forType: .string)
    }

    func showSource(_ block: String, enhanced: UUID) {
        guard let lines = try? database?.sources(enhanced, block: block), !lines.isEmpty else { return }
        sourceQuote = SourceQuote(lines: lines)
    }

    func enhanceAnyway(_ meeting: Meeting) {
        Task { await pipeline?.enhanceAnyway(meeting.id) }
    }

    func retry(_ meeting: Meeting) {
        Task { await pipeline?.retry(meeting.id) }
    }

    /// One-line status for model downloads, or nil when every needed model is ready.
    var modelActivity: String? {
        let names = [ModelCatalog.parakeet: "speech model", ModelCatalog.builtInLLM: "AI model",
                     ModelCatalog.embedder: "search model", ModelCatalog.largeLLM: "large AI model"]
        for (id, name) in names.sorted(by: { $0.key < $1.key }) {
            switch modelStates[id] {
            case .downloading(let received, let total):
                return "Downloading \(name)… \(Int(Double(received) / Double(max(total, 1)) * 100))%"
            case .waitingForNetwork:
                return "Waiting for the network to download the \(name)"
            case .verifying:
                return "Checking the \(name)…"
            case .failed:
                return "The \(name) download failed"
            default:
                continue
            }
        }
        return nil
    }

    var meetingToDelete: Meeting?

    func canDelete(_ meeting: Meeting) -> Bool {
        let state = meetings.first { $0.id == meeting.id }?.state ?? meeting.state
        return meeting.id != recordingMeetingID && ![.recording, .paused, .transcribing, .writingNotes].contains(state)
    }

    func delete(_ meeting: Meeting) {
        guard canDelete(meeting) else { return }
        try? database?.deleteMeeting(meeting.id)
        try? FileManager.default.removeItem(at: paths.audioFolder(for: meeting.id))
        if selection == meeting.id { selection = nil }
    }

    func rename(_ meeting: Meeting, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = try? database?.meeting(meeting.id), !trimmed.isEmpty, trimmed != current.title else { return }
        try? database?.renameMeeting(meeting.id, to: trimmed)
    }

    func newNote() {
        guard let database else { return }
        let meeting = Meeting(title: Meeting.defaultTitle(appName: nil, at: Date()), state: .draft)
        try? database.insert(meeting)
        selection = meeting.id
    }

    @ObservationIgnored var openWindow: OpenWindowAction?

    func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }

    var consentMessage: String {
        "Heads up: I'm using Honeycomb to take notes during this call. It records audio on my Mac only."
    }

    func copyConsentMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(consentMessage, forType: .string)
        showConsent = false
    }
}

struct SourceQuote: Identifiable {
    let id = UUID()
    let lines: [TranscriptSegment]
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ error: RecordingError) {
        switch error {
        case .alreadyRecording:
            self.init(title: "Already recording", message: "Stop the current recording first.")
        case .lowDisk(let available):
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            self.init(title: "Not enough disk space",
                      message: "Honeycomb needs at least 2 GB free to record. Only \(free) is free.")
        case .micDenied:
            self.init(title: "Microphone access is off",
                      message: "Turn on Honeycomb in System Settings → Privacy & Security → Microphone, then try again.")
        case .captureFailed:
            self.init(title: "Couldn't start recording",
                      message: "Honeycomb couldn't open the audio devices. Check System Settings → Privacy & Security → System Audio Recording.")
        }
    }
}
