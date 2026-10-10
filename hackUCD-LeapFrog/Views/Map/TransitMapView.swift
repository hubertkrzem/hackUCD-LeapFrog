import MapKit
import SwiftUI

/// MKMapView wrapper. SwiftUI's `Map` can't cluster or comfortably handle
/// ~10k stop annotations, so stops, vehicles and lines are managed here.
struct TransitMapView: UIViewRepresentable {
    let data: StaticData
    /// Already filtered by the model: all Luas/DART plus at most 150 nearby buses.
    let vehicles: [Vehicle]
    let vehiclesVersion: Int
    let enabledModes: Set<TransportMode>
    let watchedStop: Stop?
    let etas: [String: Date]
    let selectedVehicleId: String?
    /// Route-based live estimates for buses, refreshed every second.
    let estimatedPositions: [String: BusTracker.Estimate]
    let positionsVersion: Int
    /// Luas and DARTs placed on their track, refreshed with the bus estimates.
    let trainPlacements: [String: RailTracker.Placement]
    /// The path each placement is measured along, by key.
    let railPaths: [String: RouteShape]
    /// The selected bus's route, drawn while its sheet is open.
    let selectedRoute: (id: String, coordinates: [CLLocationCoordinate2D])?
    let cameraRequest: LiveMapModel.CameraRequest?
    let onSelect: (LiveMapModel.Selection) -> Void
    /// Reports the map centre when the user stops panning.
    let onRegionChange: (CLLocationCoordinate2D) -> Void

    /// Bus stops and full bus markers only appear below this latitude span (roughly a neighbourhood).
    static let busStopSpanThreshold = 0.035

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.isPitchEnabled = false
        mapView.register(StopDotView.self, forAnnotationViewWithReuseIdentifier: StopDotView.reuseID)
        mapView.register(StopClusterView.self, forAnnotationViewWithReuseIdentifier: StopClusterView.reuseID)
        mapView.register(VehicleMarkerView.self, forAnnotationViewWithReuseIdentifier: VehicleMarkerView.reuseID)
        mapView.register(TrainView.self, forAnnotationViewWithReuseIdentifier: TrainView.reuseID)
        mapView.register(WatchedStopView.self, forAnnotationViewWithReuseIdentifier: WatchedStopView.reuseID)
        var span = 0.14
        #if DEBUG
        // e.g. `-initialSpan 0.02` to start zoomed in when testing.
        if UserDefaults.standard.double(forKey: "initialSpan") > 0 { span = UserDefaults.standard.double(forKey: "initialSpan") }
        #endif
        mapView.setRegion(
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 53.3438, longitude: -6.2546),
                               span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)),
            animated: false
        )
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.syncLines(data.lines)

        let stopsKey = Coordinator.StopsKey(stopCount: data.stops.count, modes: enabledModes)
        if stopsKey != coordinator.lastStopsKey {
            coordinator.lastStopsKey = stopsKey
            coordinator.syncStops()
        }
        coordinator.syncWatchedStop(watchedStop)

        // SwiftUI calls this for any observed change (status pill, sheets...);
        // only redo vehicle work when the vehicles themselves changed.
        let vehiclesKey = Coordinator.VehiclesKey(version: vehiclesVersion, selectedId: selectedVehicleId)
        if vehiclesKey != coordinator.lastVehiclesKey {
            coordinator.lastVehiclesKey = vehiclesKey
            coordinator.syncVehicles()
        }

        if positionsVersion != coordinator.lastPositionsVersion {
            coordinator.lastPositionsVersion = positionsVersion
            coordinator.applyEstimates(estimatedPositions)
            coordinator.applyTrainPlacements(trainPlacements)
        }
        coordinator.syncSelectedRoute(selectedRoute)

        if let cameraRequest, cameraRequest != coordinator.lastCameraRequest {
            coordinator.lastCameraRequest = cameraRequest
            coordinator.apply(cameraRequest)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        struct StopsKey: Equatable {
            let stopCount: Int
            let modes: Set<TransportMode>
        }

        struct VehiclesKey: Equatable {
            let version: Int
            let selectedId: String?
        }

        var parent: TransitMapView?
        weak var mapView: MKMapView?
        var lastCameraRequest: LiveMapModel.CameraRequest?
        var lastStopsKey: StopsKey?
        var lastVehiclesKey: VehiclesKey?
        var lastPositionsVersion = -1
        private var routeOverlay: (id: String, polyline: ColoredPolyline)?

        private var linesLoaded = false
        private var railStops: [String: StopAnnotation] = [:]
        private var busStops: [String: StopAnnotation] = [:]
        private var vehicles: [String: VehicleAnnotation] = [:]
        private var trains: [String: TrainAnnotation] = [:]
        private var displayLink: CADisplayLink?
        private var trainFrameCount = 0
        #if DEBUG
        private var frameCost = (total: 0.0, worst: 0.0, frames: 0, laidOut: 0)
        #endif
        private var watched: WatchedStopAnnotation?
        /// Camera heading the vehicle sprites were last oriented for.
        private var spriteHeading: Double = 0

        // MARK: Sync

        func syncLines(_ lines: [LineShape]) {
            guard !linesLoaded, !lines.isEmpty, let mapView else { return }
            linesLoaded = true
            // DART first so the Luas lines draw on top where they cross.
            let ordered = lines.sorted { ($0.mode == .dart ? 0 : 1) < ($1.mode == .dart ? 0 : 1) }
            for line in ordered {
                var coordinates = line.coordinates
                let polyline = ColoredPolyline(coordinates: &coordinates, count: coordinates.count)
                polyline.color = Self.lineColor(for: line)
                polyline.mode = line.mode
                mapView.addOverlay(polyline, level: .aboveRoads)
            }
        }

        static func lineColor(for line: LineShape) -> UIColor {
            switch (line.mode, line.name.lowercased()) {
            case (.luas, "red"): Theme.luasRedUI
            case (.luas, _): Theme.luasGreenUI
            default: TransportMode.dart.tintUI
            }
        }

        func syncStops() {
            guard let mapView, let parent else { return }
            let modes = parent.enabledModes

            // Luas and DART: always on (when enabled), a few hundred at most.
            let wantedRail = parent.data.displayStops.filter { $0.mode != .bus && modes.contains($0.mode) }
            diff(wanted: wantedRail, current: &railStops, on: mapView)

            // Bus: only those in view once zoomed in, to keep annotation counts sane.
            var wantedBus: [Stop] = []
            let region = mapView.region
            if modes.contains(.bus), region.span.latitudeDelta < TransitMapView.busStopSpanThreshold {
                let latPad = region.span.latitudeDelta * 0.75, lonPad = region.span.longitudeDelta * 0.75
                let latRange = (region.center.latitude - latPad)...(region.center.latitude + latPad)
                let lonRange = (region.center.longitude - lonPad)...(region.center.longitude + lonPad)
                wantedBus = parent.data.displayStops.filter {
                    $0.mode == .bus && latRange.contains($0.latitude) && lonRange.contains($0.longitude)
                }
            }
            diff(wanted: wantedBus, current: &busStops, on: mapView)
        }

        private func diff(wanted: [Stop], current: inout [String: StopAnnotation], on mapView: MKMapView) {
            let wantedIds = Set(wanted.map(\.id))
            let removed = current.filter { !wantedIds.contains($0.key) }
            if !removed.isEmpty {
                mapView.removeAnnotations(Array(removed.values))
                removed.keys.forEach { current.removeValue(forKey: $0) }
            }
            let added = wanted.filter { current[$0.id] == nil }.map { StopAnnotation($0) }
            if !added.isEmpty {
                added.forEach { current[$0.stop.id] = $0 }
                mapView.addAnnotations(added)
            }
        }

        func syncWatchedStop(_ stop: Stop?) {
            guard let mapView, watched?.stop.id != stop?.id else { return }
            if let watched { mapView.removeAnnotation(watched) }
            watched = stop.map { WatchedStopAnnotation($0) }
            if let watched { mapView.addAnnotation(watched) }
        }

        func syncVehicles() {
            guard let mapView, let parent else { return }
            syncMarkers(parent.vehicles, on: mapView)
        }

        private func syncMarkers(_ latest: [Vehicle], on mapView: MKMapView) {
            guard let parent else { return }
            var latestById = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Trains on the track are drawn by TrainView instead.
            for (id, train) in trains {
                guard let vehicle = latestById.removeValue(forKey: id) else { continue }
                train.vehicle = vehicle
                (mapView.view(for: train) as? TrainView)?.configure(with: vehicle, eta: parent.etas[id].map { Self.etaText($0) })
            }

            let gone = vehicles.keys.filter { latestById[$0] == nil }
            if !gone.isEmpty {
                mapView.removeAnnotations(gone.compactMap { vehicles.removeValue(forKey: $0) })
            }

            let visible = mapView.visibleMapRect
            var added: [VehicleAnnotation] = []
            var moves: [(VehicleAnnotation, CLLocationCoordinate2D)] = []
            for (id, vehicle) in latestById {
                guard let annotation = vehicles[id] else {
                    let annotation = VehicleAnnotation(vehicle: vehicle)
                    vehicles[id] = annotation
                    added.append(annotation)
                    continue
                }
                let old = annotation.coordinate
                annotation.vehicle = vehicle
                annotation.updateHeading(from: old)
                if let view = mapView.view(for: annotation) as? VehicleMarkerView {
                    configure(view, for: vehicle, parent: parent)
                }
                // Route-tracked buses are moved by the 1 s estimate tick instead.
                if old != vehicle.coordinate && parent.estimatedPositions[id] == nil {
                    // Only on-screen movement is worth animating.
                    if visible.contains(MKMapPoint(old)) || visible.contains(MKMapPoint(vehicle.coordinate)) {
                        moves.append((annotation, vehicle.coordinate))
                    } else {
                        annotation.coordinate = vehicle.coordinate
                    }
                }
            }
            if !moves.isEmpty {
                UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    for (annotation, coordinate) in moves { annotation.coordinate = coordinate }
                }
            }
            if !added.isEmpty { mapView.addAnnotations(added) }
        }

        private func configure(_ view: VehicleMarkerView, for vehicle: Vehicle, parent: TransitMapView) {
            let heading = vehicles[vehicle.id]?.heading ?? vehicle.bearing
            view.configure(with: vehicle, eta: parent.etas[vehicle.id].map { Self.etaText($0) },
                           heading: heading.map { $0 - (mapView?.camera.heading ?? 0) })
        }

        static func etaText(_ date: Date) -> String {
            let minutes = Int(date.timeIntervalSinceNow / 60)
            return minutes <= 0 ? "Due" : "\(minutes) min"
        }

        /// Glides each tracked bus to its latest estimate and turns its 3D model to
        /// face along the road. Steps are ~1 s of travel (5–15 m), so straight-line
        /// animation stays on the road.
        func applyEstimates(_ estimates: [String: BusTracker.Estimate]) {
            guard let mapView, let parent else { return }
            let visible = mapView.visibleMapRect
            var moves: [(VehicleAnnotation, CLLocationCoordinate2D)] = []
            for (id, estimate) in estimates {
                guard let annotation = vehicles[id] else { continue }
                let coordinate = CLLocationCoordinate2D(latitude: estimate.latitude, longitude: estimate.longitude)
                guard coordinate != annotation.coordinate else { continue }
                annotation.followRoute(bearing: estimate.bearing)
                if let view = mapView.view(for: annotation) as? VehicleMarkerView {
                    configure(view, for: annotation.vehicle, parent: parent)
                }
                if visible.contains(MKMapPoint(coordinate)) || visible.contains(MKMapPoint(annotation.coordinate)) {
                    moves.append((annotation, coordinate))
                } else {
                    annotation.coordinate = coordinate
                }
            }
            guard !moves.isEmpty else { return }
            UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                for (annotation, coordinate) in moves { annotation.coordinate = coordinate }
            }
        }

        /// Swaps tracked Luas and DARTs from plain markers to coupled trains and sets each
        /// gliding towards its latest placement over the next second.
        func applyTrainPlacements(_ placements: [String: RailTracker.Placement]) {
            guard let mapView, let parent else { return }
            let now = CACurrentMediaTime()
            let gone = trains.keys.filter { placements[$0] == nil }
            if !gone.isEmpty {
                mapView.removeAnnotations(gone.compactMap { trains.removeValue(forKey: $0) })
            }
            var added: [TrainAnnotation] = []
            for (id, placement) in placements {
                guard let path = parent.railPaths[placement.pathKey] else { continue }
                if let train = trains[id] {
                    train.retarget(placement, now: now)
                    continue
                }
                guard let vehicle = vehicles[id]?.vehicle ?? parent.vehicles.first(where: { $0.id == id }) else { continue }
                if let marker = vehicles.removeValue(forKey: id) { mapView.removeAnnotation(marker) }
                let point = path.point(at: placement.distance)
                let train = TrainAnnotation(vehicle: vehicle, placement: placement,
                                            coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                trains[id] = train
                added.append(train)
            }
            if !added.isEmpty { mapView.addAnnotations(added) }

            if trains.isEmpty {
                displayLink?.invalidate()
                displayLink = nil
            } else if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(stepTrains))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        @objc private func stepTrains(_ link: CADisplayLink) {
            guard let mapView, let parent else { return }
            #if DEBUG
            let started = CACurrentMediaTime()
            var laidOut = 0
            #endif
            let now = CACurrentMediaTime()
            let frame = TrainFrame(mapView: mapView)
            trainFrameCount += 1
            // Off-screen trains only need to move often enough for MapKit to notice them arriving.
            let moveOffscreen = trainFrameCount % 10 == 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for train in trains.values {
                _ = train.step(now: now, duration: 1)
                let placement = train.placement
                guard let shape = parent.railPaths[placement.pathKey] else { continue }
                let point = shape.point(at: train.distance)
                let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                // MapKit only has views for trains on screen.
                let view = mapView.view(for: train) as? TrainView
                if coordinate != train.coordinate, view != nil || moveOffscreen { train.coordinate = coordinate }
                if let view, view.layout(distance: train.distance, shape: shape, frame: frame) {
                    #if DEBUG
                    laidOut += 1
                    #endif
                }
            }
            CATransaction.commit()
            #if DEBUG
            let cost = CACurrentMediaTime() - started
            frameCost = (frameCost.total + cost, max(frameCost.worst, cost), frameCost.frames + 1, max(frameCost.laidOut, laidOut))
            if frameCost.frames == 300 {
                NSLog(String(format: "[Trains] %d tracked, up to %d laid out · per frame: avg %.3f ms, worst %.3f ms",
                             trains.count, frameCost.laidOut, frameCost.total / 300 * 1000, frameCost.worst * 1000))
                frameCost = (0, 0, 0, 0)
            }
            #endif
        }

        func syncSelectedRoute(_ route: (id: String, coordinates: [CLLocationCoordinate2D])?) {
            guard let mapView, routeOverlay?.id != route?.id else { return }
            if let routeOverlay { mapView.removeOverlay(routeOverlay.polyline) }
            routeOverlay = nil
            guard let route, route.coordinates.count > 1 else { return }
            var coordinates = route.coordinates
            let polyline = ColoredPolyline(coordinates: &coordinates, count: coordinates.count)
            polyline.color = Theme.greenUI
            polyline.mode = .bus
            mapView.addOverlay(polyline, level: .aboveRoads)
            routeOverlay = (route.id, polyline)
        }

        func apply(_ request: LiveMapModel.CameraRequest) {
            guard let mapView else { return }
            switch request.target {
            case let .coordinate(latitude, longitude, span):
                let region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
                )
                mapView.setRegion(region, animated: true)
            case .userLocation:
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        }

        // MARK: MKMapViewDelegate

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Re-orient sprites once the map has rotated past half a heading bucket.
            let heading = mapView.camera.heading
            var delta = abs(heading - spriteHeading).truncatingRemainder(dividingBy: 360)
            delta = min(delta, 360 - delta)
            guard delta >= VehicleSpriteRenderer.bucketDegrees / 2, let parent else { return }
            spriteHeading = heading
            for annotation in vehicles.values {
                if let view = mapView.view(for: annotation) as? VehicleMarkerView {
                    configure(view, for: annotation.vehicle, parent: parent)
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            syncStops()
            parent?.onRegionChange(mapView.region.center)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let vehicle as VehicleAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: VehicleMarkerView.reuseID, for: vehicle)
                if let view = view as? VehicleMarkerView, let parent {
                    configure(view, for: vehicle.vehicle, parent: parent)
                }
                return view
            case let train as TrainAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: TrainView.reuseID, for: train)
                if let view = view as? TrainView, let parent, let shape = parent.railPaths[train.placement.pathKey] {
                    view.configure(with: train.vehicle, eta: parent.etas[train.vehicle.id].map { Self.etaText($0) })
                    view.layout(distance: train.distance, shape: shape, frame: TrainFrame(mapView: mapView))
                }
                return view
            case let watched as WatchedStopAnnotation:
                return mapView.dequeueReusableAnnotationView(withIdentifier: WatchedStopView.reuseID, for: watched)
            case let stop as StopAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: StopDotView.reuseID, for: stop)
                (view as? StopDotView)?.configure(with: stop.stop)
                return view
            case let cluster as MKClusterAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: StopClusterView.reuseID, for: cluster)
                (view as? StopClusterView)?.configure(with: cluster)
                return view
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? ColoredPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = polyline.color.withAlphaComponent(0.85)
            renderer.lineWidth = polyline.mode == .bus ? 5 : polyline.mode == .dart ? 4 : 3.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            defer { mapView.deselectAnnotation(annotation, animated: false) }
            switch annotation {
            case let vehicle as VehicleAnnotation:
                parent?.onSelect(.vehicle(vehicle.vehicle))
            case let train as TrainAnnotation:
                parent?.onSelect(.vehicle(train.vehicle))
            case let watched as WatchedStopAnnotation:
                parent?.onSelect(.stop(watched.stop))
            case let stop as StopAnnotation:
                parent?.onSelect(.stop(stop.stop))
            case let cluster as MKClusterAnnotation:
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            default:
                break
            }
        }
    }
}

// MARK: - Annotations

final class StopAnnotation: NSObject, MKAnnotation {
    let stop: Stop
    let coordinate: CLLocationCoordinate2D
    var title: String? { stop.name }

    init(_ stop: Stop) {
        self.stop = stop
        coordinate = stop.coordinate
    }
}

final class WatchedStopAnnotation: NSObject, MKAnnotation {
    let stop: Stop
    let coordinate: CLLocationCoordinate2D

    init(_ stop: Stop) {
        self.stop = stop
        coordinate = stop.coordinate
    }
}

final class VehicleAnnotation: NSObject, MKAnnotation {
    var vehicle: Vehicle
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from north. The NTA and Irish Rail feeds often omit
    /// bearing, so it falls back to the direction of the last real movement.
    private(set) var heading: Double?

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        coordinate = vehicle.coordinate
        heading = vehicle.bearing
    }

    /// Route-tracked buses face along the road at their estimated position.
    func followRoute(bearing: Double) {
        heading = bearing
    }

    func updateHeading(from old: CLLocationCoordinate2D) {
        if let bearing = vehicle.bearing {
            heading = bearing
            return
        }
        let new = vehicle.coordinate
        // Ignore GPS jitter while stopped.
        guard CLLocation(latitude: old.latitude, longitude: old.longitude)
            .distance(from: CLLocation(latitude: new.latitude, longitude: new.longitude)) > 15 else { return }
        heading = LuasEstimator.bearing(fromLat: old.latitude, fromLon: old.longitude,
                                        toLat: new.latitude, toLon: new.longitude)
    }
}

final class ColoredPolyline: MKPolyline {
    var color: UIColor = Theme.greenUI
    var mode: TransportMode = .dart
}

extension CLLocationCoordinate2D {
    static func != (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude != rhs.latitude || lhs.longitude != rhs.longitude
    }
}
