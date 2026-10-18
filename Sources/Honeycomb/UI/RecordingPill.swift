import AppKit
import HoneycombCore
import SwiftUI

/// A small floating panel while recording. It never takes focus, even over a full-screen call.
@MainActor
final class RecordingPillController {
    weak var model: AppModel?
    private var panel: NSPanel?

    func show() {
        guard let model else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            let host = NSHostingView(rootView: RecordingPill().environment(model).honeycombAppearance())
            host.sizingOptions = [.preferredContentSize]
            panel.contentView = host
            self.panel = panel
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - 180, y: frame.maxY - 12))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct RecordingPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isRecording { recording } else { starting }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 360)
        .glassEffect(in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(model.status.isHealthy ? Color.clear : Color.recording, lineWidth: 1.5))
        .tint(.accentStrong)
    }

    private var starting: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Starting…").font(.body.weight(.medium))
                Text("macOS may ask for access to your microphone and system audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var recording: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.status.isPaused && model.status.isHealthy ? Color.accent : Color.recording)
                    .frame(width: 10, height: 10)
                Text(Duration.milliseconds(model.status.elapsedMs).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                VStack(spacing: 3) {
                    LevelMeter(level: model.status.tracks[.me]?.level ?? 0).frame(width: 70, height: 4)
                    LevelMeter(level: model.status.tracks[.them]?.level ?? 0).frame(width: 70, height: 4)
                }
                .help("Top: you. Bottom: the call.")
                if !model.status.isHealthy {
                    Text("Reconnecting audio")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.recordingText)
                }
                Spacer(minLength: 0)
                Button {
                    model.pauseOrResume()
                } label: {
                    Image(systemName: model.status.isPaused ? "play.fill" : "pause.fill")
                }
                .help(model.status.isPaused ? "Resume" : "Pause")
                Button {
                    model.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop and write notes")
                Button {
                    model.showMainWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open Honeycomb")
            }
            .buttonStyle(.borderless)
            if let seconds = model.autoStopCountdown {
                HStack {
                    Text("Call ended. Writing notes in \(seconds) s.")
                        .font(.caption)
                    Spacer()
                    Button("Keep recording") { model.keepRecording() }
                        .controlSize(.small)
                }
            } else if model.showConsent {
                ConsentBanner()
            }
            if model.status.tracks[.them]?.silent == true, !model.status.isPaused {
                Text("No call audio for 15 seconds. If people are talking, check System Audio Recording in Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Recording people needs their consent in many places. One click copies a message for the chat.
struct ConsentBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.2.wave.2")
                .foregroundStyle(.secondary)
            Text("Let everyone know you're taking notes.")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy message") { model.copyConsentMessage() }
                .controlSize(.small)
            Button {
                model.showConsent = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Dismiss")
        }
    }
}
