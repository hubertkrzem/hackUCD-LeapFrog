import Foundation

nonisolated enum TransitAPIError: LocalizedError, Equatable {
    case missingAPIKey
    case http(Int)
    /// HTTP 429. `retryAfter` is when the API says to try again, if it said.
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your NTA API key to Secrets.plist"
        case .http(401), .http(403): "NTA API key was rejected"
        case .http(let code): "Server error (\(code))"
        case .rateLimited: "Rate limited, retrying shortly"
        }
    }
}

/// Client for the NTA GTFS-Realtime v2 API (developer.nationaltransport.ie).
nonisolated struct NTAClient: Sendable {
    static let baseURL = URL(string: "https://api.nationaltransport.ie/gtfsr/v2/")!

    let apiKey: String?
    var session: URLSession = .shared

    @concurrent
    func vehicles() async throws -> GTFSRFeed {
        try await fetch("Vehicles")
    }

    @concurrent
    func tripUpdates() async throws -> GTFSRFeed {
        try await fetch("TripUpdates")
    }

    private func fetch(_ path: String) async throws -> GTFSRFeed {
        guard let apiKey, !apiKey.isEmpty else { throw TransitAPIError.missingAPIKey }
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 429 {
                throw TransitAPIError.rateLimited(retryAfter: Self.retryAfter(http, body: data))
            }
            throw TransitAPIError.http(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// Seconds until the API accepts another call: the Retry-After header, or the
    /// body's "Rate limit is exceeded. Try again in 29 seconds."
    static func retryAfter(_ response: HTTPURLResponse, body: Data) -> TimeInterval? {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header) {
            return seconds
        }
        let text = String(decoding: body, as: UTF8.self)
        let pattern = try! Regex(#"[Tt]ry again in (\d+) second"#, as: (Substring, Substring).self)
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return TimeInterval(match.1)
    }

    static func decode(_ data: Data) throws -> GTFSRFeed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GTFSRFeed.self, from: data)
    }
}
