#if DEBUG
import Foundation

/// Fake buses and DARTs for testing the map without an API key. Enable with the
/// launch arguments `-syntheticBuses 300` and/or `-syntheticTrains 14`.
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

    /// Runs station to station like a real DART, but reports only what Irish Rail
    /// would: the station it last arrived at or departed from.
    private struct Train: Sendable {
        let id: String
        let shape: Int
        var direction: Double
        var station: Int
        /// Standing at `station` until this time, or running away from it since.
        var dwellUntil: Date?
        var departedAt: Date?
    }

    private static let trainDwell: TimeInterval = 30
    private static let terminusDwell: TimeInterval = 120

    let count: Int
    let trainCount: Int
    private var buses: [Bus] = []
    private var trains: [Train] = []
    private var lastTick: Date?

    static var requestedCount: Int { UserDefaults.standard.integer(forKey: "syntheticBuses") }
    static var requestedTrains: Int { UserDefaults.standard.integer(forKey: "syntheticTrains") }

    init(count: Int, trains: Int = 0) {
        self.count = count
        trainCount = trains
    }

    mutating func tick(data: StaticData, routes: BusRouteStore, rail: RailNetwork, now: Date = .now) -> [Vehicle] {
        tickBuses(data: data, routes: routes, now: now) + tickTrains(rail: rail, now: now)
    }

    private mutating func tickTrains(rail: RailNetwork, now: Date) -> [Vehicle] {
        if trains.isEmpty, trainCount > 0 { spawnTrains(rail: rail, now: now) }
        return trains.indices.compactMap { i in
            advance(&trains[i], rail: rail, now: now)
            let train = trains[i]
            let stations = rail.stations[train.shape]
            guard stations.indices.contains(train.station) else { return nil }
            let point = rail.shapes[train.shape].point(at: stations[train.station].distance)
            let southbound = rail.southSign(shape: train.shape, at: stations[train.station].distance) * train.direction > 0
            let terminus = rail.terminus(shape: train.shape, direction: train.direction)?.name
            return Vehicle(
                id: train.id, mode: .dart, latitude: point.latitude, longitude: point.longitude,
                routeName: "DART", routeDescription: terminus.map { "Synthetic to \($0)" },
                operatorName: "Iarnród Éireann / Irish Rail", headsign: terminus, bearing: nil, timestamp: now,
                source: .irishRail, tripId: train.id,
                rail: RailStatus(southbound: southbound, atStation: train.dwellUntil != nil)
            )
        }
    }

    private func advance(_ train: inout Train, rail: RailNetwork, now: Date) {
        let stations = rail.stations[train.shape]
        while true {
            if let until = train.dwellUntil {
                guard now >= until else { return }
                // Turn round at the end of the line.
                let next = train.station + Int(train.direction)
                if !stations.indices.contains(next) { train.direction = -train.direction }
                train.dwellUntil = nil
                train.departedAt = until
            } else if let departed = train.departedAt {
                let next = train.station + Int(train.direction)
                guard stations.indices.contains(next) else {
                    train.dwellUntil = now
                    continue
                }
                let arrival = departed.addingTimeInterval(
                    RailTracker.runTime(over: abs(stations[next].distance - stations[train.station].distance)))
                guard now >= arrival else { return }
                train.station = next
                train.departedAt = nil
                let atEnd = !stations.indices.contains(next + Int(train.direction))
                train.dwellUntil = arrival.addingTimeInterval(atEnd ? Self.terminusDwell : Self.trainDwell)
            } else {
                train.dwellUntil = now
            }
        }
    }

    private mutating func spawnTrains(rail: RailNetwork, now: Date) {
        var generator = SystemRandomNumberGenerator()
        for index in 0..<trainCount {
            // Mostly the main line, as on the real network.
            let shape = index % 4 == 3 ? (rail.mainShape == 0 ? 1 : 0) : rail.mainShape
            guard rail.shapes.indices.contains(shape), rail.stations[shape].count > 1 else { continue }
            let station = Int.random(in: 0..<rail.stations[shape].count, using: &generator)
            let running = Bool.random(using: &generator)
            trains.append(Train(
                id: "synthetic-dart-\(index)", shape: shape, direction: Bool.random(using: &generator) ? 1 : -1,
                station: station,
                dwellUntil: running ? nil : now.addingTimeInterval(.random(in: 0...Self.trainDwell, using: &generator)),
                departedAt: running ? now.addingTimeInterval(-.random(in: 0...60, using: &generator)) : nil
            ))
        }
    }

    private mutating func tickBuses(data: StaticData, routes: BusRouteStore, now: Date) -> [Vehicle] {
        guard count > 0 else { return [] }
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
