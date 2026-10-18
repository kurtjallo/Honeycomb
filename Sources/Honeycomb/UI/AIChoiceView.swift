import HoneycombCore
import SwiftUI

/// The "Ask once" AI choice: the built-in model, or a model the user already runs or pays for.
struct AIChoiceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.choose

    enum Step {
        case choose
        case builtIn
        case connect
    }

    var body: some View {
        Group {
            switch step {
            case .choose: choose
            case .builtIn: builtIn
            case .connect:
                ProviderForm(title: "Connect my own model", asksForModel: true,
                             onCancel: { step = .choose }, onSave: { dismiss() })
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How should Honeycomb write your notes?").font(.system(size: 22, weight: .semibold))
            Text("You can change this any time in Settings → Models.").foregroundStyle(.secondary)
            ChoiceButton(title: "Use built-in AI", systemImage: "cpu",
                         detail: "Runs on this Mac, works offline, and needs no account. Downloads Qwen3.5 4B (\(builtInSize)).") {
                model.useBuiltInAI()
                step = .builtIn
            }
            ChoiceButton(title: "Connect my own model", systemImage: "network",
                         detail: "Ollama, LM Studio, any OpenAI-compatible server, or Anthropic.") {
                step = .connect
            }
            HStack {
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var builtIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Built-in AI is on").font(.system(size: 22, weight: .semibold))
            Text("Notes are written on this Mac. The download keeps going if you close this.").foregroundStyle(.secondary)
            ModelDownloadRow(id: ModelCatalog.builtInLLM) { model.downloadModel(ModelCatalog.builtInLLM) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var builtInSize: String {
        ByteCountFormatter.string(fromByteCount: ModelCatalog.spec(ModelCatalog.builtInLLM)?.totalBytes ?? 0, countStyle: .file)
    }
}

private struct ChoiceButton: View {
    let title: String
    let systemImage: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentText)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(Color.textPrimary)
                    Text(detail).font(.callout).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .background(hovering ? Color.accentSubtle : Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Color.accentStrong : .clear, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}
