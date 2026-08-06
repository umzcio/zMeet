import SwiftUI

// MARK: - In-app dialog components (custom modals, shared across views)

struct DialogScaffold<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var appear: Animation { ZMeetMotion.enter }
    static var disappear: Animation { ZMeetMotion.exit }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .transition(.opacity)
            content
                .padding(22)
                .frame(width: 380)
                .background(ZMeetPalette.dialogCard,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ZMeetPalette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                .accessibilityAddTraits(.isModal)
                .transition(reduceMotion
                    ? AnyTransition.opacity
                    : .scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }
}

struct DialogTextField: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(ZMeetPalette.light)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(focused ? ZMeetPalette.mint : ZMeetPalette.hairline, lineWidth: 1))
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { focused = true }
    }
}

struct DialogButton: View {
    enum Kind { case primary, secondary, destructive }
    let title: String
    let kind: Kind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(background, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary:     return Color(red: 0.024, green: 0.157, blue: 0.102)
        case .secondary:   return ZMeetPalette.light
        case .destructive: return .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary:     return ZMeetPalette.mint.opacity(hover ? 0.88 : 1)
        case .secondary:   return Color.white.opacity(hover ? 0.13 : 0.07)
        case .destructive: return Color(red: 0.90, green: 0.32, blue: 0.30).opacity(hover ? 0.88 : 1)
        }
    }
}

/// Instant pointer-down feedback for custom (plain-styled) controls.
/// Apple guidance: respond on press, not on release; 100-160ms; subtle.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(ZMeetMotion.press, value: configuration.isPressed)
    }
}
