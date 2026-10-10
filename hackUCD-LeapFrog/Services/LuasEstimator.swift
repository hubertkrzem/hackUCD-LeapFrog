import Foundation

/// Places Luas trams on the map from GTFS-R TripUpdates when the vehicle feed
/// has no tram positions. Each trip's predicted times along its stop pattern
/// are worked out (scheduled offset + propagated delay, or an absolute time if
/// given), and the tram is interpolated between the two stops it is between now.
nonisolated enum LuasEstimator {
    static func estimate(
        tripUpdates: [GTFSRFeed.TripUpdate],
        data: StaticData,
        now: Date = .now
    ) -> [Vehicle] {
        tripUpdates.compactMap { update in
            guard let trip = update.trip, !trip.isCanceled,
                  let tripId = trip.tripId,
                  let patternIndex = data.luas.trips[tripId],
                  data.luas.patterns.indices.contains(patternIndex)
            else { return nil }
            let pattern = data.luas.patterns[patternIndex]
            guard let times = predictedTimes(pattern: pattern, trip: trip, updates: update.stopTimeUpdate ?? []),
                  let position = position(at: now, times: times, stopIds: pattern.stopIds, data: data)
            else { return nil }

            let route = data.routes[pattern.routeId]
            let destination = pattern.stopIds.last.flatMap { data.stopsById[$0]?.name }
            return Vehicle(
                id: "luas-\(tripId)",
                mode: .luas,
                latitude: position.latitude,
                longitude: position.longitude,
                routeName: route?.shortName ?? "Luas",
                routeDescription: route?.longName,
                operatorName: route?.operatorName,
                headsign: destination,
                bearing: position.bearing,
                timestamp: now,
                source: .luasEstimate,
                tripId: tripId,
                routeId: pattern.routeId,
                directionId: trip.directionId?.value
            )
        }
    }

    /// Predicted arrival time at each stop of the pattern.
    static func predictedTimes(
        pattern: LuasSchedule.Pattern,
        trip: GTFSRFeed.TripDescriptor,
        updates: [GTFSRFeed.StopTimeUpdate]
    ) -> [Date]? {
        let start = trip.scheduledStart
        // Map each update onto a pattern index, by stop_id first, then stop_sequence (1-based).
        var byIndex: [Int: GTFSRFeed.StopTimeUpdate] = [:]
        for update in updates where update.scheduleRelationship?.uppercased() != "SKIPPED" {
            if let stopId = update.stopId, let index = pattern.stopIds.firstIndex(of: stopId) {
                byIndex[index] = update
            } else if let sequence = update.stopSequence?.value, pattern.stopIds.indices.contains(sequence - 1) {
                byIndex[sequence - 1] = update
            }
        }
        guard start != nil || byIndex.values.contains(where: { $0.arrival?.time != nil || $0.departure?.time != nil }) else {
            return nil
        }

        // Delays propagate forward to later stops; stops before the first update use its delay.
        let firstDelay = byIndex.keys.min().flatMap { delay(of: byIndex[$0]!) } ?? 0
        var currentDelay = firstDelay
        var times: [Date] = []
        for index in pattern.stopIds.indices {
            let update = byIndex[index]
            if let update, let d = delay(of: update) { currentDelay = d }
            if let absolute = update?.arrival?.time?.value ?? update?.departure?.time?.value {
                times.append(Date(timeIntervalSince1970: TimeInterval(absolute)))
            } else if let start {
                times.append(start.addingTimeInterval(TimeInterval(pattern.offsets[index] + currentDelay)))
            } else {
                return nil
            }
        }
        return times
    }

    private static func delay(of update: GTFSRFeed.StopTimeUpdate) -> Int? {
        update.arrival?.delay?.value ?? update.departure?.delay?.value
    }

    static func position(
        at now: Date,
        times: [Date],
        stopIds: [String],
        data: StaticData
    ) -> (latitude: Double, longitude: Double, bearing: Double)? {
        guard let first = times.first, let last = times.last, now >= first, now <= last else { return nil }
        guard let next = times.firstIndex(where: { $0 > now }), next > 0 else {
            // Exactly at the final stop.
            guard let stop = stopIds.last.flatMap({ data.stopsById[$0] }) else { return nil }
            return (stop.latitude, stop.longitude, 0)
        }
        guard let from = data.stopsById[stopIds[next - 1]], let to = data.stopsById[stopIds[next]] else { return nil }
        let span = times[next].timeIntervalSince(times[next - 1])
        let fraction = span > 0 ? min(max(now.timeIntervalSince(times[next - 1]) / span, 0), 1) : 1
        return (
            from.latitude + (to.latitude - from.latitude) * fraction,
            from.longitude + (to.longitude - from.longitude) * fraction,
            bearing(fromLat: from.latitude, fromLon: from.longitude, toLat: to.latitude, toLon: to.longitude)
        )
    }

    static func bearing(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> Double {
        let φ1 = fromLat * .pi / 180, φ2 = toLat * .pi / 180
        let Δλ = (toLon - fromLon) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
