import Foundation

// GTFS-Realtime as served by the NTA API in JSON form. Every field is optional
// and numeric fields accept either numbers or strings, because protobuf-to-JSON
// encoders serialise 64-bit ints (timestamps) as strings.

nonisolated struct GTFSRFeed: Decodable, Sendable {
    let header: Header?
    let entity: [Entity]?

    struct Header: Decodable, Sendable {
        let timestamp: FlexibleInt?
    }

    struct Entity: Decodable, Sendable {
        let id: String?
        let isDeleted: Bool?
        let vehicle: VehiclePosition?
        let tripUpdate: TripUpdate?
    }

    struct TripDescriptor: Decodable, Sendable {
        let tripId: String?
        let routeId: String?
        let directionId: FlexibleInt?
        let startTime: String?
        let startDate: String?
        let scheduleRelationship: String?
    }

    struct VehicleDescriptor: Decodable, Sendable {
        let id: String?
        let label: String?
    }

    struct Position: Decodable, Sendable {
        let latitude: Double
        let longitude: Double
        let bearing: Double?
    }

    struct VehiclePosition: Decodable, Sendable {
        let trip: TripDescriptor?
        let vehicle: VehicleDescriptor?
        let position: Position?
        let timestamp: FlexibleInt?
    }

    struct StopTimeEvent: Decodable, Sendable {
        let delay: FlexibleInt?
        let time: FlexibleInt?
    }

    struct StopTimeUpdate: Decodable, Sendable {
        let stopSequence: FlexibleInt?
        let stopId: String?
        let arrival: StopTimeEvent?
        let departure: StopTimeEvent?
        let scheduleRelationship: String?
    }

    struct TripUpdate: Decodable, Sendable {
        let trip: TripDescriptor?
        let vehicle: VehicleDescriptor?
        let stopTimeUpdate: [StopTimeUpdate]?
        let timestamp: FlexibleInt?
    }
}

/// An integer that may arrive as a JSON number or a numeric string.
nonisolated struct FlexibleInt: Decodable, Sendable, Hashable {
    let value: Int

    init(_ value: Int) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int(double)
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer")
        }
    }
}

nonisolated extension GTFSRFeed.TripDescriptor {
    var isCanceled: Bool {
        let relationship = scheduleRelationship?.uppercased()
        return relationship == "CANCELED" || relationship == "CANCELLED"
    }

    /// The trip's scheduled start (start_date + start_time) in Irish local time.
    /// start_time may exceed 24:00:00 for trips running past midnight.
    var scheduledStart: Date? {
        guard let startDate, let startTime, startDate.count == 8 else { return nil }
        let parts = startTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3,
              let year = Int(startDate.prefix(4)),
              let month = Int(startDate.dropFirst(4).prefix(2)),
              let day = Int(startDate.suffix(2))
        else { return nil }
        // GTFS times count from noon minus 12h, which equals midnight except on DST change days.
        var components = DateComponents(year: year, month: month, day: day, hour: 12)
        components.timeZone = .dublin
        guard let noon = Calendar.dublin.date(from: components) else { return nil }
        let seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return noon.addingTimeInterval(TimeInterval(seconds - 12 * 3600))
    }
}

extension TimeZone {
    nonisolated static let dublin = TimeZone(identifier: "Europe/Dublin")!
}

extension Calendar {
    nonisolated static let dublin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .dublin
        return calendar
    }()
}
