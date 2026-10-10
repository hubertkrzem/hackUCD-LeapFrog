import Foundation

/// Keeps buses on their route and estimates where they are *now*.
///
/// NTA pings arrive 45–90 s after they were taken and only every ~20–30 s.
/// Each ping is snapped onto the bus's route shape (its "anchor"); between
/// pings the bus is advanced along the road, assuming it keeps the delay it
/// had at the anchor, so it follows the timetable's pace (slower in town,
/// faster on open road). Without a timetable it uses its observed speed.
final class BusTracker {
    nonisolated struct Estimate: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        let bearing: Double
    }

    /// Pings further than this from every candidate route are left unsnapped (diversions, wrong data).
    static let maxOffRoute: Double = 80
    /// Share of the bus's own recent speed mixed into the timetable pace. Tuned on
    /// real NTA pings: 25% was marginally best; the timetable does most of the work.
    static let observedSpeedWeight = 0.25
    /// Don't extrapolate further than this past a ping.
    static let maxHorizon: TimeInterval = 120
    static let maxSpeed: Double = 25
    static let defaultSpeed: Double = 6
    /// Buses are rarely genuinely early mid-route; large "early" readings are layovers.
    static let maxEarliness: TimeInterval = 120
    /// Small backward corrections are absorbed by holding still; larger ones ease back.
    static let holdThreshold: Double = 40
    static let easeDuration: TimeInterval = 2

    struct Track {
        var shapeIndex: Int
        var tripId: String?
        var anchorDistance: Double
        var anchorTime: Date
        var tripStart: Date?
        var delay: TimeInterval?
        var speed: Double?
        /// Last distance actually shown, so the bus never visibly jumps backwards.
        var shown: Double?
        var easeFrom: (distance: Double, at: Date)?
    }

    /// Prediction error stats, comparing the estimate against the next real ping.
    struct Accuracy {
        var estimateErrors: [Double] = []
        var rawErrors: [Double] = []

        var summary: String {
            func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
            return String(format: "pings %d · median error: estimate %.0f m vs last ping %.0f m",
                          estimateErrors.count, median(estimateErrors), median(rawErrors))
        }
    }

    private(set) var tracks: [String: Track] = [:]
    private(set) var accuracy = Accuracy()
    let store: BusRouteStore

    init(store: BusRouteStore) {
        self.store = store
    }

    func isTracked(_ vehicleId: String) -> Bool { tracks[vehicleId] != nil }

    func shape(for vehicleId: String) -> RouteShape? {
        tracks[vehicleId].flatMap { store.shape($0.shapeIndex) }
    }

    /// Snaps each bus's latest ping to its route. Call after every Vehicles refresh.
    func ingest(_ vehicles: [Vehicle], now: Date = .now) {
        var seen = Set<String>()
        for vehicle in vehicles where vehicle.mode == .bus {
            seen.insert(vehicle.id)
            let previous = tracks[vehicle.id]
            // Same ping as last time: nothing new to learn.
            if let previous, previous.anchorTime == vehicle.timestamp, previous.tripId == vehicle.tripId { continue }

            guard let (shapeIndex, shape, snapped) = snap(vehicle, previous: previous) else {
                tracks[vehicle.id] = nil
                continue
            }

            if let previous, previous.shapeIndex == shapeIndex, previous.tripId == vehicle.tripId {
                recordAccuracy(previous, shape: shape, newDistance: snapped, at: vehicle.timestamp)
            }

            var track = Track(
                shapeIndex: shapeIndex,
                tripId: vehicle.tripId,
                anchorDistance: snapped,
                anchorTime: vehicle.timestamp,
                tripStart: vehicle.tripStart
            )
            if let start = vehicle.tripStart, let offset = shape.scheduledOffset(at: snapped) {
                let delay = vehicle.timestamp.timeIntervalSince(start) - offset
                track.delay = max(delay, -Self.maxEarliness)
            }
            if let previous, previous.shapeIndex == shapeIndex {
                let dt = vehicle.timestamp.timeIntervalSince(previous.anchorTime)
                if dt > 5 {
                    let observed = min(max((snapped - previous.anchorDistance) / dt, 0), Self.maxSpeed)
                    track.speed = previous.speed.map { 0.5 * $0 + 0.5 * observed } ?? observed
                } else {
                    track.speed = previous.speed
                }
                track.shown = previous.shown
                // If the corrected estimate lands well behind what's on screen, glide back rather than jump.
                if let shown = previous.shown, rawDistance(track, shape: shape, at: now) < shown - Self.holdThreshold {
                    track.easeFrom = (shown, now)
                }
            }
            tracks[vehicle.id] = track
        }
        for id in tracks.keys where !seen.contains(id) {
            tracks[id] = nil
        }
    }

    /// Where to draw the bus at `time`, or nil to fall back to its raw ping.
    func estimate(for vehicleId: String, at time: Date = .now) -> Estimate? {
        guard var track = tracks[vehicleId], let shape = store.shape(track.shapeIndex) else { return nil }
        var distance = rawDistance(track, shape: shape, at: time)

        if let ease = track.easeFrom {
            let progress = time.timeIntervalSince(ease.at) / Self.easeDuration
            if progress < 1 {
                distance = ease.distance + (distance - ease.distance) * max(progress, 0)
            } else {
                track.easeFrom = nil
            }
        } else if let shown = track.shown, distance < shown, shown - distance <= Self.holdThreshold {
            distance = shown
        }
        track.shown = distance
        tracks[vehicleId] = track

        let point = shape.point(at: distance)
        return Estimate(latitude: point.latitude, longitude: point.longitude, bearing: point.bearing)
    }

    /// The model's prediction, before display smoothing.
    func rawDistance(_ track: Track, shape: RouteShape, at time: Date) -> Double {
        let elapsed = min(max(time.timeIntervalSince(track.anchorTime), 0), Self.maxHorizon)
        let observed = track.speed.map { track.anchorDistance + $0 * elapsed }
        let predicted: Double
        if let start = track.tripStart, let delay = track.delay,
           let scheduled = shape.distance(atOffset: track.anchorTime.addingTimeInterval(elapsed).timeIntervalSince(start) - delay) {
            predicted = observed.map { (1 - Self.observedSpeedWeight) * scheduled + Self.observedSpeedWeight * $0 } ?? scheduled
        } else {
            predicted = observed ?? track.anchorDistance + (shape.scheduledSpeed ?? Self.defaultSpeed) * elapsed
        }
        let ceiling = min(track.anchorDistance + Self.maxSpeed * elapsed, shape.length)
        return min(max(predicted, track.anchorDistance), ceiling)
    }

    private func snap(_ vehicle: Vehicle, previous: Track?) -> (Int, RouteShape, Double)? {
        var candidates = store.candidateShapes(tripId: vehicle.tripId, routeId: vehicle.routeId, directionId: vehicle.directionId)
        // Keep a bus on the variant it was already following when the trip hasn't changed.
        if let previous, previous.tripId == vehicle.tripId, !candidates.contains(previous.shapeIndex) {
            candidates.insert(previous.shapeIndex, at: 0)
        }
        var best: (Int, RouteShape, Double, Double)?
        for index in candidates {
            guard let shape = store.shape(index) else { continue }
            let hint = previous?.shapeIndex == index ? previous?.anchorDistance : nil
            guard let projection = shape.project(latitude: vehicle.latitude, longitude: vehicle.longitude, near: hint) else { continue }
            if projection.offRoute < (best?.3 ?? .infinity) {
                best = (index, shape, projection.distance, projection.offRoute)
            }
        }
        guard let best, best.3 <= Self.maxOffRoute else { return nil }
        return (best.0, best.1, best.2)
    }

    private func recordAccuracy(_ previous: Track, shape: RouteShape, newDistance: Double, at time: Date) {
        guard time.timeIntervalSince(previous.anchorTime) > 5 else { return }
        accuracy.estimateErrors.append(abs(rawDistance(previous, shape: shape, at: time) - newDistance))
        accuracy.rawErrors.append(abs(previous.anchorDistance - newDistance))
        if accuracy.estimateErrors.count > 2_000 {
            accuracy.estimateErrors.removeFirst(1_000)
            accuracy.rawErrors.removeFirst(1_000)
        }
    }
}
