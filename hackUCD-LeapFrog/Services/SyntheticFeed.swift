#if DEBUG
import Foundation

/// Fake buses for testing the map without an API key. Enable with the launch
/// argument `-syntheticBuses 300`.
///
/// Buses drive along real Dublin route shapes at their own speeds, dwelling at
/// "stops", and — like the real NTA feed — report pings every 20 s that are
/// already 60 s old, so the route-based estimator has real work to do.
nonisolated struct SyntheticFeed: Sendable {
    static let pingInterval: TimeInterval = 20
    static let reportLag: TimeInterval = 60
    private static let stopSpacing = 400.0
    private static let dwell: TimeInterval = 15

    private struct Bus: Sendable {
        let id: String
        let tripId: String
        let shapeIndex: Int
        let routeId: String
        let directionId: Int
        let speed: Double
        var distance: Double
        var dwellLeft: TimeInterval
        var nextStop: Double
        var tripStart: Date?
    }

    let count: Int
    private var buses: [Bus] = []
    private var lastTick: Date?

    static var requestedCount: Int { UserDefaults.standard.integer(forKey: "syntheticBuses") }

    init(count: Int) {
        self.count = count
    }

    mutating func tick(data: StaticData, routes: BusRouteStore, now: Date = .now) -> [Vehicle] {
        if buses.isEmpty { spawn(routes: routes, now: now) }
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        let reportedAt = now.addingTimeInterval(-Self.reportLag)

        return buses.indices.compactMap { i in
            guard let shape = routes.shape(buses[i].shapeIndex) else { return nil }
            advance(&buses[i], by: dt, length: shape.length, now: now)
            let bus = buses[i]
            if bus.tripStart == nil, let offset = shape.scheduledOffset(at: bus.distance) {
                buses[i].tripStart = reportedAt.addingTimeInterval(-offset)
            }
            let point = shape.point(at: bus.distance)
            let route = data.routes[bus.routeId]
            return Vehicle(
                id: bus.id, mode: .bus, latitude: point.latitude, longitude: point.longitude,
                routeName: route?.shortName ?? "?", routeDescription: route?.longName, operatorName: route?.operatorName,
                headsign: route.flatMap { VehicleMerger.headsign(for: $0, directionId: bus.directionId) },
                bearing: point.bearing, timestamp: reportedAt, source: .nta, tripId: bus.tripId,
                routeId: bus.routeId, directionId: bus.directionId, tripStart: buses[i].tripStart
            )
        }
    }

    private func advance(_ bus: inout Bus, by dt: TimeInterval, length: Double, now: Date) {
        var remaining = dt
        while remaining > 0 {
            if bus.dwellLeft > 0 {
                let wait = min(remaining, bus.dwellLeft)
                bus.dwellLeft -= wait
                remaining -= wait
                continue
            }
            let timeToStop = (bus.nextStop - bus.distance) / bus.speed
            if timeToStop > remaining {
                bus.distance += bus.speed * remaining
                remaining = 0
            } else {
                bus.distance = bus.nextStop
                remaining -= timeToStop
                bus.nextStop += Self.stopSpacing
                bus.dwellLeft = Self.dwell
            }
            if bus.distance >= length {
                bus.distance = 0
                bus.nextStop = Self.stopSpacing
                bus.tripStart = nil
            }
        }
    }

    /// Picks real trips whose routes pass through central Dublin.
    private mutating func spawn(routes: BusRouteStore, now: Date) {
        var shapeRoute: [Int: (String, Int)] = [:]
        for (key, shapes) in routes.routeShapes {
            let parts = key.split(separator: "|")
            guard parts.count == 2, let direction = Int(parts[1]) else { continue }
            for shape in shapes { shapeRoute[shape] = (String(parts[0]), direction) }
        }
        var generator = SystemRandomNumberGenerator()
        for (tripId, shapeIndex) in routes.trips.shuffled(using: &generator) where buses.count < count {
            guard let (routeId, direction) = shapeRoute[shapeIndex], let shape = routes.shape(shapeIndex),
                  shape.length > 2_000
            else { continue }
            let middle = shape.point(at: shape.length / 2)
            guard abs(middle.latitude - 53.345) < 0.06, abs(middle.longitude + 6.26) < 0.1 else { continue }
            let distance = Double.random(in: 0..<shape.length, using: &generator)
            buses.append(Bus(
                id: "synthetic-\(buses.count)", tripId: tripId, shapeIndex: shapeIndex, routeId: routeId,
                directionId: direction, speed: Double.random(in: 5...12, using: &generator), distance: distance,
                dwellLeft: 0, nextStop: (distance / Self.stopSpacing).rounded(.up) * Self.stopSpacing, tripStart: nil
            ))
        }
    }
}
#endif
