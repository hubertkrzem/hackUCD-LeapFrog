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
/// Each vehicle's latest "ping" is a timeline of station calls: Irish Rail's
/// actual arrival/departure times so far plus its live expected times ahead,
/// or a Luas trip's predicted stop times from GTFS-R TripUpdates. Between pings
/// the vehicle follows that timeline, running station to station like a train.
/// If the timeline says it should already have left a station the feed says it
/// hasn't, the rest of the journey slips by the difference (it keeps its delay).
/// DARTs without movements fall back to the positions feed's station-only
/// updates. New pings never make a vehicle jump: corrections glide.
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
    /// Corrections are glided over this long rather than jumped.
    static let easeDuration: TimeInterval = 3
    /// Small backward corrections are absorbed by standing still instead.
    static let holdThreshold: Double = 40

    private struct Track {
        var run: RailRun
        /// What the run was built from, so an unchanged ping isn't re-applied.
        var source: Source
        var shown: Double?
        var easeFrom: (distance: Double, at: Date)?
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

    /// Applies the latest pings. `calls` holds each vehicle's timeline when known
    /// (keyed by vehicle id); `fetchedAt` is when each timeline was fetched.
    func ingest(_ vehicles: [Vehicle], calls: [String: [RailCall]], fetchedAt: [String: Date] = [:], now: Date = .now) {
        var seen = Set<String>()
        for vehicle in vehicles where vehicle.mode != .bus {
            seen.insert(vehicle.id)
            let previous = tracks[vehicle.id]
            if let journey = calls[vehicle.id], journey.count >= 2 {
                if previous?.source == .calls(journey) { continue }
                guard let run = makeRun(mode: vehicle.mode, calls: journey, fetchedAt: fetchedAt[vehicle.id] ?? now) else {
                    tracks[vehicle.id] = nil
                    continue
                }
                apply(run, source: .calls(journey), to: vehicle.id, previous: previous, now: now)
            } else if vehicle.mode == .dart {
                let atStation = vehicle.rail?.atStation ?? false
                let source = Source.station(latitude: vehicle.latitude, longitude: vehicle.longitude, atStation: atStation)
                if previous?.source == source { continue }
                guard let run = stationRun(for: vehicle, atStation: atStation, now: now) else {
                    tracks[vehicle.id] = nil
                    continue
                }
                apply(run, source: source, to: vehicle.id, previous: previous, now: now)
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
        var distance = track.run.distance(at: time)
        if let ease = track.easeFrom {
            let progress = time.timeIntervalSince(ease.at) / Self.easeDuration
            if progress < 1 {
                // Smoothstep, so corrections start and finish gently.
                let t = max(progress, 0), s = t * t * (3 - 2 * t)
                distance = ease.distance + (distance - ease.distance) * s
            } else {
                track.easeFrom = nil
            }
        } else if let shown = track.shown, shown > distance, shown - distance <= Self.holdThreshold {
            distance = shown
        }
        track.shown = distance
        tracks[vehicleId] = track
        return Placement(pathKey: track.run.pathKey, distance: distance)
    }

    /// Where the vehicle is shown, carried onto the new run's path (it may be a
    /// different path), and glided from there to the new estimate.
    private func apply(_ run: RailRun, source: Source, to id: String, previous: Track?, now: Date) {
        var track = Track(run: run, source: source)
        if let previous, let shown = previous.shown {
            var carried: Double? = shown
            if previous.run.pathKey != run.pathKey {
                carried = nil
                if let old = paths.paths[previous.run.pathKey], let new = paths.paths[run.pathKey] {
                    let point = old.point(at: shown)
                    if let p = new.project(latitude: point.latitude, longitude: point.longitude), p.offRoute < 50 {
                        carried = p.distance
                    }
                }
            }
            if let carried {
                track.shown = carried
                let fresh = run.distance(at: now)
                if carried - fresh > Self.holdThreshold || fresh - carried > 1 {
                    track.easeFrom = (carried, now)
                }
            }
        }
        tracks[id] = track
    }

    private func makeRun(mode: TransportMode, calls: [RailCall], fetchedAt: Date) -> RailRun? {
        guard let (key, path) = paths.path(mode: mode, calls: calls) else { return nil }
        let dwell = mode == .luas ? Self.tramDwell : Self.dartDwell
        // Arrive/depart times, filling gaps with a normal dwell.
        var events: [(arrive: Date, depart: Date, arriveSeen: Bool, departSeen: Bool)] = []
        for (i, call) in calls.enumerated() {
            guard let arrive = call.arrival ?? call.departure?.addingTimeInterval(i == 0 ? 0 : -dwell)
                ?? events.last?.depart else { return nil }
            let depart = i == calls.count - 1 ? arrive : (call.departure ?? arrive.addingTimeInterval(dwell))
            events.append((arrive, max(depart, arrive), call.hasArrived || i == 0, call.hasDeparted))
        }
        // The feed knows the vehicle hasn't reached its next event yet: if the
        // timeline says it should have, the rest of the journey runs that much late.
        // Events alternate arrive (even) / depart (odd).
        if calls.contains(where: { $0.hasArrived || $0.hasDeparted }),
           let pending = (0..<events.count * 2).first(where: { $0 % 2 == 0 ? !events[$0 / 2].arriveSeen : !events[$0 / 2].departSeen }) {
            let due = pending % 2 == 0 ? events[pending / 2].arrive : events[pending / 2].depart
            let slip = fetchedAt.timeIntervalSince(due)
            if slip > 0 {
                for k in pending..<(events.count * 2) {
                    if k % 2 == 0 {
                        events[k / 2].arrive = events[k / 2].arrive.addingTimeInterval(slip)
                    } else {
                        events[k / 2].depart = events[k / 2].depart.addingTimeInterval(slip)
                    }
                }
            }
        }
        // Times must never run backwards.
        for i in events.indices.dropFirst() {
            events[i].arrive = max(events[i].arrive, events[i - 1].depart)
            events[i].depart = max(events[i].depart, events[i].arrive)
        }
        let stops = zip(path.stopDistances, events).map { RailRun.Stop(distance: $0, arrive: $1.arrive, depart: $1.depart) }
        return RailRun(pathKey: key, stops: stops,
                       acceleration: mode == .luas ? Self.tramAcceleration : Self.acceleration)
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
