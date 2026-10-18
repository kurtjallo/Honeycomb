import HoneycombCore
import SwiftUI

struct CallPromptView: View {
    let prompt: CallPrompt
    let choose: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.title2)
                .foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(prompt.kind.headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(prompt.replacesRecording ? "Stop the current recording and start notes for this call?" : "Take notes for this call?")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(prompt.replacesRecording ? "Switch" : "Start notes") { choose(true) }
                .buttonStyle(HoneyButtonStyle())
                .fixedSize()
            Button { choose(false) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Not now")
            .accessibilityLabel("Not now")
        }
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(width: 344)
        .glassEffect(in: .rect(cornerRadius: 16))
        .tint(.accentStrong)
    }
}
