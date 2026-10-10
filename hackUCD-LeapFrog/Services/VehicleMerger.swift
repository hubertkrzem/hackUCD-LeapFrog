import Foundation

/// Combines the NTA feed with the Irish Rail and Luas fallbacks into one list
/// of vehicles. NTA data wins for a mode whenever it has any vehicles of it.
nonisolated enum VehicleMerger {
    /// Positions older than this are treated as stale and hidden.
    static let maxAge: TimeInterval = 180

    static func merge(
        ntaVehicles: GTFSRFeed?,
        tripUpdates: GTFSRFeed?,
        irishRail: [IrishRailClient.Train]?,
        data: StaticData,
        now: Date = .now
    ) -> [Vehicle] {
        var vehicles = ntaVehicles.map { ntaToVehicles($0, data: data, now: now) } ?? []
        let modesFromNTA = Set(vehicles.map(\.mode))

        if !modesFromNTA.contains(.dart), let irishRail {
            vehicles += irishRail.filter(\.isRunning).map { train in
                Vehicle(
                    id: "ir-\(train.code)",
                    mode: .dart,
                    latitude: train.latitude,
                    longitude: train.longitude,
                    routeName: "DART",
                    routeDescription: train.journey,
                    operatorName: "Iarnród Éireann / Irish Rail",
                    headsign: train.destination,
                    bearing: nil,
                    timestamp: now,
                    source: .irishRail,
                    tripId: train.code,
                    rail: train.railStatus
                )
            }
        }

        if !modesFromNTA.contains(.luas), let updates = tripUpdates?.entity?.compactMap(\.tripUpdate) {
            vehicles += LuasEstimator.estimate(tripUpdates: updates, data: data, now: now)
        }
        return vehicles
    }

    static func ntaToVehicles(_ feed: GTFSRFeed, data: StaticData, now: Date) -> [Vehicle] {
        (feed.entity ?? []).compactMap { entity in
            guard entity.isDeleted != true,
                  let position = entity.vehicle?.position,
                  position.latitude != 0, position.longitude != 0
            else { return nil }
            let vehicle = entity.vehicle!
            let timestamp = vehicle.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0.value)) } ?? now
            guard now.timeIntervalSince(timestamp) < maxAge else { return nil }

            let route = vehicle.trip?.routeId.flatMap { data.routes[$0] }
            let id = vehicle.vehicle?.id ?? entity.id ?? vehicle.trip?.tripId ?? UUID().uuidString
            return Vehicle(
                id: "nta-\(id)",
                mode: route?.mode ?? .bus,
                latitude: position.latitude,
                longitude: position.longitude,
                routeName: route?.shortName ?? "–",
                routeDescription: route?.longName,
                operatorName: route?.operatorName,
                headsign: route.flatMap { headsign(for: $0, directionId: vehicle.trip?.directionId?.value) },
                bearing: position.bearing,
                timestamp: timestamp,
                source: .nta,
                tripId: vehicle.trip?.tripId,
                routeId: vehicle.trip?.routeId,
                directionId: vehicle.trip?.directionId?.value,
                tripStart: vehicle.trip?.scheduledStart
            )
        }
    }

    /// Route long names read "Origin - Destination"; direction 1 runs the other way.
    static func headsign(for route: RouteInfo, directionId: Int?) -> String? {
        let ends = route.longName.components(separatedBy: " - ")
        guard ends.count >= 2, let directionId else { return nil }
        return directionId == 1 ? ends.first : ends.last
    }

    /// Upcoming arrivals at a stop from TripUpdates (used for bus and DART stops).
    static func arrivals(
        at stopIds: Set<String>,
        tripUpdates: GTFSRFeed?,
        data: StaticData,
        now: Date = .now
    ) -> [Arrival] {
        var result: [Arrival] = []
        for entity in tripUpdates?.entity ?? [] {
            guard let update = entity.tripUpdate, let trip = update.trip, !trip.isCanceled else { continue }
            for stopUpdate in update.stopTimeUpdate ?? [] {
                guard let stopId = stopUpdate.stopId, stopIds.contains(stopId) else { continue }
                let event = stopUpdate.arrival ?? stopUpdate.departure
                let time = event?.time.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }
                if let time, time < now.addingTimeInterval(-30) { continue }
                let route = trip.routeId.flatMap { data.routes[$0] }
                result.append(Arrival(
                    id: "\(trip.tripId ?? entity.id ?? UUID().uuidString)-\(stopId)",
                    routeName: route?.shortName ?? "–",
                    destination: route.flatMap { headsign(for: $0, directionId: trip.directionId?.value) }
                        ?? route?.longName ?? "",
                    time: time,
                    dueMinutes: nil,
                    delay: event?.delay?.value,
                    group: nil
                ))
            }
        }
        return result.sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
    }
}
