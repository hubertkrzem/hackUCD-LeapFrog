import Foundation

/// The DART lines as measurable track, with every station's position along them.
nonisolated struct RailNetwork: Sendable {
    nonisolated struct Station: Sendable {
        let name: String
        let distance: Double
    }

    let shapes: [RouteShape]
    /// Stations on each shape, sorted by distance.
    let stations: [[Station]]
    /// The Malahide–Greystones main line; the Howth branch only wins where it's clearly closer.
    let mainShape: Int

    /// Stations further than this from a line aren't on it.
    static let stationSnap: Double = 250

    init(data: StaticData) {
        let lines = data.lines.filter { $0.mode == .dart && $0.points.count > 1 }
        shapes = lines.map { line in
            RouteShape(latitudes: line.points.map { $0[0] }, longitudes: line.points.map { $0[1] },
                       profileDistances: [], profileOffsets: [])
        }
        let dartStops = data.stops.filter { $0.mode == .dart }
        stations = shapes.map { shape in
            dartStops.compactMap { stop -> Station? in
                guard let p = shape.project(latitude: stop.latitude, longitude: stop.longitude),
                      p.offRoute <= Self.stationSnap else { return nil }
                return Station(name: stop.name, distance: p.distance)
            }
            .sorted { $0.distance < $1.distance }
        }
        let lengths = shapes.map(\.length)
        mainShape = lengths.indices.max { lengths[$0] < lengths[$1] } ?? 0
    }

    /// Snaps a position to the track. On shared track the main line is preferred,
    /// unless the train is heading to Howth.
    func locate(latitude: Double, longitude: Double, towardsHowth: Bool) -> (shape: Int, distance: Double)? {
        let hits = shapes.indices.compactMap { index -> (Int, Double, Double)? in
            guard let p = shapes[index].project(latitude: latitude, longitude: longitude),
                  p.offRoute <= RailTracker.maxOffTrack else { return nil }
            return (index, p.distance, p.offRoute)
        }
        guard let nearest = hits.min(by: { $0.2 < $1.2 }) else { return nil }
        let preferred = hits.first { hit in
            let isMain = hit.0 == mainShape
            return (towardsHowth ? !isMain : isMain) && hit.2 <= nearest.2 + 60
        }
        let pick = preferred ?? nearest
        return (pick.0, pick.1)
    }

    /// +1 if increasing distance heads south at this point of the shape, else -1.
    func southSign(shape: Int, at distance: Double) -> Double {
        let line = shapes[shape]
        let ahead = line.point(at: distance + 150).latitude, behind = line.point(at: distance - 150).latitude
        return ahead <= behind ? 1 : -1
    }

    /// The next station strictly ahead of `distance` in `direction` (±1).
    func nextStation(shape: Int, after distance: Double, direction: Double) -> Station? {
        let list = stations[shape]
        return direction > 0
            ? list.first { $0.distance > distance + 30 }
            : list.last { $0.distance < distance - 30 }
    }

    /// The station at the end of the line in `direction`.
    func terminus(shape: Int, direction: Double) -> Station? {
        direction > 0 ? stations[shape].last : stations[shape].first
    }
}

/// A stop on a rail vehicle's journey and when it's there. Times the feed has
/// observed are actual; the rest are predictions.
nonisolated struct RailCall: Sendable, Equatable {
    let stationId: String
    let latitude: Double
    let longitude: Double
    var arrival: Date?
    var departure: Date?
    var hasArrived = false
    var hasDeparted = false
    /// The timetable's times, when the feed gives them.
    var scheduledArrival: Date? = nil
    var scheduledDeparture: Date? = nil
}

/// A journey's timeline along its track: at each stop, the distance along the
/// path and when the vehicle arrives and leaves. Between stops the vehicle
/// accelerates, cruises and brakes so it arrives exactly on time.
nonisolated struct RailRun: Sendable {
    nonisolated struct Stop: Sendable {
        let distance: Double
        let arrive: Date
        let depart: Date
    }

    let pathKey: String
    let stops: [Stop]
    let acceleration: Double

    func distance(at time: Date) -> Double {
        guard let first = stops.first else { return 0 }
        if time <= first.depart { return first.distance }
        for i in stops.indices.dropFirst() {
            let from = stops[i - 1], to = stops[i]
            if time < to.arrive {
                let elapsed = time.timeIntervalSince(from.depart)
                return from.distance + Self.travelled(over: to.distance - from.distance,
                                                      in: to.arrive.timeIntervalSince(from.depart),
                                                      after: elapsed, acceleration: acceleration)
            }
            if time <= to.depart { return to.distance }
        }
        return stops[stops.count - 1].distance
    }

    /// The time at which the run reaches `distance` (the earliest, if it stands there).
    func time(atDistance distance: Double) -> Date {
        guard let first = stops.first, let last = stops.last, stops.count > 1 else { return stops.first?.arrive ?? .now }
        var low = first.depart, high = last.arrive
        if distance <= first.distance { return low }
        if distance >= last.distance { return high }
        for _ in 0..<40 {
            let mid = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
            if self.distance(at: mid) < distance { low = mid } else { high = mid }
        }
        return high
    }

    /// Distance covered `t` seconds into a run of `length` metres that must take
    /// `duration` seconds, starting and ending at rest: a trapezoid speed profile
    /// with the given acceleration, or an S-curve when the stretch is too short for one.
    static func travelled(over length: Double, in duration: TimeInterval, after t: TimeInterval,
                          acceleration a: Double) -> Double {
        guard duration > 0, t < duration else { return length }
        guard t > 0, length > 0 else { return 0 }
        let discriminant = a * a * duration * duration - 4 * a * length
        guard discriminant >= 0 else {
            let u = t / duration
            return length * u * u * (3 - 2 * u)
        }
        let cruise = (a * duration - sqrt(discriminant)) / 2
        let ramp = cruise / a, rampDistance = cruise * cruise / (2 * a)
        if t < ramp { return 0.5 * a * t * t }
        if t < duration - ramp { return rampDistance + cruise * (t - ramp) }
        let left = duration - t
        return length - 0.5 * a * left * left
    }
}

/// Builds each journey's path by following the drawn Luas/DART track between
/// consecutive stops, so trams and trains stay on the rails even where a
/// journey spans several line shapes (Tallaght/Saggart, Howth/Malahide).
final class RailPaths {
    nonisolated struct Path: Sendable {
        let shape: RouteShape
        /// Distance along `shape` of each stop, in call order.
        let stopDistances: [Double]
    }

    /// A stop further than this from every line is joined by a straight line.
    static let snap: Double = 200

    private let lines: [(mode: TransportMode, shape: RouteShape)]
    private(set) var paths: [String: RouteShape] = [:]
    private var built: [String: Path] = [:]

    init(data: StaticData) {
        lines = data.lines.filter { $0.mode != .bus && $0.points.count > 1 }.map { line in
            (line.mode, RouteShape(latitudes: line.points.map { $0[0] }, longitudes: line.points.map { $0[1] },
                                   profileDistances: [], profileOffsets: []))
        }
    }

    static func key(mode: TransportMode, calls: [RailCall]) -> String {
        mode.rawValue + ":" + calls.map(\.stationId).joined(separator: ">")
    }

    func path(mode: TransportMode, calls: [RailCall]) -> (key: String, path: Path)? {
        guard calls.count >= 2 else { return nil }
        let key = Self.key(mode: mode, calls: calls)
        if let cached = built[key] { return (key, cached) }

        var latitudes: [Double] = [], longitudes: [Double] = []
        var stopIndices: [Int] = []
        func append(_ lat: Double, _ lon: Double) {
            if let lastLat = latitudes.last, let lastLon = longitudes.last,
               abs(lastLat - lat) < 1e-7, abs(lastLon - lon) < 1e-7 { return }
            latitudes.append(lat)
            longitudes.append(lon)
        }
        for i in calls.indices.dropLast() {
            for (j, point) in track(from: calls[i], to: calls[i + 1], mode: mode).enumerated() {
                append(point.latitude, point.longitude)
                if j == 0 { stopIndices.append(latitudes.count - 1) }
            }
        }
        // The last segment ended on the final stop.
        stopIndices.append(latitudes.count - 1)
        guard latitudes.count >= 2 else { return nil }
        let shape = RouteShape(latitudes: latitudes, longitudes: longitudes, profileDistances: [], profileOffsets: [])
        let path = Path(shape: shape, stopDistances: stopIndices.map { shape.cumulative[$0] })
        built[key] = path
        paths[key] = shape
        return (key, path)
    }

    /// The track between two adjacent stops: the stretch of whichever line passes
    /// closest to both, in travel order.
    private func track(from a: RailCall, to b: RailCall, mode: TransportMode) -> [(latitude: Double, longitude: Double)] {
        var best: (shape: RouteShape, from: Double, to: Double, off: Double)?
        for line in lines where line.mode == mode {
            guard let pa = line.shape.project(latitude: a.latitude, longitude: a.longitude),
                  let pb = line.shape.project(latitude: b.latitude, longitude: b.longitude),
                  pa.offRoute <= Self.snap, pb.offRoute <= Self.snap else { continue }
            let off = pa.offRoute + pb.offRoute
            if off < (best?.off ?? .infinity) { best = (line.shape, pa.distance, pb.distance, off) }
        }
        guard let best else { return [(a.latitude, a.longitude), (b.latitude, b.longitude)] }
        let shape = best.shape
        let start = shape.point(at: best.from), end = shape.point(at: best.to)
        var points = [(latitude: start.latitude, longitude: start.longitude)]
        let low = min(best.from, best.to), high = max(best.from, best.to)
        var inner = shape.cumulative.indices.filter { shape.cumulative[$0] > low && shape.cumulative[$0] < high }
        if best.to < best.from { inner.reverse() }
        points += inner.map { (shape.latitudes[$0], shape.longitudes[$0]) }
        points.append((end.latitude, end.longitude))
        return points
    }
}

/// Keeps Luas trams and DART trains on their track and estimates where they
/// are *now*, like `BusTracker` does for buses.
///
/// Rail runs to a timetable, so the timetable is the backbone: each vehicle has a
/// *schedule clock* and is drawn where its timetable puts it at that clock time.
/// The live feeds only decide how late it's running (a target delay), and the
/// clock is steered towards that at between 0.5x and 2x real time. So a vehicle
/// can speed up, slow down or stand, but never jump or run backwards.
///
/// Feed data:
/// - DART: Irish Rail movements give the timetable, actual arrival/departure times
///   so far and live expected times ahead. A train is never drawn leaving a station
///   until the feed confirms it reached and left it.
/// - Luas: the timetable comes from the GTFS trip, the delay from its TripUpdates.
/// - DARTs without movements fall back to station-only dead reckoning.
///
/// Replayed second by second against two recordings of live Irish Rail data
/// (with 10 s polling), this cut DART median error from ~66 m to 13-39 m and
/// backward moves from ~25 per train-hour to none.
final class RailTracker {
    nonisolated struct Placement: Sendable, Equatable {
        let pathKey: String
        /// Metres along the path to the middle of the vehicle.
        let distance: Double
    }

    static let maxOffTrack: Double = 300
    static let cruiseSpeed: Double = 16
    static let acceleration: Double = 0.7
    static let tramAcceleration: Double = 0.9
    static let dartDwell: TimeInterval = 30
    static let tramDwell: TimeInterval = 20
    /// The schedule clock runs at between these multiples of real time.
    static let minClockRate = 0.5
    static let maxClockRate = 2.0
    /// Clock rate nudge per second of difference from the target delay.
    static let clockGain = 0.05

    /// What a feed update says about a vehicle: its timetable along its path, how
    /// late it's running, and how far it's confirmed to have got.
    private struct Plan {
        var schedule: RailRun
        var targetDelay: TimeInterval
        /// Schedule time the clock may not pass: the departure from the first station
        /// the feed hasn't yet confirmed the train reached and left.
        var limit: Date?
    }

    private struct Track {
        var plan: Plan
        /// What the plan was built from, so an unchanged update isn't re-applied.
        var source: Source
        /// Schedule time the vehicle is at.
        var clock: Date
        var updatedAt: Date

        /// Steers the clock towards the target delay; never backwards, never past the limit.
        mutating func advance(to time: Date) {
            let dt = time.timeIntervalSince(updatedAt)
            guard dt > 0 else { return }
            let gap = time.addingTimeInterval(-plan.targetDelay).timeIntervalSince(clock)
            let rate = min(max(1 + RailTracker.clockGain * gap, RailTracker.minClockRate), RailTracker.maxClockRate)
            var next = clock.addingTimeInterval(rate * dt)
            if let limit = plan.limit { next = min(next, max(limit, clock)) }
            clock = next
            updatedAt = time
        }

        var distance: Double { plan.schedule.distance(at: clock) }
    }

    private enum Source: Equatable {
        case calls([RailCall])
        case station(latitude: Double, longitude: Double, atStation: Bool)
    }

    let network: RailNetwork
    let paths: RailPaths
    private var tracks: [String: Track] = [:]

    init(data: StaticData) {
        network = RailNetwork(data: data)
        paths = RailPaths(data: data)
    }

    /// Every path a placement can refer to.
    var pathShapes: [String: RouteShape] { paths.paths }

    /// Applies the latest feed data. `calls` holds each vehicle's journey when known
    /// (keyed by vehicle id); `fetchedAt` is when each journey was fetched.
    func ingest(_ vehicles: [Vehicle], calls: [String: [RailCall]], fetchedAt: [String: Date] = [:], now: Date = .now) {
        var seen = Set<String>()
        for vehicle in vehicles where vehicle.mode != .bus {
            seen.insert(vehicle.id)
            let previous = tracks[vehicle.id]
            if let journey = calls[vehicle.id], journey.count >= 2 {
                if previous?.source == .calls(journey) { continue }
                guard let plan = makePlan(mode: vehicle.mode, calls: journey, fetchedAt: fetchedAt[vehicle.id] ?? now) else {
                    tracks[vehicle.id] = nil
                    continue
                }
                apply(plan, source: .calls(journey), to: vehicle.id, previous: previous, now: now)
            } else if vehicle.mode == .dart {
                let atStation = vehicle.rail?.atStation ?? false
                let source = Source.station(latitude: vehicle.latitude, longitude: vehicle.longitude, atStation: atStation)
                if previous?.source == source { continue }
                guard let run = stationRun(for: vehicle, atStation: atStation, now: now) else {
                    tracks[vehicle.id] = nil
                    continue
                }
                apply(Plan(schedule: run, targetDelay: 0, limit: nil), source: source, to: vehicle.id, previous: previous, now: now)
            } else {
                tracks[vehicle.id] = nil
            }
        }
        for id in tracks.keys where !seen.contains(id) {
            tracks[id] = nil
        }
    }

    func placement(for vehicleId: String, at time: Date = .now) -> Placement? {
        guard var track = tracks[vehicleId] else { return nil }
        track.advance(to: time)
        tracks[vehicleId] = track
        return Placement(pathKey: track.plan.schedule.pathKey, distance: track.distance)
    }

    /// Keeps the vehicle's clock (it never jumps); on a new path, finds the clock
    /// time that puts it where it's currently drawn.
    private func apply(_ plan: Plan, source: Source, to id: String, previous: Track?, now: Date) {
        var clock = now.addingTimeInterval(-plan.targetDelay)
        if let limit = plan.limit { clock = min(clock, limit) }
        if var previous {
            previous.advance(to: now)
            if previous.plan.schedule.pathKey == plan.schedule.pathKey {
                clock = previous.clock
            } else if let old = paths.paths[previous.plan.schedule.pathKey], let new = paths.paths[plan.schedule.pathKey] {
                let point = old.point(at: previous.distance)
                if let p = new.project(latitude: point.latitude, longitude: point.longitude), p.offRoute < 50 {
                    clock = plan.schedule.time(atDistance: p.distance)
                }
            }
        }
        tracks[id] = Track(plan: plan, source: source, clock: clock, updatedAt: now)
    }

    private func makePlan(mode: TransportMode, calls: [RailCall], fetchedAt: Date) -> Plan? {
        guard let (key, path) = paths.path(mode: mode, calls: calls) else { return nil }
        let dwell = mode == .luas ? Self.tramDwell : Self.dartDwell
        let last = calls.count - 1
        // Without a full timetable, the predictions themselves are the schedule.
        let timetabled = calls.enumerated().allSatisfy { i, call in
            (i == 0 ? call.scheduledDeparture : call.scheduledArrival ?? call.scheduledDeparture) != nil
        }
        func times(_ arrival: Date?, _ departure: Date?, at i: Int, previous: Date?) -> (arrive: Date, depart: Date)? {
            guard let arrive = (i == 0 ? departure ?? arrival : arrival ?? departure?.addingTimeInterval(-dwell)) ?? previous
            else { return nil }
            let depart = i == last ? arrive : (departure ?? arrive.addingTimeInterval(dwell))
            return (arrive, max(depart, arrive))
        }
        var schedule: [(arrive: Date, depart: Date)] = []
        for (i, call) in calls.enumerated() {
            let pair = timetabled
                ? times(call.scheduledArrival, call.scheduledDeparture, at: i, previous: schedule.last?.depart)
                : times(call.arrival, call.departure, at: i, previous: schedule.last?.depart)
            guard var pair else { return nil }
            if let before = schedule.last {
                pair.arrive = max(pair.arrive, before.depart)
                pair.depart = max(pair.depart, pair.arrive)
            }
            schedule.append(pair)
        }
        let run = RailRun(pathKey: key,
                          stops: zip(path.stopDistances, schedule).map { RailRun.Stop(distance: $0, arrive: $1.arrive, depart: $1.depart) },
                          acceleration: mode == .luas ? Self.tramAcceleration : Self.acceleration)
        guard timetabled else { return Plan(schedule: run, targetDelay: 0, limit: nil) }

        // Events in order: arrive (k = 0) and depart (k = 1) at each call.
        let events = calls.indices.flatMap { i in [(i, 0), (i, 1)] }
        func predicted(_ i: Int, _ k: Int) -> Date? { k == 0 ? calls[i].arrival : calls[i].departure }
        func scheduled(_ i: Int, _ k: Int) -> Date { k == 0 ? schedule[i].arrive : schedule[i].depart }

        if calls.contains(where: { $0.hasArrived || $0.hasDeparted }) {
            // The first event the feed hasn't confirmed yet.
            let confirmed: (Int, Int) -> Bool = { i, k in
                k == 0 ? (i == 0 || calls[i].hasArrived || calls[i].hasDeparted) : (calls[i].hasDeparted || (i == last && calls[i].hasArrived))
            }
            guard let (i, k) = events.first(where: { !confirmed($0.0, $0.1) }) else {
                let arrived = calls[last].arrival ?? schedule[last].arrive
                return Plan(schedule: run, targetDelay: arrived.timeIntervalSince(schedule[last].arrive), limit: nil)
            }
            // Irish Rail's live prediction for that event, and at least as late as it
            // already is if it's overdue.
            var delay = (predicted(i, k) ?? scheduled(i, k)).timeIntervalSince(scheduled(i, k))
            delay = max(delay, fetchedAt.timeIntervalSince(scheduled(i, k)))
            return Plan(schedule: run, targetDelay: delay, limit: schedule[i].depart)
        }
        // Predictions only (Luas): the delay at the next stop ahead.
        let next = events.first { predicted($0.0, $0.1).map { $0 >= fetchedAt } ?? false } ?? (last, 0)
        let delay = (predicted(next.0, next.1) ?? scheduled(next.0, next.1)).timeIntervalSince(scheduled(next.0, next.1))
        return Plan(schedule: run, targetDelay: delay, limit: nil)
    }

    /// Without a timeline, a DART is only known to be at, or to have just left, a
    /// station: it waits there, or runs to the next station and stops.
    private func stationRun(for vehicle: Vehicle, atStation: Bool, now: Date) -> RailRun? {
        let towardsHowth = (vehicle.headsign ?? vehicle.routeDescription ?? "").localizedCaseInsensitiveContains("Howth")
        guard let (shape, distance) = network.locate(latitude: vehicle.latitude, longitude: vehicle.longitude,
                                                     towardsHowth: towardsHowth) else { return nil }
        let line = network.shapes[shape]
        let here = line.point(at: distance)
        var direction: Double = 1
        if let southbound = vehicle.rail?.southbound {
            direction = network.southSign(shape: shape, at: distance) * (southbound ? 1 : -1)
        }
        let origin = RailCall(stationId: "@\(Int(distance))", latitude: here.latitude, longitude: here.longitude)
        let next = network.nextStation(shape: shape, after: distance, direction: direction)
        guard let next else {
            // At the end of the line: stand at the buffers, on the track that leads there.
            guard let previous = network.nextStation(shape: shape, after: distance, direction: -direction) else { return nil }
            let before = line.point(at: previous.distance)
            let from = RailCall(stationId: "@\(Int(previous.distance))", latitude: before.latitude, longitude: before.longitude)
            guard let (key, path) = paths.path(mode: .dart, calls: [from, origin]) else { return nil }
            return RailRun(pathKey: key, stops: [RailRun.Stop(distance: path.stopDistances[1], arrive: now, depart: .distantFuture)],
                           acceleration: Self.acceleration)
        }
        let there = line.point(at: next.distance)
        let destination = RailCall(stationId: "@\(Int(next.distance))", latitude: there.latitude, longitude: there.longitude)
        guard let (key, path) = paths.path(mode: .dart, calls: [origin, destination]) else { return nil }
        let start = path.stopDistances[0], end = path.stopDistances[1]
        if atStation {
            return RailRun(pathKey: key, stops: [RailRun.Stop(distance: start, arrive: now, depart: .distantFuture)],
                           acceleration: Self.acceleration)
        }
        let arrival = now.addingTimeInterval(Self.runTime(over: end - start))
        return RailRun(pathKey: key, stops: [
            RailRun.Stop(distance: start, arrive: now, depart: now),
            RailRun.Stop(distance: end, arrive: arrival, depart: .distantFuture),
        ], acceleration: Self.acceleration)
    }

    /// How long a DART takes to run `length` metres between stops at full pace.
    nonisolated static func runTime(over length: Double) -> TimeInterval {
        let peak = min(cruiseSpeed, sqrt(acceleration * length))
        let rampDistance = peak * peak / (2 * acceleration)
        return 2 * peak / acceleration + (length - 2 * rampDistance) / peak
    }

    /// Distance covered `t` seconds into a full-pace run of `length` metres.
    nonisolated static func travelled(over length: Double, after t: TimeInterval) -> Double {
        RailRun.travelled(over: length, in: runTime(over: length), after: t, acceleration: acceleration)
    }
}
