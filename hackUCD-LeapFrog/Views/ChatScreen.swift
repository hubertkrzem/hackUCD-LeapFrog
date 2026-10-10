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

/// Full-screen travel assistant: opens with an overview of live conditions,
/// then answers public transport questions.
struct ChatScreen: View {
    let model: LiveMapModel
    let onClose: () -> Void

    @State private var assistant = TravelAssistant()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            inputBar
        }
        .background(Theme.surface)
        .task { await assistant.start(model: model) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Theme.green, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Travel assistant")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Live disruptions & travel help")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Theme.canvas, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(assistant.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if assistant.isWaiting {
                        TypingIndicator(label: assistant.messages.isEmpty ? "Checking live conditions…" : nil)
                            .id("typing")
                    }
                    if let error = assistant.error {
                        ErrorNotice(message: error) { Task { await assistant.retry() } }
                            .id("error")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: assistant.messages.count) { scrollToEnd(proxy) }
            .onChange(of: assistant.isWaiting) { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if assistant.isWaiting {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = assistant.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about disruptions, stations, connections…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Theme.green : Theme.hairline, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !assistant.isWaiting
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await assistant.send(text) }
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

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let isRider = message.role == .user
        HStack {
            if isRider { Spacer(minLength: 48) }
            Text(Self.render(message.text))
                .font(.body)
                .foregroundStyle(isRider ? .white : Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isRider ? Theme.green : Theme.canvas,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !isRider { Spacer(minLength: 32) }
        }
    }

    /// Replies may use **bold**; keep line breaks and bullets as written.
    static func render(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct TypingIndicator: View {
    let label: String?
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Theme.secondaryInk)
                        .frame(width: 7, height: 7)
                        .opacity(phase == index ? 1 : 0.35)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if let label {
                Text(label).font(.footnote).foregroundStyle(Theme.secondaryInk)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                phase = (phase + 1) % 3
            }
        }
        .accessibilityLabel("Assistant is typing")
    }
}

private struct ErrorNotice: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.ink)
            Button("Try again", action: onRetry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.green)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
