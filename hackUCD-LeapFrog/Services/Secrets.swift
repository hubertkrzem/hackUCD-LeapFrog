import Foundation

/// Reads the NTA API key from the gitignored Secrets.plist (key `NTAApiKey`),
/// falling back to the `NTA_API_KEY` environment variable set in the Xcode scheme.
nonisolated enum Secrets {
    static let placeholder = "PASTE_YOUR_NTA_API_KEY_HERE"

    static var ntaAPIKey: String? {
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let plist = NSDictionary(contentsOf: url),
           let key = (plist["NTAApiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty, key != placeholder {
            return key
        }
        let env = ProcessInfo.processInfo.environment["NTA_API_KEY"]
        return env?.isEmpty == false ? env : nil
    }
}
