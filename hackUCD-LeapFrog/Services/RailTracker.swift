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

/// Keeps DART trains on the track and moves them like trains between the
/// coarse Irish Rail updates, which only ever place a train at a station.
///
/// After "Departed X" a train accelerates, cruises and brakes to a stop at the
/// next station, then waits there until the feed catches up.
final class RailTracker {
    nonisolated struct Placement: Sendable, Equatable {
        let shape: Int
        /// Metres along the shape to the middle of the train.
        let distance: Double
        /// +1 if the train runs towards increasing distance.
        let direction: Double
    }

    static let maxOffTrack: Double = 300
    static let cruiseSpeed: Double = 16
    static let acceleration: Double = 0.7
    /// Corrections are glided over this long rather than jumped.
    static let easeDuration: TimeInterval = 3
    /// Small backward corrections are absorbed by standing still instead.
    static let holdThreshold: Double = 40

    private struct Track {
        var shape: Int
        var direction: Double
        var anchor: Double
        var anchorTime: Date
        /// Where the train will stop: the next station, or nil if it's standing.
        var target: Double?
        var rawLatitude: Double
        var rawLongitude: Double
        var atStation: Bool
        var shown: Double?
        var easeFrom: (distance: Double, at: Date)?
    }

    let network: RailNetwork
    private var tracks: [String: Track] = [:]

    init(network: RailNetwork) {
        self.network = network
    }

    func ingest(_ vehicles: [Vehicle], now: Date = .now) {
        var seen = Set<String>()
        for vehicle in vehicles where vehicle.mode == .dart {
            seen.insert(vehicle.id)
            let previous = tracks[vehicle.id]
            let atStation = vehicle.rail?.atStation ?? false
            // Irish Rail repeats the same station for minutes; only a change is news.
            if let previous, previous.rawLatitude == vehicle.latitude, previous.rawLongitude == vehicle.longitude,
               previous.atStation == atStation { continue }

            let towardsHowth = (vehicle.headsign ?? vehicle.routeDescription ?? "").localizedCaseInsensitiveContains("Howth")
            guard let (shape, distance) = network.locate(latitude: vehicle.latitude, longitude: vehicle.longitude,
                                                         towardsHowth: towardsHowth) else {
                tracks[vehicle.id] = nil
                continue
            }

            var direction = previous?.direction ?? 1
            if let southbound = vehicle.rail?.southbound {
                direction = network.southSign(shape: shape, at: distance) * (southbound ? 1 : -1)
            } else if let previous, previous.shape == shape, abs(distance - previous.anchor) > 20 {
                direction = distance > previous.anchor ? 1 : -1
            }

            var track = Track(
                shape: shape, direction: direction, anchor: distance, anchorTime: now,
                target: atStation ? nil : network.nextStation(shape: shape, after: distance, direction: direction)?.distance,
                rawLatitude: vehicle.latitude, rawLongitude: vehicle.longitude, atStation: atStation
            )
            if let previous, previous.shape == shape, previous.direction == direction, let shown = previous.shown {
                track.shown = shown
                let fresh = rawDistance(track, at: now)
                let behind = (shown - fresh) * direction
                if behind > Self.holdThreshold || behind < -1 {
                    track.easeFrom = (shown, now)
                }
            }
            tracks[vehicle.id] = track
        }
        for id in tracks.keys where !seen.contains(id) {
            tracks[id] = nil
        }
    }

    func placement(for vehicleId: String, at time: Date = .now) -> Placement? {
        guard var track = tracks[vehicleId] else { return nil }
        var distance = rawDistance(track, at: time)
        if let ease = track.easeFrom {
            let progress = time.timeIntervalSince(ease.at) / Self.easeDuration
            if progress < 1 {
                // Smoothstep, so corrections start and finish gently.
                let t = max(progress, 0), s = t * t * (3 - 2 * t)
                distance = ease.distance + (distance - ease.distance) * s
            } else {
                track.easeFrom = nil
            }
        } else if let shown = track.shown, (shown - distance) * track.direction > 0,
                  (shown - distance) * track.direction <= Self.holdThreshold {
            distance = shown
        }
        track.shown = distance
        tracks[vehicleId] = track
        return Placement(shape: track.shape, distance: distance, direction: track.direction)
    }

    private func rawDistance(_ track: Track, at time: Date) -> Double {
        guard let target = track.target else { return track.anchor }
        let travelled = Self.travelled(over: abs(target - track.anchor), after: time.timeIntervalSince(track.anchorTime))
        return track.anchor + track.direction * travelled
    }

    /// Distance covered `t` seconds into a run of `length` metres that starts and
    /// ends at rest: accelerate, cruise, brake.
    nonisolated static func travelled(over length: Double, after t: TimeInterval) -> Double {
        guard t > 0, length > 0 else { return 0 }
        let a = acceleration
        let peak = min(cruiseSpeed, sqrt(a * length))
        let rampTime = peak / a, rampDistance = peak * peak / (2 * a)
        let cruiseTime = (length - 2 * rampDistance) / peak
        let total = 2 * rampTime + cruiseTime
        if t >= total { return length }
        if t < rampTime { return 0.5 * a * t * t }
        if t < rampTime + cruiseTime { return rampDistance + peak * (t - rampTime) }
        let left = total - t
        return length - 0.5 * a * left * left
    }

    /// How long that run takes.
    nonisolated static func runTime(over length: Double) -> TimeInterval {
        let peak = min(cruiseSpeed, sqrt(acceleration * length))
        let rampDistance = peak * peak / (2 * acceleration)
        return 2 * peak / acceleration + (length - 2 * rampDistance) / peak
    }
}
