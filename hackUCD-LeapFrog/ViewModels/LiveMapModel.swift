import CoreLocation
import Foundation
import Observation

@Observable
final class LiveMapModel {
    enum Status: Equatable {
        case loading
        case live
        case degraded(String)
        case failed(String)
    }

    enum Selection: Identifiable, Hashable {
        case stop(Stop)
        case vehicle(Vehicle)

        var id: String {
            switch self {
            case .stop(let stop): "stop-\(stop.id)"
            case .vehicle(let vehicle): "vehicle-\(vehicle.id)"
            }
        }
    }

    /// A one-shot request for the map to move; the id makes repeated requests distinct.
    struct CameraRequest: Equatable {
        enum Target: Equatable {
            case coordinate(latitude: Double, longitude: Double, span: Double)
            case userLocation
        }

        let id = UUID()
        let target: Target
    }

    /// How often the loop wakes. The NTA Vehicles feed updates about this often.
    /// Each feed is fetched as soon as it's due; these are the gaps after a success.
    /// Bus positions are fetched as often as the API lets us.
    static let vehiclesInterval: TimeInterval = 20
    /// The NTA API allows TripUpdates about once a minute per key.
    static let tripUpdatesInterval: TimeInterval = 65
    static let irishRailInterval: TimeInterval = 30
    /// Retry gap after a network error, or a 429 that didn't say how long to wait.
    static let errorRetry: TimeInterval = 10

    private(set) var data: StaticData = .empty
    /// Every vehicle from the latest refresh, before filtering.
    private(set) var vehicles: [Vehicle] = []
    /// What the map should draw: all Luas and DART plus nearby buses, or the watched stop's vehicles.
    private(set) var displayedVehicles: [Vehicle] = []
    /// Bumped whenever `displayedVehicles` changes, so the map can skip redundant syncs.
    private(set) var displayVersion = 0
    private(set) var vehicleCounts: [TransportMode: Int] = [:]
    /// Predicted arrival at the watched stop, by vehicle id.
    private(set) var watchETAs: [String: Date] = [:]
    private(set) var tripUpdates: GTFSRFeed?
    private(set) var status: Status = .loading
    private(set) var lastUpdated: Date?
    /// Where each tracked bus is estimated to be right now, refreshed every second.
    private(set) var estimatedPositions: [String: BusTracker.Estimate] = [:]
    private(set) var positionsVersion = 0
    @ObservationIgnored private var tracker: BusTracker?
    /// Where each Luas and DART is on its track, refreshed alongside `estimatedPositions`.
    private(set) var trainPlacements: [String: RailTracker.Placement] = [:]
    /// The track each placement's distance is measured along.
    private(set) var railPaths: [String: RouteShape] = [:]
    @ObservationIgnored private var railTracker: RailTracker?
    /// Each DART's journey timeline from Irish Rail movements, by vehicle id.
    @ObservationIgnored private var dartJourneys: [String: (calls: [RailCall], fetchedAt: Date, status: String)] = [:]
    @ObservationIgnored private var railStations: [String: (latitude: Double, longitude: Double)]?
    /// Movements are refetched when a train's status changes, and at least this often.
    static let movementsInterval: TimeInterval = 60
    var enabledModes: Set<TransportMode> = Set(TransportMode.allCases) {
        didSet { recomputeDisplayed() }
    }
    var selection: Selection?
    var cameraRequest: CameraRequest?

    /// Not persisted: a forgotten watch from a previous session would silently hide buses.
    private(set) var watchedStopId: String? {
        didSet { recomputeDisplayed() }
    }

    let hasAPIKey: Bool
    private let nta: NTAClient
    private let irishRail = IrishRailClient()
    let luas = LuasClient()
    private let location = LocationProvider()
    /// Map centre, used for the bus range until the user's location is known.
    private var mapCenter: CLLocationCoordinate2D?
    /// The last successful Vehicles response, reused if a later call fails.
    private var lastVehicleFeed: GTFSRFeed?
    private var lastVehicleSuccess: Date?
    private var lastRailTrains: [IrishRailClient.Train]?
    /// When each feed may next be fetched.
    private var nextVehiclesAt: Date = .distantPast
    private var nextTripUpdatesAt: Date = .distantPast
    private var nextIrishRailAt: Date = .distantPast
    private var filterGeneration = 0
    #if DEBUG
    private var synthetic: SyntheticFeed? = SyntheticFeed.isRequested
        ? SyntheticFeed(count: SyntheticFeed.requestedCount, trains: SyntheticFeed.requestedTrains,
                        trams: SyntheticFeed.requestedTrams) : nil
    #endif

    init(apiKey: String? = Secrets.ntaAPIKey) {
        nta = NTAClient(apiKey: apiKey)
        hasAPIKey = apiKey != nil
        location.onSignificantChange = { [weak self] in self?.recomputeDisplayed() }
    }

    var selectedVehicleId: String? {
        if case .vehicle(let vehicle) = selection { vehicle.id } else { nil }
    }

    var watchedStop: Stop? {
        watchedStopId.flatMap { data.stopsById[$0] }
    }

    /// Where the 5 km bus range is measured from: the user, else the map centre.
    var busCenter: CLLocationCoordinate2D? {
        location.coordinate ?? mapCenter
    }

    var isUsingUserLocation: Bool { location.coordinate != nil }

    func vehicleCount(for mode: TransportMode) -> Int {
        vehicleCounts[mode] ?? 0
    }

    func toggle(_ mode: TransportMode) {
        if enabledModes.contains(mode) {
            enabledModes.remove(mode)
        } else {
            enabledModes.insert(mode)
        }
    }

    func watch(_ stop: Stop?) {
        watchedStopId = stop?.id
    }

    /// Called by the map when the user stops panning. Only matters while the
    /// user's own location is unknown.
    func mapCenterChanged(_ center: CLLocationCoordinate2D) {
        mapCenter = center
        if location.coordinate == nil { recomputeDisplayed() }
    }

    /// Re-applies filters off the main actor; stale results from older calls are dropped.
    func recomputeDisplayed() {
        filterGeneration += 1
        let generation = filterGeneration
        let criteria = VehicleFilter.Criteria(modes: enabledModes, busCenter: busCenter, watchedStopId: watchedStopId)
        let (vehicles, data, tripUpdates) = (vehicles, data, tripUpdates)
        Task {
            let result = await Self.filter(vehicles, criteria: criteria, data: data, tripUpdates: tripUpdates)
            guard generation == filterGeneration else { return }
            displayedVehicles = result.vehicles
            vehicleCounts = result.counts
            watchETAs = result.etas
            displayVersion += 1
        }
    }

    @concurrent
    private static func filter(_ vehicles: [Vehicle], criteria: VehicleFilter.Criteria, data: StaticData,
                               tripUpdates: GTFSRFeed?) async -> VehicleFilter.Result {
        VehicleFilter.apply(vehicles, criteria: criteria, data: data, tripUpdates: tripUpdates)
    }

    @concurrent
    private static func merge(ntaVehicles: GTFSRFeed?, tripUpdates: GTFSRFeed?,
                              irishRail: [IrishRailClient.Train]?, data: StaticData) async -> [Vehicle] {
        VehicleMerger.merge(ntaVehicles: ntaVehicles, tripUpdates: tripUpdates, irishRail: irishRail, data: data)
    }

    /// Snaps buses to their routes and moves each to its estimated position now.
    private func trackBuses(_ merged: [Vehicle]) -> [Vehicle] {
        if let railTracker {
            var calls = LuasEstimator.calls(tripUpdates: tripUpdates?.entity?.compactMap(\.tripUpdate) ?? [], data: data)
            var fetchedAt: [String: Date] = [:]
            for (id, journey) in dartJourneys {
                calls[id] = journey.calls
                fetchedAt[id] = journey.fetchedAt
            }
            #if DEBUG
            if let synthetic {
                for (id, journey) in synthetic.railCalls { calls[id] = journey }
            }
            #endif
            railTracker.ingest(merged, calls: calls, fetchedAt: fetchedAt)
        }
        guard let tracker else { return merged }
        tracker.ingest(merged.filter { $0.source == .nta })
        #if DEBUG
        if !tracker.accuracy.estimateErrors.isEmpty { print("[BusTracker]", tracker.accuracy.summary) }
        #endif
        return merged.map { vehicle in
            tracker.estimate(for: vehicle.id).map { vehicle.moved(to: $0) } ?? vehicle
        }
    }

    /// Advances every tracked bus on screen along its route, once a second.
    private func runEstimates() async {
        while !Task.isCancelled {
            if tracker != nil || railTracker != nil {
                var positions: [String: BusTracker.Estimate] = [:]
                var placements: [String: RailTracker.Placement] = [:]
                for vehicle in displayedVehicles {
                    if vehicle.mode == .bus {
                        positions[vehicle.id] = tracker?.estimate(for: vehicle.id)
                    } else {
                        placements[vehicle.id] = railTracker?.placement(for: vehicle.id)
                    }
                }
                if let shapes = railTracker?.pathShapes, shapes.count != railPaths.count { railPaths = shapes }
                estimatedPositions = positions
                trainPlacements = placements
                positionsVersion += 1
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func isRouteEstimated(_ vehicleId: String) -> Bool {
        tracker?.isTracked(vehicleId) ?? false
    }

    /// The selected bus's route, to draw on the map.
    var selectedRoute: (id: String, coordinates: [CLLocationCoordinate2D])? {
        guard case .vehicle(let vehicle) = selection, let shape = tracker?.shape(for: vehicle.id) else { return nil }
        return (vehicle.id, shape.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
    }

    private func setVehicles(_ merged: [Vehicle]) {
        vehicles = merged
        lastUpdated = .now
        recomputeDisplayed()
    }

    /// Loads bundled data, then polls the live feeds until the task is cancelled.
    func run() async {
        location.start()
        if data.stops.isEmpty {
            do {
                data = try await StaticData.loadFromBundle()
            } catch {
                status = .failed("Couldn't load stop data")
                return
            }
        }
        if tracker == nil, let store = try? await BusRouteStore.loadFromBundle() {
            tracker = BusTracker(store: store)
        }
        if railTracker == nil {
            railTracker = RailTracker(data: data)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pollFeeds() }
            group.addTask { await self.runEstimates() }
        }
    }

    private func pollFeeds() async {
        while !Task.isCancelled {
            #if DEBUG
            if var feed = synthetic, let store = tracker?.store, let rail = railTracker?.network {
                let fake = feed.tick(data: data, routes: store, rail: rail)
                synthetic = feed
                setVehicles(trackBuses(fake))
                status = .live
                try? await Task.sleep(for: .seconds(SyntheticFeed.pingInterval))
                continue
            }
            #endif
            await refresh()
            // Wake when the next feed is due (still at least every 30s, so Luas estimates keep moving).
            let nextDue = min(nextVehiclesAt, nextTripUpdatesAt, nextIrishRailAt).timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(min(max(nextDue, 1), 30)))
        }
    }

    /// Fetches whichever feeds are due, then redraws from the latest good data of each.
    func refresh(now: Date = .now) async {
        let fetchVehicles = now >= nextVehiclesAt
        let fetchTrips = now >= nextTripUpdatesAt
        let fetchRail = now >= nextIrishRailAt

        async let vehicleResult: Result<GTFSRFeed, Error>? = fetchVehicles ? Result.catching { try await nta.vehicles() } : nil
        async let tripResult: Result<GTFSRFeed, Error>? = fetchTrips ? Result.catching { try await nta.tripUpdates() } : nil
        async let railResult: Result<[IrishRailClient.Train], Error>? = fetchRail ? Result.catching { try await irishRail.currentDARTs() } : nil
        let (vehicleFeed, tripFeed, rail) = await (vehicleResult, tripResult, railResult)

        if let vehicleFeed {
            if case .success(let feed) = vehicleFeed {
                lastVehicleFeed = feed
                lastVehicleSuccess = now
            }
            nextVehiclesAt = Self.nextAttempt(after: vehicleFeed, interval: Self.vehiclesInterval, now: now)
        }
        if let tripFeed {
            if case .success(let feed) = tripFeed { tripUpdates = feed }
            nextTripUpdatesAt = Self.nextAttempt(after: tripFeed, interval: Self.tripUpdatesInterval, now: now)
        }
        if let rail {
            if case .success(let trains) = rail {
                lastRailTrains = trains
                await refreshJourneys(for: trains, now: now)
            }
            nextIrishRailAt = Self.nextAttempt(after: rail, interval: Self.irishRailInterval, now: now)
        }

        // Always merge from the last good data of each feed, so one failed call never
        // empties the map. Positions older than VehicleMerger.maxAge are still dropped.
        let merged = await Self.merge(
            ntaVehicles: lastVehicleFeed,
            tripUpdates: tripUpdates,
            irishRail: lastRailTrains,
            data: data
        )
        if !merged.isEmpty || lastVehicleFeed != nil {
            setVehicles(trackBuses(merged))
        }
        updateStatus(vehicleError: vehicleFeed?.failure, railError: rail?.failure, now: now)
    }

    /// Fetches the movements of every running DART whose status changed since its
    /// last fetch (it arrived or departed somewhere), or whose timeline is getting old.
    private func refreshJourneys(for trains: [IrishRailClient.Train], now: Date) async {
        if railStations == nil { railStations = try? await irishRail.stations() }
        guard let stations = railStations else { return }
        let running = trains.filter(\.isRunning)
        let due = running.filter { train in
            guard let journey = dartJourneys["ir-\(train.code)"] else { return true }
            return journey.status != train.message || now.timeIntervalSince(journey.fetchedAt) > Self.movementsInterval
        }
        let client = irishRail
        let fetched = await withTaskGroup(of: (IrishRailClient.Train, [IrishRailClient.Movement]?).self) { group in
            for train in due {
                group.addTask { (train, try? await client.movements(for: train)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (train, movements) in fetched {
            guard let movements else { continue }
            let calls = IrishRailClient.Movement.calls(movements, stations: stations)
            dartJourneys["ir-\(train.code)"] = calls.count >= 2 ? (calls, now, train.message) : nil
        }
        let live = Set(running.map { "ir-\($0.code)" })
        dartJourneys = dartJourneys.filter { live.contains($0.key) }
    }

    /// Success → the normal interval; 429 → exactly when the API says; other errors → retry soon.
    static func nextAttempt<T>(after result: Result<T, Error>, interval: TimeInterval, now: Date) -> Date {
        switch result {
        case .success:
            return now.addingTimeInterval(interval)
        case .failure(TransitAPIError.rateLimited(let retryAfter)):
            return now.addingTimeInterval((retryAfter ?? errorRetry) + 1)
        case .failure:
            return now.addingTimeInterval(errorRetry)
        }
    }

    private func updateStatus(vehicleError: Error?, railError: Error?, now: Date) {
        let busesFresh = lastVehicleSuccess.map { now.timeIntervalSince($0) < 90 } ?? false
        if busesFresh || !hasAPIKey {
            if !hasAPIKey {
                status = .degraded(TransitAPIError.missingAPIKey.localizedDescription)
            } else if railError != nil && lastRailTrains == nil {
                status = .degraded("Irish Rail feed unavailable")
            } else {
                status = .live
            }
        } else if let vehicleError {
            status = vehicles.isEmpty ? .failed(vehicleError.localizedDescription) : .degraded(vehicleError.localizedDescription)
        } else {
            status = .degraded("Bus positions are delayed")
        }
    }

    func arrivals(for stop: Stop) -> [Arrival] {
        VehicleMerger.arrivals(at: data.siblingStopIds(of: stop), tripUpdates: tripUpdates, data: data)
    }

    func focus(on stop: Stop) {
        cameraRequest = CameraRequest(target: .coordinate(latitude: stop.latitude, longitude: stop.longitude, span: 0.008))
        selection = .stop(stop)
    }

    func showUserLocation() {
        location.start()
        cameraRequest = CameraRequest(target: .userLocation)
    }

    func showDublin() {
        cameraRequest = CameraRequest(target: .coordinate(latitude: 53.3438, longitude: -6.2546, span: 0.14))
    }
}

extension Result where Failure == Error {
    static func catching(_ body: () async throws -> Success) async -> Result {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }

    var failure: Error? {
        if case .failure(let error) = self { error } else { nil }
    }
}
