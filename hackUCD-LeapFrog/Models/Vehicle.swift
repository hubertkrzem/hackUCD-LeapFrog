import CoreLocation
import Foundation

nonisolated struct Vehicle: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case nta, irishRail, luasEstimate, luasForecast

        var label: String {
            switch self {
            case .nta: "Live GPS · NTA"
            case .irishRail: "Live · Irish Rail"
            case .luasEstimate: "Estimated from live timetable"
            case .luasForecast: "Live · Luas stop forecasts"
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
    /// Scheduled start of the trip (GTFS-R start_date + start_time), for route-based estimates.
    var tripStart: Date? = nil
    /// Irish Rail's direction and whether the train is standing at a station.
    var rail: RailStatus? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isEstimated: Bool { source == .luasEstimate }

    /// A copy placed at a route-based estimate (position and road bearing).
    func moved(to estimate: BusTracker.Estimate) -> Vehicle {
        Vehicle(id: id, mode: mode, latitude: estimate.latitude, longitude: estimate.longitude, routeName: routeName,
                routeDescription: routeDescription, operatorName: operatorName, headsign: headsign,
                bearing: estimate.bearing, timestamp: timestamp, source: source, tripId: tripId,
                routeId: routeId, directionId: directionId, tripStart: tripStart, rail: rail)
    }
}

/// What the Irish Rail feed says about a train beyond its position, which is
/// only ever the last station it arrived at or departed from.
nonisolated struct RailStatus: Hashable, Sendable {
    /// Nil when the feed doesn't say.
    let southbound: Bool?
    let atStation: Bool
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
