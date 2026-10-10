import Foundation

/// Real-time tram arrivals from the Luas forecasting API (no key required).
nonisolated struct LuasClient: Sendable {
    struct Forecast: Sendable {
        let message: String?
        let arrivals: [Arrival]
    }

    var session: URLSession = .shared

    @concurrent
    func forecast(stopCode: String) async throws -> Forecast {
        var components = URLComponents(string: "https://luasforecasts.rpa.ie/xml/get.ashx")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "forecast"),
            URLQueryItem(name: "stop", value: stopCode),
            URLQueryItem(name: "encrypt", value: "false"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransitAPIError.http(http.statusCode)
        }
        return Self.parse(data)
    }

    /// Parses `<stopInfo><message/><direction name><tram dueMins destination/>…`.
    static func parse(_ data: Data) -> Forecast {
        let delegate = ForecastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return Forecast(message: delegate.message, arrivals: delegate.arrivals)
    }

    private final class ForecastParser: NSObject, XMLParserDelegate {
        var message: String?
        var arrivals: [Arrival] = []
        private var direction: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "direction":
                direction = attributes["name"]
            case "tram":
                guard let destination = attributes["destination"], !destination.isEmpty,
                      destination.lowercased() != "no trams forecast"
                else { return }
                let due = attributes["dueMins"] ?? ""
                arrivals.append(Arrival(
                    id: "\(direction ?? "")-\(arrivals.count)",
                    routeName: "Luas",
                    destination: destination,
                    time: nil,
                    // "DUE" means arriving now.
                    dueMinutes: Int(due) ?? (due.uppercased() == "DUE" ? 0 : nil),
                    delay: nil,
                    group: direction
                ))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "message" {
                message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
