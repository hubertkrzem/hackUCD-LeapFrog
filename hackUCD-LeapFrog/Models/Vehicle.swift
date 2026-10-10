import CoreLocation
import Foundation

nonisolated struct Vehicle: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case nta, irishRail, luasEstimate

        var label: String {
            switch self {
            case .nta: "Live GPS · NTA"
            case .irishRail: "Live · Irish Rail"
            case .luasEstimate: "Estimated from live timetable"
            }
        }
    }

    let id: String
    let mode: TransportMode
    let latitude: Double
    let longitude: Double
    let routeName: String
    let routeDescription: String?
    let operatorName: String?
    let headsign: String?
    let bearing: Double?
    let timestamp: Date
    let source: Source
    let tripId: String?
    /// GTFS route_id / direction_id, used for favourites and stop watching.
    /// Nil for Irish Rail trains, which aren't keyed by GTFS route.
    var routeId: String? = nil
    var directionId: Int? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isEstimated: Bool { source == .luasEstimate }
}

/// A predicted arrival shown in a stop's detail sheet.
nonisolated struct Arrival: Identifiable, Hashable, Sendable {
    let id: String
    let routeName: String
    let destination: String
    /// Absolute predicted time when known.
    let time: Date?
    /// Minutes until arrival when that is all the source gives us (Luas forecasts).
    let dueMinutes: Int?
    /// Seconds late (+) or early (-), when known.
    let delay: Int?
    let group: String?
}
