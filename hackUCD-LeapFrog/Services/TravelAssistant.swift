import Foundation
import Observation

nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable, Codable {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

/// Talks to tools/chat_bridge.py on the Mac, which answers using Claude Code.
/// For demos only: a shipping app would call a hosted back end instead.
nonisolated struct ChatBridgeClient: Sendable {
    let baseURL: URL
    var session: URLSession = .shared

    /// The simulator reaches the Mac at 127.0.0.1. For a phone, set `ChatBridgeURL`
    /// in Secrets.plist to the Mac's address (and run the bridge with `--host 0.0.0.0`).
    static var configured: ChatBridgeClient {
        let fromSecrets = Bundle.main.url(forResource: "Secrets", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) }?["ChatBridgeURL"] as? String
        return ChatBridgeClient(baseURL: URL(string: fromSecrets ?? "") ?? URL(string: "http://127.0.0.1:8787")!)
    }

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: ChatMessage.Role
            let content: String
        }
        let messages: [Message]
        let context: String
    }

    private struct Response: Decodable {
        let reply: String?
        let error: String?
    }

    @concurrent
    func reply(to messages: [ChatMessage], context: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(Request(
            messages: messages.map { .init(role: $0.role, content: $0.text) },
            context: context
        ))
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let reply = response.reply, !reply.isEmpty { return reply }
        throw TravelAssistant.Failure.assistant(response.error ?? "Empty reply")
    }
}

/// The travel assistant conversation. On open it asks for an overview of live
/// conditions; after that it answers the rider's questions.
@Observable
final class TravelAssistant {
    enum Failure: LocalizedError {
        case assistant(String)
        var errorDescription: String? {
            if case .assistant(let message) = self { message } else { nil }
        }
    }

    /// Sent (but not shown) when the chat opens; the prompt turns it into a conditions overview.
    static let openingMessage = "(chat opened)"

    private(set) var messages: [ChatMessage] = []
    private(set) var isWaiting = false
    private(set) var error: String?

    private let client: ChatBridgeClient
    private var history: [ChatMessage] = []
    private var context = ""

    init(client: ChatBridgeClient = .configured) {
        self.client = client
    }

    /// Builds the live snapshot and asks for the opening overview (once per chat).
    func start(model: LiveMapModel) async {
        guard history.isEmpty, !isWaiting else { return }
        isWaiting = true
        // Opened straight after launch: give the live feeds a moment to arrive first.
        for _ in 0..<20 where model.lastUpdated == nil || (model.hasAPIKey && model.tripUpdates == nil) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let busesReporting = model.vehicles.filter { $0.mode == .bus && $0.source == .nta }.count
        context = await TransitSnapshot.build(tripUpdates: model.tripUpdates, routes: model.data.routes,
                                              busesReporting: busesReporting)
        isWaiting = false
        await exchange(ChatMessage(role: .user, text: Self.openingMessage), visible: false)
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWaiting else { return }
        await exchange(ChatMessage(role: .user, text: trimmed), visible: true)
    }

    /// Re-sends the last rider message after a failure.
    func retry() async {
        guard let last = history.last, last.role == .user, !isWaiting else { return }
        history.removeLast()
        await exchange(last, visible: false)
    }

    private func exchange(_ message: ChatMessage, visible: Bool) async {
        error = nil
        history.append(message)
        if visible { messages.append(message) }
        isWaiting = true
        defer { isWaiting = false }
        do {
            let reply = try await client.reply(to: history, context: context)
            let answer = ChatMessage(role: .assistant, text: reply)
            history.append(answer)
            messages.append(answer)
        } catch let failure as Failure {
            error = failure.localizedDescription
        } catch {
            self.error = "Can't reach the assistant. On your Mac, run: python3 tools/chat_bridge.py"
        }
    }
}
