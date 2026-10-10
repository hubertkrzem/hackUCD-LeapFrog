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
        /// Service date as the API writes it, e.g. "10 Oct 2026"; needed for movements.
        var date: String = ""
    }

    /// One row of a train's journey: a station call with its actual times so far
    /// and Irish Rail's expected times for the rest.
    struct Movement: Sendable, Equatable {
        let stationCode: String
        /// "O" origin, "S" stop, "D" destination; "T" timing points are dropped.
        let type: String
        let expectedArrival: Date?
        let expectedDeparture: Date?
        let arrival: Date?
        let departure: Date?
    }

    static let url = URL(string: "https://api.irishrail.ie/realtime/realtime.asmx/getCurrentTrainsXML_WithTrainType?TrainType=D")!
    static let base = "https://api.irishrail.ie/realtime/realtime.asmx/"

    var session: URLSession = .shared

    @concurrent
    func currentDARTs() async throws -> [Train] {
        Self.parse(try await fetch(Self.url))
    }

    /// Every DART station's coordinates, keyed by station code (e.g. "MHIDE").
    @concurrent
    func stations() async throws -> [String: (latitude: Double, longitude: Double)] {
        let data = try await fetch(URL(string: Self.base + "getAllStationsXML_WithStationType?StationType=D")!)
        var result: [String: (latitude: Double, longitude: Double)] = [:]
        for record in XMLRecordParser.parse(data, recordElement: "objStation") {
            guard let code = record["StationCode"]?.trimmingCharacters(in: .whitespaces),
                  let lat = record["StationLatitude"].flatMap(Double.init),
                  let lon = record["StationLongitude"].flatMap(Double.init), lat != 0 else { continue }
            result[code] = (lat, lon)
        }
        return result
    }

    /// A train's journey so far and ahead.
    @concurrent
    func movements(for train: Train) async throws -> [Movement] {
        var components = URLComponents(string: Self.base + "getTrainMovementsXML")!
        components.queryItems = [URLQueryItem(name: "TrainId", value: train.code), URLQueryItem(name: "TrainDate", value: train.date)]
        return Self.parseMovements(try await fetch(components.url!), date: train.date)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransitAPIError.http(http.statusCode)
        }
        return data
    }

    static func parseMovements(_ data: Data, date: String) -> [Movement] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_IE_POSIX")
        formatter.timeZone = .dublin
        formatter.dateFormat = "d MMM yyyy"
        guard let day = formatter.date(from: date) else { return [] }
        var previous: Date?
        // "HH:mm:ss" on the service day; "00:00:00" or blank means none. Journeys
        // past midnight roll into the next day.
        func time(_ text: String?) -> Date? {
            guard let text, text != "00:00:00" else { return nil }
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var value = Calendar.dublin.date(bySettingHour: parts[0], minute: parts[1], second: parts[2], of: day)
            if let v = value, let previous, previous.timeIntervalSince(v) > 6 * 3600 {
                value = Calendar.dublin.date(byAdding: .day, value: 1, to: v)
            }
            if let value { previous = value }
            return value
        }
        return XMLRecordParser.parse(data, recordElement: "objTrainMovements").compactMap { record in
            guard let code = record["LocationCode"]?.trimmingCharacters(in: .whitespaces), !code.isEmpty,
                  let type = record["LocationType"], type != "T" else { return nil }
            return Movement(
                stationCode: code, type: type,
                expectedArrival: time(record["ExpectedArrival"]), expectedDeparture: time(record["ExpectedDeparture"]),
                arrival: time(record["Arrival"]), departure: time(record["Departure"])
            )
        }
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
                direction: record["Direction"] ?? "",
                date: record["TrainDate"] ?? ""
            )
        }
    }
}

nonisolated extension IrishRailClient.Movement {
    /// The journey as `RailTracker` calls, using station coordinates from `stations()`.
    static func calls(_ movements: [Self], stations: [String: (latitude: Double, longitude: Double)]) -> [RailCall] {
        movements.compactMap { m in
            guard let station = stations[m.stationCode] else { return nil }
            return RailCall(
                stationId: m.stationCode, latitude: station.latitude, longitude: station.longitude,
                arrival: m.arrival ?? m.expectedArrival, departure: m.departure ?? m.expectedDeparture,
                hasArrived: m.arrival != nil || m.departure != nil, hasDeparted: m.departure != nil
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

    /// "Arrived Killiney next stop Dalkey" means standing at Killiney; "Departed ..." means running.
    var railStatus: RailStatus {
        let southbound: Bool? = switch direction.lowercased() {
        case "southbound": true
        case "northbound": false
        default: nil
        }
        return RailStatus(southbound: southbound, atStation: progress?.hasPrefix("Departed") != true)
    }
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
