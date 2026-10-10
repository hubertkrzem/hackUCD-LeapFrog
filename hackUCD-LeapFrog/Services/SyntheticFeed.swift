#if DEBUG
import Foundation

/// Fake moving buses for load-testing the map without an API key.
/// Enable with the launch argument `-syntheticBuses 1500`.
nonisolated struct SyntheticFeed: Sendable {
    let count: Int
    private var buses: [Vehicle] = []

    static var requestedCount: Int { UserDefaults.standard.integer(forKey: "syntheticBuses") }

    init(count: Int) {
        self.count = count
    }

    /// Advances every bus ~150 m in a slowly wandering direction.
    mutating func tick(data: StaticData, now: Date = .now) -> [Vehicle] {
        if buses.isEmpty {
            let busRoutes = data.routes.filter { $0.value.mode == .bus }.map { ($0.key, $0.value) }
            guard !busRoutes.isEmpty else { return [] }
            var generator = SystemRandomNumberGenerator()
            buses = (0..<count).map { index in
                let (routeId, route) = busRoutes[index % busRoutes.count]
                return makeBus(
                    id: "synthetic-\(index)", routeId: routeId, route: route,
                    latitude: 53.35 + Double.random(in: -0.12...0.12, using: &generator),
                    longitude: -6.26 + Double.random(in: -0.2...0.2, using: &generator),
                    bearing: Double.random(in: 0..<360, using: &generator), now: now
                )
            }
            return buses
        }
        buses = buses.map { bus in
            let bearing = ((bus.bearing ?? 0) + Double.random(in: -25...25)).truncatingRemainder(dividingBy: 360)
            let radians = bearing * .pi / 180
            let route = RouteInfo(shortName: bus.routeName, longName: bus.routeDescription ?? "",
                                  mode: .bus, operatorName: bus.operatorName ?? "")
            return makeBus(
                id: bus.id, routeId: bus.routeId ?? "", route: route,
                latitude: bus.latitude + cos(radians) * 0.0013,
                longitude: bus.longitude + sin(radians) * 0.0022,
                bearing: bearing < 0 ? bearing + 360 : bearing, now: now
            )
        }
        return buses
    }

    private func makeBus(id: String, routeId: String, route: RouteInfo, latitude: Double, longitude: Double,
                         bearing: Double, now: Date) -> Vehicle {
        Vehicle(
            id: id, mode: .bus, latitude: latitude, longitude: longitude,
            routeName: route.shortName, routeDescription: route.longName, operatorName: route.operatorName,
            headsign: nil, bearing: bearing, timestamp: now, source: .nta, tripId: nil,
            routeId: routeId, directionId: 0
        )
    }
}
#endif
