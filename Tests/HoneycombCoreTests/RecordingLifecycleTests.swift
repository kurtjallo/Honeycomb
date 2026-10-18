import Foundation
import Testing
@testable import HoneycombCore

struct RecordingLifecycleTests {
    var lifecycle = RecordingLifecycle()
    let meeting = UUID()
    static let zoom = CallApp(bundleId: "us.zoom.xos", name: "Zoom", kind: .app)

    static func prompt(replacing: Bool) -> CallPrompt {
        CallPrompt(key: "zoom-1", app: zoom, kind: .app("Zoom"), replacesRecording: replacing)
    }

    mutating func recording(_ target: StartTarget = .newMeeting) {
        #expect(lifecycle.handle(.start(target)) == [.startCapture(target)])
        #expect(lifecycle.handle(.captureOpened(meetingID: meeting))
            == [.began(ActiveRecording(meetingID: meeting, callKey: target.callKey))])
    }

    @Test mutating func aSecondStopDoesNothing() {
        recording()
        #expect(lifecycle.handle(.stop) == [.stopCapture])
        #expect(lifecycle.phase.isStopping)
        #expect(lifecycle.handle(.stop).isEmpty)
        #expect(lifecycle.phase.meetingID == meeting, "the stopping meeting stays shown until its stop finishes")
        #expect(lifecycle.handle(.stopFinished).isEmpty)
        #expect(lifecycle.phase == .idle)
    }

    @Test mutating func startDuringAStopIsIgnored() {
        recording()
        _ = lifecycle.handle(.stop)
        #expect(lifecycle.handle(.start(.newMeeting)).isEmpty)
        #expect(lifecycle.handle(.start(.call(Self.prompt(replacing: true)))).isEmpty)
        _ = lifecycle.handle(.stopFinished)
        #expect(lifecycle.phase == .idle)
    }

    @Test mutating func aStartRecordsIntoTheSelectedDraft() {
        let draft = UUID()
        #expect(lifecycle.handle(.start(.draft(draft))) == [.startCapture(.draft(draft))])
        #expect(lifecycle.phase.isStarting)
        #expect(lifecycle.handle(.start(.newMeeting)).isEmpty, "a second click while starting does nothing")
    }

    @Test mutating func resumingDuringTheCountdownCancelsIt() {
        recording()
        #expect(lifecycle.handle(.callEnded(atMs: 1_000)) == [.pauseCapture])
        #expect(lifecycle.secondsUntilAutoStop(atMs: 1_000) == 8)
        #expect(lifecycle.secondsUntilAutoStop(atMs: 8_500) == 1)
        #expect(lifecycle.handle(.resume) == [.resumeCapture])
        #expect(lifecycle.secondsUntilAutoStop(atMs: 2_000) == nil)
        #expect(lifecycle.handle(.tick(atMs: 60_000)).isEmpty)
        #expect(lifecycle.phase == .recording(ActiveRecording(meetingID: meeting, callKey: nil)))
    }

    @Test mutating func theCountdownStopsTheRecording() {
        recording()
        _ = lifecycle.handle(.callEnded(atMs: 1_000))
        #expect(lifecycle.handle(.tick(atMs: 8_500)).isEmpty)
        #expect(lifecycle.handle(.tick(atMs: 9_000)) == [.stopCapture])
        #expect(lifecycle.handle(.tick(atMs: 9_500)).isEmpty)
    }

    @Test mutating func theCallComingBackResumesAnAutomaticPause() {
        recording(.call(Self.prompt(replacing: false)))
        _ = lifecycle.handle(.callEnded(atMs: 0))
        #expect(lifecycle.handle(.callResumed) == [.resumeCapture])
        #expect(lifecycle.handle(.tick(atMs: 60_000)).isEmpty)
        #expect(!lifecycle.phase.isPaused)
    }

    @Test mutating func theCallComingBackLeavesAManualPauseAlone() {
        recording()
        #expect(lifecycle.handle(.pause) == [.pauseCapture])
        #expect(lifecycle.handle(.callEnded(atMs: 0)).isEmpty, "capture is already paused")
        #expect(lifecycle.handle(.callResumed).isEmpty)
        #expect(lifecycle.phase == .paused(ActiveRecording(meetingID: meeting, callKey: nil)))
        #expect(lifecycle.handle(.tick(atMs: 60_000)).isEmpty, "the countdown was cancelled")
        #expect(lifecycle.handle(.callResumed).isEmpty)
    }

    @Test mutating func aManualPauseStillStopsWhenTheCallEnds() {
        recording()
        _ = lifecycle.handle(.pause)
        _ = lifecycle.handle(.callEnded(atMs: 0))
        #expect(lifecycle.handle(.tick(atMs: 8_000)) == [.stopCapture])
    }

    @Test mutating func aFailedResumeGoesBackToPaused() {
        recording()
        _ = lifecycle.handle(.pause)
        #expect(lifecycle.handle(.resume) == [.resumeCapture])
        #expect(lifecycle.handle(.resumeFailed).isEmpty)
        #expect(lifecycle.phase.isPaused)
    }

    @Test mutating func aFailedCaptureReturnsToIdle() {
        _ = lifecycle.handle(.start(.newMeeting))
        #expect(lifecycle.phase.holdsModels)
        #expect(lifecycle.handle(.captureFailed).isEmpty)
        #expect(lifecycle.phase == .idle)
        #expect(!lifecycle.phase.holdsModels)
        #expect(lifecycle.handle(.start(.newMeeting)) == [.startCapture(.newMeeting)])
    }

    @Test mutating func aPromptCanReplaceTheRecording() {
        recording()
        #expect(lifecycle.handle(.start(.call(Self.prompt(replacing: false)))).isEmpty)
        let prompt = Self.prompt(replacing: true)
        #expect(lifecycle.handle(.start(.call(prompt))) == [.stopCapture])
        #expect(lifecycle.handle(.stopFinished) == [.startCapture(.call(prompt))])
        #expect(lifecycle.phase.holdsModels, "the models stay held between the two recordings")
    }

    @Test mutating func quitWhileIdleQuitsAtOnce() {
        #expect(lifecycle.handle(.quitRequested) == [.quit])
        #expect(lifecycle.handle(.start(.newMeeting)).isEmpty, "nothing starts once the app is quitting")
    }

    @Test mutating func quitWhileRecordingAsksThenStopsFirst() {
        recording()
        #expect(lifecycle.handle(.quitRequested) == [.askToQuit])
        #expect(lifecycle.handle(.quitCancelled) == [.cancelQuit])
        #expect(lifecycle.handle(.quitRequested) == [.askToQuit])
        #expect(lifecycle.handle(.quitConfirmed) == [.stopCapture])
        #expect(lifecycle.handle(.stopFinished) == [.quit])
    }

    @Test mutating func quitWhilePausedOrCountingDownAsks() {
        recording()
        _ = lifecycle.handle(.pause)
        #expect(lifecycle.handle(.quitRequested) == [.askToQuit])
        _ = lifecycle.handle(.callEnded(atMs: 0))
        #expect(lifecycle.handle(.quitRequested) == [.askToQuit])
    }

    @Test mutating func quitWhileStartingCancelsTheStart() {
        _ = lifecycle.handle(.start(.newMeeting))
        #expect(lifecycle.handle(.quitRequested) == [.askToQuit])
        #expect(lifecycle.handle(.quitConfirmed) == [.cancelStart])
        #expect(lifecycle.handle(.captureFailed) == [.quit])
    }

    @Test mutating func quitWhileStartingStopsACaptureThatOpenedAnyway() {
        _ = lifecycle.handle(.start(.newMeeting))
        _ = lifecycle.handle(.quitConfirmed)
        #expect(lifecycle.handle(.captureOpened(meetingID: meeting)) == [.stopCapture])
        #expect(lifecycle.handle(.stopFinished) == [.quit])
    }

    @Test mutating func quitWhileStoppingWaitsForTheStop() {
        recording()
        _ = lifecycle.handle(.stop)
        #expect(lifecycle.handle(.quitRequested).isEmpty)
        #expect(lifecycle.handle(.stopFinished) == [.quit])
    }

    /// AGENTS.md: never start a recording without the user's click.
    @Test func onlyAStartClickOpensCapture() {
        var generator = SplitMix(seed: 7)
        let events: [RecordingEvent] = [
            .stop, .pause, .resume, .quitCancelled, .callEnded(atMs: 0), .callResumed, .tick(atMs: 100_000),
            .captureOpened(meetingID: UUID()), .captureFailed, .resumeFailed, .stopFinished,
        ]
        for _ in 0..<200 {
            var lifecycle = RecordingLifecycle()
            for _ in 0..<50 {
                let commands = lifecycle.handle(events[Int(generator.next() % UInt64(events.count))])
                #expect(!commands.contains { if case .startCapture = $0 { true } else { false } })
            }
        }
    }
}

struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
