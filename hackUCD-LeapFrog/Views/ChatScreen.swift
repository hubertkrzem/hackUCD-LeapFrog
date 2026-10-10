import SwiftUI

/// The round button above the menu that opens the travel assistant.
struct ChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Theme.green, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: Theme.ink.opacity(0.22), radius: 12, y: 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Travel assistant")
        .accessibilityHint("Ask about travel disruptions")
    }
}

/// Full-screen chat for travel disruptions. A blank placeholder for now: the
/// assistant itself comes later.
struct ChatScreen: View {
    let onClose: () -> Void

    var body: some View {
        Theme.surface
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .background(Theme.canvas, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.top, 8)
                .accessibilityLabel("Close chat")
            }
    }

    /// For screenshots: launch a Debug build with `-chat 1`.
    static var opensAtLaunch: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "chat")
        #else
        false
        #endif
    }
}
