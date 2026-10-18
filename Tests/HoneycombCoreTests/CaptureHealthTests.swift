import Testing
@testable import HoneycombCore

struct CaptureHealthTests {
    var machine = CaptureHealthMachine()

    /// Writes one buffer every 100 ms from `from` up to, not including, `to`.
    mutating func write(from: Int64, to: Int64, silent: Bool = false) -> [CaptureCommand] {
        var commands: [CaptureCommand] = []
        var now = from
        while now < to {
            commands += machine.handle(.wrote(atMs: now, silent: silent))
            commands += machine.handle(.tick(atMs: now))
            now += 100
        }
        return commands
    }

    mutating func tick(from: Int64, to: Int64) -> [CaptureCommand] {
        var commands: [CaptureCommand] = []
        var now = from
        while now <= to {
            commands += machine.handle(.tick(atMs: now))
            now += 50
        }
        return commands
    }

    @Test mutating func steadyWritingIsComplete() {
        _ = machine.handle(.started(atMs: 0))
        #expect(write(from: 100, to: 60_000).isEmpty)
        #expect(machine.health == .ok)
        #expect(machine.finalStatus(stoppedAtMs: 60_500) == .complete)
    }

    @Test mutating func noAudioAfterGraceRestarts() {
        _ = machine.handle(.started(atMs: 0))
        #expect(tick(from: 0, to: 4_950).isEmpty)
        let commands = machine.handle(.tick(atMs: 5_000))
        #expect(commands == [.interruptionStarted(reason: .stalled, atMs: 5_000), .restart(attempt: 1)])
    }

    @Test mutating func stallRestartsAtOnce() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 10_000)
        #expect(tick(from: 10_000, to: 12_850).isEmpty)
        let commands = machine.handle(.tick(atMs: 12_900))
        #expect(commands == [.interruptionStarted(reason: .stalled, atMs: 12_900), .restart(attempt: 1)])
        #expect(machine.health == .recovering)
    }

    @Test mutating func threeFailedRestartsMeanLost() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 1_000)
        var commands = tick(from: 1_000, to: 3_900)
        #expect(commands.last == .restart(attempt: 1))
        commands = machine.handle(.restartFailed(atMs: 3_950))
        #expect(commands.isEmpty)
        #expect(tick(from: 4_000, to: 4_400).isEmpty)
        #expect(machine.handle(.tick(atMs: 4_450)) == [.restart(attempt: 2)])
        _ = machine.handle(.restartFailed(atMs: 4_500))
        #expect(tick(from: 4_550, to: 6_450).isEmpty)
        #expect(machine.handle(.tick(atMs: 6_500)) == [.restart(attempt: 3)])
        #expect(machine.handle(.restartFailed(atMs: 6_600)) == [.captureLost(atMs: 6_600)])
        #expect(machine.health == .lost)
        #expect(machine.finalStatus(stoppedAtMs: 7_000) == .incomplete)
    }

    @Test mutating func lostKeepsRetrying() {
        _ = machine.handle(.started(atMs: 0))
        _ = machine.handle(.tick(atMs: 5_000))
        for attempt in 1...3 {
            _ = tick(from: 5_000 + Int64(attempt - 1) * 2_500, to: 5_000 + Int64(attempt) * 2_500 - 50)
            _ = machine.handle(.restartFailed(atMs: 5_000 + Int64(attempt) * 2_500))
        }
        #expect(machine.health == .lost)
        let retries = tick(from: 12_600, to: 23_000).filter { if case .restart = $0 { true } else { false } }
        #expect(retries == [.restart(attempt: 4)])
    }

    @Test mutating func successfulRestartRecoversAfterStableWindow() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 1_000)
        _ = tick(from: 1_000, to: 3_900)
        _ = machine.handle(.restartSucceeded(atMs: 4_000))
        let early = write(from: 4_200, to: 9_100)
        #expect(early.isEmpty)
        #expect(machine.health == .recovering)
        let later = write(from: 9_100, to: 9_400)
        #expect(later == [.interruptionRecovered(resumedAtMs: 4_200, attempts: 1)])
        #expect(machine.health == .ok)
        #expect(machine.finalStatus(stoppedAtMs: 9_500) == .recovered)
    }

    @Test mutating func routeChangeBurstIsDebounced() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 2_000)
        _ = machine.handle(.routeChanged(atMs: 2_000))
        _ = machine.handle(.routeChanged(atMs: 2_300))
        _ = machine.handle(.routeChanged(atMs: 2_600))
        #expect(tick(from: 2_600, to: 3_300).isEmpty)
        let commands = machine.handle(.tick(atMs: 3_350))
        #expect(commands == [.interruptionStarted(reason: .routeChanged, atMs: 3_350), .restart(attempt: 1)])
    }

    /// AVAudioEngine posts a configuration change each time it starts on a chosen mic, and the mic
    /// keeps delivering. Restarting on it built a new engine that posted another one, until "lost".
    @Test mutating func routeChangeWhileStillWritingKeepsRunning() {
        _ = machine.handle(.started(atMs: 0))
        _ = machine.handle(.routeChanged(atMs: 50))
        #expect(write(from: 100, to: 20_000).isEmpty)
        _ = machine.handle(.routeChanged(atMs: 20_000))
        #expect(write(from: 20_000, to: 30_000).isEmpty)
        #expect(machine.health == .ok)
        #expect(machine.finalStatus(stoppedAtMs: 30_000) == .complete)
    }

    @Test mutating func samplesDrainedJustAfterARouteChangeDoNotProveItSurvived() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 2_000)
        _ = machine.handle(.routeChanged(atMs: 2_000))
        _ = machine.handle(.wrote(atMs: 2_040, silent: false))
        #expect(tick(from: 2_050, to: 2_700).isEmpty)
        let commands = machine.handle(.tick(atMs: 2_750))
        #expect(commands == [.interruptionStarted(reason: .routeChanged, atMs: 2_750), .restart(attempt: 1)])
    }

    @Test mutating func writesWhileLostResumeTheTrack() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 1_000)
        var now: Int64 = 1_000
        var commands: [CaptureCommand] = []
        while machine.health != .lost {
            let step = machine.handle(.tick(atMs: now))
            commands += step
            if step.contains(where: { if case .restart = $0 { true } else { false } }) {
                commands += machine.handle(.restartSucceeded(atMs: now))
            }
            now += 50
        }
        #expect(commands.last == .captureLost(atMs: now - 50))
        #expect(write(from: now, to: now + 4_900).isEmpty)
        #expect(machine.health == .recovering)
        #expect(write(from: now + 4_900, to: now + 5_100) == [.interruptionRecovered(resumedAtMs: now, attempts: 3)])
        #expect(machine.health == .ok)
        #expect(machine.finalStatus(stoppedAtMs: now + 5_100) == .recovered)
    }

    @Test mutating func silenceOnlyWarns() {
        _ = machine.handle(.started(atMs: 0))
        let silent = write(from: 100, to: 16_200, silent: true)
        #expect(silent == [.silenceWarning(true)])
        let speech = write(from: 16_200, to: 16_400)
        #expect(speech == [.silenceWarning(false)])
        #expect(machine.health == .ok)
    }

    @Test mutating func tailToleranceDecidesCompleteness() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 10_000)
        #expect(machine.finalStatus(stoppedAtMs: 12_000) == .complete)
        #expect(machine.finalStatus(stoppedAtMs: 13_500) == .incomplete)
    }

    @Test mutating func pauseStopsStallChecks() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 10_000)
        _ = machine.handle(.paused(atMs: 10_000))
        #expect(tick(from: 10_000, to: 70_000).isEmpty)
        #expect(machine.finalStatus(stoppedAtMs: 70_000) == .complete)
        _ = machine.handle(.started(atMs: 70_000))
        _ = write(from: 70_100, to: 80_000)
        #expect(machine.finalStatus(stoppedAtMs: 80_000) == .complete)
    }

    @Test mutating func writeFailureRestarts() {
        _ = machine.handle(.started(atMs: 0))
        _ = write(from: 100, to: 1_000)
        let commands = machine.handle(.writeFailed(atMs: 1_000))
        #expect(commands == [.interruptionStarted(reason: .writeFailed, atMs: 1_000), .restart(attempt: 1)])
    }
}
