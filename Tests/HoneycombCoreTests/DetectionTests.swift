import Testing
@testable import HoneycombCore

struct DetectionTests {
    var machine = DetectionMachine(callApps: CallAppCatalog.builtIn, accessibilityTrusted: true)

    mutating func ticks(_ from: Int64, _ to: Int64) -> [DetectionCommand] {
        var commands: [DetectionCommand] = []
        var now = from
        while now <= to {
            commands += machine.handle(.tick(atMs: now))
            now += 500
        }
        return commands
    }

    func shown(_ commands: [DetectionCommand]) -> [CallPrompt] {
        commands.compactMap { if case .show(let prompt) = $0 { prompt } else { nil } }
    }

    @Test mutating func zoomAsksAfterThreeSeconds() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        #expect(ticks(0, 2_500).isEmpty)
        let prompts = shown(machine.handle(.tick(atMs: 3_000)))
        #expect(prompts.map(\.kind) == [.app("Zoom")])
        #expect(prompts.first?.kind.headline == "Zoom call detected")
    }

    @Test mutating func dictationAppsAreIgnored() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "com.electron.wispr-flow", atMs: 0))
        _ = machine.handle(.micStarted(key: "2", bundleID: "com.apple.SpeechRecognitionCore.speechrecognitiond", atMs: 0))
        #expect(ticks(0, 30_000).isEmpty)
    }

    @Test mutating func shortBlipsAreIgnored() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "com.tinyspeck.slackmacgap", atMs: 0))
        _ = machine.handle(.micStopped(key: "1", atMs: 1_500))
        #expect(ticks(0, 10_000).isEmpty)
    }

    @Test mutating func browserHelperReadsTheTabTitle() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "com.google.Chrome.helper", atMs: 0))
        #expect(ticks(0, 3_000) == [.readTitle(key: "1", bundleID: "com.google.Chrome")])
        let prompts = shown(machine.handle(.titleRead(key: "1", title: "Meet - abc-defg-hij")))
        #expect(prompts.map(\.kind) == [.site("Google Meet")])
    }

    @Test mutating func safariRecordsFromWebKitsGPUProcess() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "com.apple.WebKit.GPU", atMs: 0))
        #expect(ticks(0, 3_000) == [.readTitle(key: "1", bundleID: "com.apple.Safari")])
    }

    @Test mutating func chatGPTVoiceInABrowserIsQuiet() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "company.thebrowser.Browser", atMs: 0))
        _ = ticks(0, 3_000)
        #expect(machine.handle(.titleRead(key: "1", title: "ChatGPT")).isEmpty)
        #expect(ticks(3_500, 60_000).isEmpty)
    }

    @Test mutating func aMeetingTabOpenedAfterTheMicStartsStillPrompts() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "com.google.Chrome", atMs: 0))
        _ = ticks(0, 3_000)
        _ = machine.handle(.titleRead(key: "1", title: "New Tab"))
        #expect(ticks(3_500, 5_000) == [.readTitle(key: "1", bundleID: "com.google.Chrome")])
        let prompts = shown(machine.handle(.titleRead(key: "1", title: "Meet - abc-defg-hij")))
        #expect(prompts.map(\.kind) == [.site("Google Meet")])
    }

    @Test mutating func browserWithoutAccessibilityGetsTheGenericPrompt() {
        machine.accessibilityTrusted = false
        _ = machine.handle(.micStarted(key: "1", bundleID: "com.google.Chrome", atMs: 0))
        #expect(shown(ticks(0, 3_000)).map(\.kind) == [.browser("Chrome")])
    }

    @Test mutating func notNowStaysQuietForThatCall() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = ticks(0, 3_000)
        #expect(machine.handle(.notNow(key: "1")) == [.hide(key: "1")])
        #expect(ticks(3_500, 60_000).isEmpty)
        _ = machine.handle(.micStarted(key: "2", bundleID: "us.zoom.xos", atMs: 61_000))
        #expect(ticks(61_000, 70_000).isEmpty)
        _ = machine.handle(.micStopped(key: "1", atMs: 71_000))
        _ = machine.handle(.micStopped(key: "2", atMs: 71_000))
        _ = machine.handle(.micStarted(key: "3", bundleID: "us.zoom.xos", atMs: 100_000))
        #expect(shown(ticks(100_000, 103_000)).count == 1)
    }

    @Test mutating func promptHidesWhenTheCallEndsFirst() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = ticks(0, 3_000)
        #expect(machine.handle(.micStopped(key: "1", atMs: 4_000)) == [.hide(key: "1")])
    }

    @Test mutating func endingTheCallStopsTheRecording() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = ticks(0, 3_000)
        let commands = machine.handle(.startNotes(key: "1"))
        #expect(commands.count == 2)
        _ = machine.handle(.recordingStarted(key: "1"))
        _ = machine.handle(.micStopped(key: "1", atMs: 600_000))
        #expect(ticks(600_000, 604_500).isEmpty)
        #expect(machine.handle(.tick(atMs: 605_000)) == [.callEnded])
    }

    @Test mutating func micComingBackCancelsTheEnding() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = ticks(0, 3_000)
        _ = machine.handle(.startNotes(key: "1"))
        _ = machine.handle(.recordingStarted(key: "1"))
        _ = machine.handle(.micStopped(key: "1", atMs: 10_000))
        _ = machine.handle(.micStarted(key: "2", bundleID: "us.zoom.xos", atMs: 12_000))
        #expect(ticks(12_000, 30_000).isEmpty)
    }

    @Test mutating func micComingBackAfterTheCallEndedResumes() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = ticks(0, 3_000)
        _ = machine.handle(.startNotes(key: "1"))
        _ = machine.handle(.recordingStarted(key: "1"))
        _ = machine.handle(.micStopped(key: "1", atMs: 10_000))
        #expect(ticks(10_000, 15_000) == [.callEnded])
        #expect(machine.handle(.micStarted(key: "2", bundleID: "us.zoom.xos", atMs: 16_000)) == [.callResumed])
        _ = machine.handle(.micStopped(key: "2", atMs: 20_000))
        #expect(ticks(20_000, 25_000) == [.callEnded], "the call can end again")
    }

    @Test mutating func aPromptStartThatFailedNeverAutoStopsALaterRecording() {
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = ticks(0, 3_000)
        _ = machine.handle(.startNotes(key: "1"))
        _ = machine.handle(.recordingStarted(key: nil))
        _ = machine.handle(.micStopped(key: "1", atMs: 60_000))
        #expect(!ticks(60_000, 70_000).contains(.callEnded))
    }

    @Test mutating func manualRecordingNeverAutoStops() {
        _ = machine.handle(.recordingStarted(key: nil))
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        _ = machine.handle(.micStopped(key: "1", atMs: 1_000))
        #expect(!ticks(0, 30_000).contains(.callEnded))
    }

    @Test mutating func backToBackOffersToSwitch() {
        _ = machine.handle(.recordingStarted(key: nil))
        _ = machine.handle(.micStarted(key: "9", bundleID: "com.apple.FaceTime", atMs: 0))
        let prompts = shown(ticks(0, 3_000))
        #expect(prompts.first?.replacesRecording == true)
    }

    @Test mutating func appsWithAskOffAreIgnored() {
        machine.callApps = machine.callApps.map { app in
            var app = app
            if app.bundleId == "us.zoom.xos" { app.ask = false }
            return app
        }
        _ = machine.handle(.micStarted(key: "1", bundleID: "us.zoom.xos", atMs: 0))
        #expect(ticks(0, 10_000).isEmpty)
    }

    @Test func meetingSiteTitles() {
        #expect(MeetingSites.match("Meet - xyz-abcd-efg") == "Google Meet")
        #expect(MeetingSites.match("Zoom Meeting") == "Zoom")
        #expect(MeetingSites.match("Weekly sync | Microsoft Teams") == "Microsoft Teams")
        #expect(MeetingSites.match("ChatGPT") == nil)
        #expect(MeetingSites.match("Zoom pricing plans - Google Search") == nil)
    }
}
