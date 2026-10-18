import AppKit
import HoneycombCore
import SwiftUI

/// Runs the detection rules on the main actor: feeds them mic changes and ticks, and turns
/// their commands into pop-ups and recordings.
@MainActor
final class CallDetector {
    private var machine: DetectionMachine
    private let monitor = MicUsageMonitor()
    private weak var model: AppModel?
    private var timer: Timer?
    private let started = ContinuousClock.now
    private let prompts = CallPromptPanels()
    private var sleepObserver: NSObjectProtocol?

    init(model: AppModel, callApps: [CallApp]) {
        self.model = model
        machine = DetectionMachine(callApps: callApps, accessibilityTrusted: BrowserTitles.isTrusted)
    }

    private var now: Int64 {
        let elapsed = ContinuousClock.now - started
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    func start() {
        monitor.start { change in
            Task { @MainActor [weak self] in self?.micChanged(change) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.machine.accessibilityTrusted = BrowserTitles.isTrusted
                self.run(self.machine.handle(.tick(atMs: self.now)))
                self.model?.tick()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.model?.stopRecording() }
        }
    }

    func updateCallApps(_ apps: [CallApp]) {
        machine.callApps = apps
    }

    func recordingStarted(fromCall key: String?) {
        run(machine.handle(.recordingStarted(key: key)))
    }

    func recordingStopped() {
        run(machine.handle(.recordingStopped))
    }

    private func micChanged(_ change: MicUsageMonitor.Change) {
        let event: DetectionEvent = change.started
            ? .micStarted(key: change.key, bundleID: change.bundleID, atMs: now)
            : .micStopped(key: change.key, atMs: now)
        run(machine.handle(event))
    }

    private func run(_ commands: [DetectionCommand]) {
        for command in commands {
            switch command {
            case .readTitle(let key, let bundleID):
                let titles = BrowserTitles.windowTitles(bundleID: bundleID)
                run(machine.handle(.titleRead(key: key, titles: titles)))
            case .show(let prompt):
                prompts.show(prompt) { [weak self] start in
                    guard let self else { return }
                    self.run(self.machine.handle(start ? .startNotes(key: prompt.key) : .notNow(key: prompt.key)))
                }
            case .hide(let key):
                prompts.hide(key)
            case .startRecording(let prompt):
                model?.startFromPrompt(prompt)
            case .callEnded:
                model?.callEnded()
            case .callResumed:
                model?.callResumed()
            }
        }
    }
}

/// The "Zoom call detected" pop-up. A non-activating panel, so it never steals focus from the call.
@MainActor
final class CallPromptPanels {
    private var panels: [String: NSPanel] = [:]

    func show(_ prompt: CallPrompt, choose: @escaping (Bool) -> Void) {
        hide(prompt.key)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 80),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let view = CallPromptView(prompt: prompt) { [weak self] start in
            self?.hide(prompt.key)
            choose(start)
        }
        let host = NSHostingView(rootView: view.honeycombAppearance())
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 360, y: frame.maxY - 12))
        }
        panel.orderFrontRegardless()
        panels[prompt.key] = panel
        NSSound(named: "Tink")?.play()
    }

    func hide(_ key: String) {
        panels.removeValue(forKey: key)?.orderOut(nil)
    }
}
