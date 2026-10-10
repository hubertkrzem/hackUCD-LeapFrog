import CoreLocation
import Foundation

// Shapes of the JSON produced by tools/build_static_data.py. Keys are kept
// short in the bundle to keep it small.

nonisolated struct Stop: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let name: String
    let code: String
    let latitude: Double
    let longitude: Double
    let mode: TransportMode
    /// Luas forecast abbreviation (e.g. "STS"), only set for Luas stops.
    let luasCode: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case id = "i", name = "n", code = "c", latitude = "la", longitude = "lo", mode = "m", luasCode = "a"
    }
}

nonisolated struct RouteInfo: Hashable, Sendable, Decodable {
    let shortName: String
    let longName: String
    let mode: TransportMode
    let operatorName: String

    enum CodingKeys: String, CodingKey {
        case shortName = "s", longName = "l", mode = "m", operatorName = "o"
    }
}

nonisolated struct LineShape: Sendable, Decodable {
    let routeId: String
    let name: String
    let mode: TransportMode
    let points: [[Double]]

    var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }

    enum CodingKeys: String, CodingKey {
        case routeId = "r", name = "n", mode = "m", points = "p"
    }
}

/// Luas stop patterns with scheduled offsets, used to place trams between stops.
nonisolated struct LuasSchedule: Sendable, Decodable {
    struct Pattern: Sendable, Decodable {
        let routeId: String
        let stopIds: [String]
        /// Seconds from the first stop's scheduled arrival.
        let offsets: [Int]

        enum CodingKeys: String, CodingKey {
            case routeId = "r", stopIds = "s", offsets = "t"
        }
    }

    let patterns: [Pattern]
    let trips: [String: Int]
}
