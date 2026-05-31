import SwiftUI

// MARK: - In-app dialog components (custom modals, shared across views)

struct DialogScaffold<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            content
                .padding(22)
                .frame(width: 380)
                .background(Color(red: 0.105, green: 0.124, blue: 0.116),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LibraryView.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
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
            .foregroundStyle(LibraryView.light)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(focused ? LibraryView.mint : LibraryView.hairline, lineWidth: 1))
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
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary:     return Color(red: 0.024, green: 0.157, blue: 0.102)
        case .secondary:   return LibraryView.light
        case .destructive: return .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary:     return LibraryView.mint.opacity(hover ? 0.88 : 1)
        case .secondary:   return Color.white.opacity(hover ? 0.13 : 0.07)
        case .destructive: return Color(red: 0.90, green: 0.32, blue: 0.30).opacity(hover ? 0.88 : 1)
        }
    }
}
