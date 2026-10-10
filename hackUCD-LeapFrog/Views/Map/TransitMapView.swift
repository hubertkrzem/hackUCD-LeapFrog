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

        private var linesLoaded = false
        private var railStops: [String: StopAnnotation] = [:]
        private var busStops: [String: StopAnnotation] = [:]
        private var vehicles: [String: VehicleAnnotation] = [:]
        private var watched: WatchedStopAnnotation?

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
            let latestById = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

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
                if let view = mapView.view(for: annotation) as? VehicleMarkerView {
                    configure(view, for: vehicle, parent: parent)
                }
                if old != vehicle.coordinate {
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
            view.configure(with: vehicle, eta: parent.etas[vehicle.id].map { Self.etaText($0) })
        }

        static func etaText(_ date: Date) -> String {
            let minutes = Int(date.timeIntervalSinceNow / 60)
            return minutes <= 0 ? "Due" : "\(minutes) min"
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
            renderer.lineWidth = polyline.mode == .dart ? 4 : 3.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            defer { mapView.deselectAnnotation(annotation, animated: false) }
            switch annotation {
            case let vehicle as VehicleAnnotation:
                parent?.onSelect(.vehicle(vehicle.vehicle))
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

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        coordinate = vehicle.coordinate
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
