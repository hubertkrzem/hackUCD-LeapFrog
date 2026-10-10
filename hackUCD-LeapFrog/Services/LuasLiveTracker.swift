import Foundation

/// Tracks Luas trams from the RPA's real-time stop forecasts.
///
/// NTA's Luas TripUpdates proved too unstable to place trams (in a recording, a
/// third of updates moved the same trip by over 2 minutes, some by 15+), so trams
/// come from the Luas forecasting API instead. A few "observer" stops spread along
/// each line are polled; each lists every tram approaching it within ~40 min with
/// its destination and minutes due. A tram due at observer S in m minutes is m
/// minutes of timetable away from S, which places it on its route's timetable.
/// The reading from the observer a tram is nearest to wins (the most precise),
/// and trams are matched to the previous update in order, as trams can't
/// overtake. `RailTracker` then moves each tram smoothly along its timetable.
final class LuasLiveTracker {
    nonisolated struct Observation: Sendable {
        let stopCode: String
        let fetchedAt: Date
        let arrivals: [Arrival]
    }

    /// Every `observerSpacing`th stop along each line is polled.
    static let observerSpacing = 5
    /// Readings older than this are ignored.
    static let maxReadingAge: TimeInterval = 90
    /// Readings of the same tram from different observers land within this of each other.
    static let sameTram: TimeInterval = 150
    /// A tram keeps its identity across updates if it moved less than this.
    static let matchWindow: TimeInterval = 240
    /// Trams no observer has reported for this long are dropped.
    static let lostAfter: TimeInterval = 300

    /// The longest timetable pattern ending at a destination, used for every tram
    /// heading there (shorter workings run on the same track).
    private struct Route {
        let pattern: LuasSchedule.Pattern
        let offsets: [String: TimeInterval]
        var duration: TimeInterval { TimeInterval(pattern.offsets.last ?? 0) }
    }

    private struct Tram {
        let id: String
        let destination: String
        /// When the tram is (or was) at its route's first stop, on timetable pace.
        var anchor: Date
        /// The anchor when first seen: the tram's own "timetable".
        let firstAnchor: Date
        var lastSeen: Date
    }

    let observerCodes: [String]
    private let data: StaticData
    private let routes: [String: Route]
    private var trams: [Tram] = []
    private var counter = 0
    private(set) var lastUpdate: Date?

    init(data: StaticData) {
        self.data = data
        var routes: [String: Route] = [:]
        for pattern in data.luas.patterns {
            guard let last = pattern.stopIds.last, let destination = data.stopsById[last]?.name else { continue }
            if let existing = routes[destination], existing.pattern.stopIds.count >= pattern.stopIds.count { continue }
            var offsets: [String: TimeInterval] = [:]
            for (stopId, offset) in zip(pattern.stopIds, pattern.offsets) {
                if let code = data.stopsById[stopId]?.luasCode, offsets[code] == nil { offsets[code] = TimeInterval(offset) }
            }
            routes[destination] = Route(pattern: pattern, offsets: offsets)
        }
        self.routes = routes

        // Observers: every few stops along each line's longest pattern. Trams on a
        // branch end (e.g. Tallaght) are seen from the trunk on their way in or out.
        var longest: [String: LuasSchedule.Pattern] = [:]
        for pattern in data.luas.patterns where pattern.stopIds.count > (longest[pattern.routeId]?.stopIds.count ?? 0) {
            longest[pattern.routeId] = pattern
        }
        var codes: [String] = []
        for pattern in longest.values.sorted(by: { $0.routeId < $1.routeId }) {
            let lineCodes = pattern.stopIds.compactMap { data.stopsById[$0]?.luasCode }
            for (index, code) in lineCodes.enumerated() where index % Self.observerSpacing == Self.observerSpacing / 2 {
                if !codes.contains(code) { codes.append(code) }
            }
        }
        observerCodes = codes
    }

    var isLive: Bool { lastUpdate.map { Date.now.timeIntervalSince($0) < 120 } ?? false }

    func update(_ observations: [Observation], now: Date = .now) {
        guard !observations.isEmpty else { return }
        lastUpdate = now
        for (destination, route) in routes {
            // Each reading as an anchor time, merged per tram, keeping the reading
            // from the observer the tram is closest to.
            var readings: [(ahead: TimeInterval, anchor: Date)] = []
            for observation in observations where now.timeIntervalSince(observation.fetchedAt) <= Self.maxReadingAge {
                guard let offset = route.offsets[observation.stopCode] else { continue }
                for arrival in observation.arrivals where arrival.destination == destination {
                    guard let due = arrival.dueMinutes else { continue }
                    // "DUE" is under a minute; "n" minutes is n to n+1.
                    let ahead = due == 0 ? 15 : TimeInterval(due * 60 + 30)
                    readings.append((ahead, observation.fetchedAt.addingTimeInterval(ahead - offset)))
                }
            }
            readings.sort { $0.anchor < $1.anchor }
            var merged: [(ahead: TimeInterval, anchor: Date)] = []
            for reading in readings {
                if let last = merged.last, reading.anchor.timeIntervalSince(last.anchor) < Self.sameTram {
                    if reading.ahead < last.ahead { merged[merged.count - 1] = reading }
                } else {
                    merged.append(reading)
                }
            }

            // Match to the trams already known, in order.
            var known = trams.indices.filter { trams[$0].destination == destination }
            for reading in merged {
                if let best = known.min(by: { abs(trams[$0].anchor.timeIntervalSince(reading.anchor)) < abs(trams[$1].anchor.timeIntervalSince(reading.anchor)) }),
                   abs(trams[best].anchor.timeIntervalSince(reading.anchor)) < Self.matchWindow {
                    trams[best].anchor = reading.anchor
                    trams[best].lastSeen = now
                    // Keep order: trams before this one can't match later readings.
                    known.removeAll { trams[$0].anchor <= trams[best].anchor }
                } else {
                    counter += 1
                    trams.append(Tram(id: "luas-live-\(counter)", destination: destination,
                                      anchor: reading.anchor, firstAnchor: reading.anchor, lastSeen: now))
                }
            }
        }
        // Drop trams that have finished their run, or that no observer reports any more.
        trams.removeAll { tram in
            guard let route = routes[tram.destination] else { return true }
            return tram.anchor.addingTimeInterval(route.duration + 60) < now
                || now.timeIntervalSince(tram.lastSeen) > Self.lostAfter
        }
    }

    /// Trams running now (or about to leave their first stop), with their positions.
    func vehicles(now: Date = .now) -> [Vehicle] {
        trams.compactMap { tram in
            guard tram.anchor <= now.addingTimeInterval(90), let route = routes[tram.destination] else { return nil }
            let pattern = route.pattern
            let times = times(for: tram, on: pattern)
            let clamped = min(max(now, times.first ?? now), times.last ?? now)
            guard let position = LuasEstimator.position(at: clamped, times: times, stopIds: pattern.stopIds, data: data)
            else { return nil }
            let info = data.routes[pattern.routeId]
            return Vehicle(
                id: tram.id, mode: .luas, latitude: position.latitude, longitude: position.longitude,
                routeName: info?.shortName ?? "Luas", routeDescription: info?.longName, operatorName: info?.operatorName,
                headsign: tram.destination, bearing: position.bearing, timestamp: tram.lastSeen,
                source: .luasForecast, tripId: tram.id, routeId: pattern.routeId
            )
        }
    }

    /// Each tram's journey for `RailTracker`: its own timetable (pace from GTFS,
    /// anchored when first seen) and the live prediction from the latest forecasts.
    func calls() -> [String: [RailCall]] {
        var result: [String: [RailCall]] = [:]
        for tram in trams {
            guard let pattern = routes[tram.destination]?.pattern else { continue }
            let scheduled = pattern.offsets.map { tram.firstAnchor.addingTimeInterval(TimeInterval($0)) }
            result[tram.id] = LuasEstimator.calls(stopIds: pattern.stopIds, times: times(for: tram, on: pattern),
                                                  scheduled: scheduled, data: data)
        }
        return result
    }

    private func times(for tram: Tram, on pattern: LuasSchedule.Pattern) -> [Date] {
        pattern.offsets.map { tram.anchor.addingTimeInterval(TimeInterval($0)) }
    }
}
