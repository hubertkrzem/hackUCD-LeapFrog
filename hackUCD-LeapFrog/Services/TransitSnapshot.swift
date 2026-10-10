import Foundation

/// A short plain-text summary of live conditions for the travel assistant.
///
/// Uses data the app already has (NTA trip updates for buses) plus two feeds
/// that need no API key: Irish Rail for DART lateness and the Luas forecast
/// API for each line's status message. Nothing here calls the NTA API, so
/// opening the chat doesn't eat into its rate limit.
nonisolated enum TransitSnapshot {
    /// Central stops whose forecast carries each line's status message.
    static let luasStatusStops = [("Green", "STS"), ("Red", "BUS")]
    static let lateThreshold = 5 * 60
    static let busLateThreshold = 10 * 60

    @concurrent
    static func build(tripUpdates: GTFSRFeed?, routes: [String: RouteInfo], busesReporting: Int,
                      now: Date = .now) async -> String {
        async let trains = try? IrishRailClient().currentDARTs()
        async let green = try? LuasClient().forecast(stopCode: luasStatusStops[0].1)
        async let red = try? LuasClient().forecast(stopCode: luasStatusStops[1].1)
        let (dart, greenForecast, redForecast) = await (trains, green, red)

        var lines = [header(now)]
        for (name, forecast) in [(luasStatusStops[0].0, greenForecast), (luasStatusStops[1].0, redForecast)] {
            if let message = forecast?.message, !message.isEmpty {
                lines.append("Luas \(name) line: \"\(message)\"")
            } else {
                lines.append("Luas \(name) line: status unavailable")
            }
        }
        lines.append(dartSummary(dart))
        lines.append(busSummary(tripUpdates, routes: routes, busesReporting: busesReporting))
        return lines.joined(separator: "\n")
    }

    static func header(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .dublin
        formatter.locale = Locale(identifier: "en_IE")
        formatter.dateFormat = "HH:mm, EEEE d MMMM"
        return "Snapshot at \(formatter.string(from: now)) (Dublin time)."
    }

    static func dartSummary(_ trains: [IrishRailClient.Train]?) -> String {
        guard let trains else { return "DART: live status unavailable." }
        let running = trains.filter(\.isRunning)
        let late = running.compactMap { train -> (IrishRailClient.Train, Int)? in
            guard let minutes = minutesLate(train.message), minutes * 60 >= lateThreshold else { return nil }
            return (train, minutes)
        }
        .sorted { $0.1 > $1.1 }
        guard !late.isEmpty else { return "DART: \(running.count) trains running, none 5+ min late." }
        let detail = late.prefix(4).map { "\($0.0.code) \($0.0.journey ?? "") (\($0.1) min late)" }
        return "DART: \(running.count) trains running; \(late.count) running 5+ min late: " + detail.joined(separator: "; ") + "."
    }

    /// "(7 mins late)" from an Irish Rail public message; nil if absent.
    static func minutesLate(_ message: String) -> Int? {
        guard let match = message.firstMatch(of: try! Regex(#"\((-?\d+) mins? late\)"#, as: (Substring, Substring).self))
        else { return nil }
        return Int(match.1)
    }

    /// Bus Éireann runs city services elsewhere (route 213 is in Cork), so it's
    /// reported apart from Dublin's city network to keep the assistant from mixing them up.
    static func busSummary(_ feed: GTFSRFeed?, routes: [String: RouteInfo], busesReporting: Int) -> String {
        guard let feed else {
            return busesReporting > 0
                ? "Buses: \(busesReporting) buses reporting; no live delay data yet."
                : "Buses: live bus data unavailable."
        }
        struct Tally { var cancelled: [String: Int] = [:], late: [String: Int] = [:] }
        var dublin = Tally(), busEireann = Tally()
        for entity in feed.entity ?? [] {
            guard let update = entity.tripUpdate, let trip = update.trip,
                  let routeId = trip.routeId, let route = routes[routeId], route.mode == .bus
            else { continue }
            let isBusEireann = route.operatorName.localizedCaseInsensitiveContains("Éireann")
            if trip.isCanceled {
                isBusEireann ? (busEireann.cancelled[route.shortName, default: 0] += 1)
                             : (dublin.cancelled[route.shortName, default: 0] += 1)
            } else if let delay = (update.stopTimeUpdate ?? []).compactMap({ ($0.arrival ?? $0.departure)?.delay?.value }).first,
                      delay >= busLateThreshold {
                isBusEireann ? (busEireann.late[route.shortName, default: 0] += 1)
                             : (dublin.late[route.shortName, default: 0] += 1)
            }
        }
        func top(_ counts: [String: Int]) -> String {
            counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6)
                .map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        }
        func describe(_ tally: Tally) -> String {
            let cancelled = tally.cancelled.values.reduce(0, +), late = tally.late.values.reduce(0, +)
            return [
                cancelled == 0 ? "no cancelled trips" : "\(cancelled) trips cancelled (routes: \(top(tally.cancelled)))",
                late == 0 ? "no trips 10+ min late" : "\(late) trips running 10+ min late (routes: \(top(tally.late)))",
            ].joined(separator: "; ")
        }
        return """
        Buses (NTA live feed, \(busesReporting) buses reporting):
        - Dublin city buses (Dublin Bus, Go-Ahead Ireland): \(describe(dublin)).
        - Bus Éireann (nationwide, including other cities): \(describe(busEireann)).
        """
    }
}
