import CoreLocation
import Foundation

/// Decides which vehicles the map shows: every Luas and DART, plus either the
/// buses heading to the watched stop, or the buses nearest the reference point
/// (the user, or the map centre) within `busRadius`, up to `maxBuses`.
nonisolated enum VehicleFilter {
    static let busRadius: CLLocationDistance = 5_000
    static let maxBuses = 150

    struct Criteria: Sendable, Equatable {
        var modes: Set<TransportMode>
        /// Buses are measured from here. Nil shows none.
        var busCenter: CLLocationCoordinate2D?
        var watchedStopId: String?

        static func == (lhs: Criteria, rhs: Criteria) -> Bool {
            lhs.modes == rhs.modes && lhs.watchedStopId == rhs.watchedStopId
                && lhs.busCenter?.latitude == rhs.busCenter?.latitude
                && lhs.busCenter?.longitude == rhs.busCenter?.longitude
        }
    }

    struct Result: Sendable {
        var vehicles: [Vehicle]
        /// Vehicles per mode that pass the range/watch rules, regardless of the mode toggles.
        var counts: [TransportMode: Int] = [:]
        /// Predicted arrival at the watched stop, by vehicle id, when TripUpdates has one.
        var etas: [String: Date] = [:]
    }

    /// How long after its predicted arrival a vehicle is assumed to have left the stop.
    static let passedGrace: TimeInterval = 60

    static func apply(
        _ vehicles: [Vehicle],
        criteria: Criteria,
        data: StaticData,
        tripUpdates: GTFSRFeed?,
        now: Date = .now
    ) -> Result {
        // Luas and DART are always all shown; watching a stop only changes which buses.
        let rail = vehicles.filter { $0.mode != .bus }
        var result: Result
        if let stopId = criteria.watchedStopId, let stop = data.stopsById[stopId] {
            result = watching(stop, vehicles: vehicles.filter { $0.mode == .bus }, data: data, tripUpdates: tripUpdates, now: now)
            result.vehicles = rail + result.vehicles
        } else {
            let buses = criteria.busCenter.map { nearestBuses(vehicles, to: $0) } ?? []
            result = Result(vehicles: rail + buses)
        }
        for vehicle in result.vehicles { result.counts[vehicle.mode, default: 0] += 1 }
        result.vehicles.removeAll { !criteria.modes.contains($0.mode) }
        return result
    }

    /// Buses within `radius` of `center`, nearest first, at most `limit`.
    static func nearestBuses(
        _ vehicles: [Vehicle],
        to center: CLLocationCoordinate2D,
        radius: CLLocationDistance = busRadius,
        limit: Int = maxBuses
    ) -> [Vehicle] {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let inRange: [(Vehicle, CLLocationDistance)] = vehicles.compactMap { vehicle in
            guard vehicle.mode == .bus else { return nil }
            let distance = origin.distance(from: CLLocation(latitude: vehicle.latitude, longitude: vehicle.longitude))
            return distance <= radius ? (vehicle, distance) : nil
        }
        return inRange.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// Vehicles on any route + direction that calls at `stop`, minus those
    /// TripUpdates says have already been through it.
    static func watching(
        _ stop: Stop,
        vehicles: [Vehicle],
        data: StaticData,
        tripUpdates: GTFSRFeed?,
        now: Date
    ) -> Result {
        let served = data.routesServing(stop)
        let servedRouteIds = Set(served.map(\.routeId))
        let servedModes = Set(servedRouteIds.compactMap { data.routes[$0]?.mode })
        let stopIds = data.siblingStopIds(of: stop)

        // trip_id -> predicted time at this stop
        var predicted: [String: Date] = [:]
        for entity in tripUpdates?.entity ?? [] {
            guard let update = entity.tripUpdate, let tripId = update.trip?.tripId else { continue }
            for stopUpdate in update.stopTimeUpdate ?? [] {
                guard let id = stopUpdate.stopId, stopIds.contains(id),
                      let time = (stopUpdate.arrival ?? stopUpdate.departure)?.time?.value
                else { continue }
                predicted[tripId] = Date(timeIntervalSince1970: TimeInterval(time))
            }
        }

        var result = Result(vehicles: [])
        for vehicle in vehicles {
            let serves: Bool
            if let routeId = vehicle.routeId {
                serves = vehicle.directionId.map { served.contains(RouteDirection(routeId: routeId, directionId: $0)) }
                    ?? servedRouteIds.contains(routeId)
            } else {
                // Irish Rail trains carry no GTFS route; match on mode instead.
                serves = servedModes.contains(vehicle.mode)
            }
            guard serves else { continue }
            if let tripId = vehicle.tripId, let time = predicted[tripId] {
                if time < now.addingTimeInterval(-passedGrace) { continue }
                result.etas[vehicle.id] = time
            }
            result.vehicles.append(vehicle)
        }
        return result
    }
}
