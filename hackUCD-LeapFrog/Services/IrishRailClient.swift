import Foundation

/// Live DART positions from the Irish Rail realtime API (no key required).
/// Used when the NTA feed carries no DART vehicles.
nonisolated struct IrishRailClient: Sendable {
    struct Train: Sendable, Equatable {
        let code: String
        let status: String
        let latitude: Double
        let longitude: Double
        let message: String
        let direction: String
    }

    static let url = URL(string: "https://api.irishrail.ie/realtime/realtime.asmx/getCurrentTrainsXML_WithTrainType?TrainType=D")!

    var session: URLSession = .shared

    @concurrent
    func currentDARTs() async throws -> [Train] {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransitAPIError.http(http.statusCode)
        }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [Train] {
        let records = XMLRecordParser.parse(data, recordElement: "objTrainPositions")
        return records.compactMap { record in
            guard let code = record["TrainCode"],
                  let lat = record["TrainLatitude"].flatMap(Double.init),
                  let lon = record["TrainLongitude"].flatMap(Double.init),
                  lat != 0, lon != 0
            else { return nil }
            return Train(
                code: code.trimmingCharacters(in: .whitespaces),
                status: record["TrainStatus"] ?? "",
                latitude: lat,
                longitude: lon,
                message: record["PublicMessage"] ?? "",
                direction: record["Direction"] ?? ""
            )
        }
    }
}

nonisolated extension IrishRailClient.Train {
    /// "R" = running, "N" = not yet departed.
    var isRunning: Bool { status == "R" }

    /// PublicMessage lines are separated by a literal "\n", e.g.
    /// "E209\n09:33 - Malahide to Bray (0 mins late)\nArrived Woodbrook next stop Bray".
    var messageLines: [String] {
        message.components(separatedBy: "\\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "Malahide to Bray" from the second message line.
    var journey: String? {
        guard messageLines.count > 1 else { return nil }
        var line = messageLines[1]
        if let dash = line.range(of: " - ") { line = String(line[dash.upperBound...]) }
        if let paren = line.range(of: " (") { line = String(line[..<paren.lowerBound]) }
        return line.isEmpty ? nil : line
    }

    var destination: String? {
        journey?.components(separatedBy: " to ").last
    }

    var progress: String? { messageLines.count > 2 ? messageLines[2] : nil }
}

/// Collects the text of each child element of every `recordElement` into a dictionary.
nonisolated final class XMLRecordParser: NSObject, XMLParserDelegate {
    private let recordElement: String
    private var records: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    private init(recordElement: String) {
        self.recordElement = recordElement
    }

    static func parse(_ data: Data, recordElement: String) -> [[String: String]] {
        let delegate = XMLRecordParser(recordElement: recordElement)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == recordElement { current = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == recordElement {
            if let current { records.append(current) }
            current = nil
        } else if current != nil {
            current?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }
}
