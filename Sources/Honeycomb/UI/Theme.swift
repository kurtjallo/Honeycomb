import AppKit
import SwiftUI

/// Honeycomb's palette. Values and contrast checks are in `.plan/ui-design.md`; the editor's
/// `style.css` repeats them, so change both together.
extension Color {
    static let canvas = Color(light: 0xFFFDF8, dark: 0x1E1E1E)
    static let textPrimary = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let textSecondary = Color(light: 0x626267, dark: 0xA1A1A6)
    static let textAI = Color(light: 0x6B6459, dark: 0xA69F93)
    static let accent = Color(light: 0xF2B630, dark: 0xF7B531)
    static let accentHover = Color(light: 0xE39B12, dark: 0xFFCB52)
    static let onAccent = Color(light: 0x1D1D1F, dark: 0x1D1D1F)
    static let accentStrong = Color(light: 0xC27A06, dark: 0xF7B531)
    static let accentText = Color(light: 0x8A5800, dark: 0xFFCB52)
    static let accentSubtle = Color(light: 0xFCEFCC, dark: 0x3B3018)
    static let selection = Color(light: 0xFAE6B0, dark: 0x3E3215)
    static let recording = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let recordingText = Color(light: 0xC42B1C, dark: 0xFF6B61)
    static let warning = Color(light: 0xC2410C, dark: 0xFF8A4C)
    static let warningSubtle = Color(light: 0xFDEBDD, dark: 0x3D2617)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The Settings choice for light, dark, or whatever macOS is using.
/// Stored as `honeycomb.appearance`. A missing key means System.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "honeycomb.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` leaves the window on the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func isDark(system: ColorScheme) -> Bool {
        switch self {
        case .system: system == .dark
        case .light: false
        case .dark: true
        }
    }
}

/// Panels built with `NSHostingView` are not inside a scene, so they do not inherit the window's
/// `preferredColorScheme`. This is the one place those roots, and the scenes, read the setting.
private struct HoneycombAppearance: ViewModifier {
    @AppStorage(AppearanceChoice.defaultsKey) private var appearance = AppearanceChoice.system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func honeycombAppearance() -> some View {
        modifier(HoneycombAppearance())
    }
}

/// The primary action. Dark text on honey, because a white label on `accent` is under 2:1.
/// While recording it turns red with a white label, so "Stop" never reads as "Start".
struct HoneyButtonStyle: ButtonStyle {
    var isRecording = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        HoneyButton(configuration: configuration, isRecording: isRecording, large: large)
    }

    private struct HoneyButton: View {
        let configuration: Configuration
        let isRecording: Bool
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .medium))
                .foregroundStyle(isRecording ? Color.white : Color.onAccent)
                .padding(.horizontal, large ? 20 : 12)
                .padding(.vertical, large ? 10 : 5)
                .background(fill, in: .capsule)
                .contentShape(.capsule)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if isRecording { return .recording }
            return hovering || configuration.isPressed ? .accentHover : .accent
        }
    }
}

/// A small capsule with an icon and a label, for meta such as the date, length, and status.
struct Chip<Content: View>: View {
    var fill: Color = .clear
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .labelStyle(ChipLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: .capsule)
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
