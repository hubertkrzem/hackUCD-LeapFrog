import MapKit
import UIKit

/// A DART or Luas placed on its track. The map glides `distance` between the 1 s
/// tracker ticks; the view lays the carriages out behind it every frame.
final class TrainAnnotation: NSObject, MKAnnotation {
    var vehicle: Vehicle
    @objc dynamic var coordinate: CLLocationCoordinate2D
    private(set) var placement: RailTracker.Placement
    private var from: Double
    private var startedAt: CFTimeInterval = 0
    /// Distance shown this frame.
    private(set) var distance: Double

    init(vehicle: Vehicle, placement: RailTracker.Placement, coordinate: CLLocationCoordinate2D) {
        self.vehicle = vehicle
        self.placement = placement
        self.coordinate = coordinate
        from = placement.distance
        distance = placement.distance
    }

    /// Heads for a new placement over the next tick, starting from wherever it is now.
    func retarget(_ new: RailTracker.Placement, now: CFTimeInterval) {
        // A new path is measured differently; the tracker already made the switch seamless.
        if new.pathKey != placement.pathKey {
            from = new.distance
            distance = new.distance
        } else {
            from = distance
        }
        placement = new
        startedAt = now
    }

    /// Advances the glide; returns false once it has settled.
    func step(now: CFTimeInterval, duration: CFTimeInterval) -> Bool {
        let t = min(max((now - startedAt) / duration, 0), 1)
        distance = from + (placement.distance - from) * t
        return t < 1
    }
}

/// The map's projection for one frame, shared by every train. With pitch off the
/// flat map is an exact scale + rotation + shift of MapKit's map points, so two
/// `convert` calls per frame replace hundreds.
struct TrainFrame: Equatable {
    let originX: Double
    let originY: Double
    let originScreen: CGPoint
    /// Screen points per map point, as a complex number (scale and rotation).
    let a: Double
    let b: Double
    let cameraHeading: Double
    let metresPerPoint: Double

    init(mapView: MKMapView) {
        let rect = mapView.visibleMapRect
        let origin = MKMapPoint(x: rect.midX, y: rect.midY)
        originX = origin.x
        originY = origin.y
        let probe = MKMapPoint(x: origin.x + 1_000, y: origin.y)
        originScreen = mapView.convert(origin.coordinate, toPointTo: mapView)
        let probeScreen = mapView.convert(probe.coordinate, toPointTo: mapView)
        a = Double(probeScreen.x - originScreen.x) / 1_000
        b = Double(probeScreen.y - originScreen.y) / 1_000
        cameraHeading = mapView.camera.heading
        metresPerPoint = MKMetersPerMapPointAtLatitude(origin.coordinate.latitude) / max(hypot(a, b), 1e-9)
    }

    func screen(latitude: Double, longitude: Double) -> CGPoint {
        let p = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let dx = p.x - originX, dy = p.y - originY
        return CGPoint(x: originScreen.x + CGFloat(a * dx - b * dy), y: originScreen.y + CGFloat(b * dx + a * dy))
    }
}

/// The cars of a train or tram, front to back.
struct Consist {
    /// Each car's sprite, and whether it faces backwards.
    let cars: [(model: SpriteModel, reversed: Bool)]
    let realCarLength: Double
    /// Screen length of a car, after zoom scaling.
    let carRange: ClosedRange<CGFloat>
    /// Sprite canvas, big enough for the longest car at any angle.
    let spriteSide: CGFloat

    /// Three two-car DART units; the cars in each unit face apart, so cabs meet at the couplings.
    static let dart = Consist(cars: (0..<6).map { (.dartCar, $0 % 2 == 1) }, realCarLength: 20,
                              carRange: 11...26, spriteSide: 34)
    /// A three-section articulated Luas: cab, middle, cab facing back.
    static let luas = Consist(cars: [(.luasCab, false), (.luasMiddle, false), (.luasCab, true)], realCarLength: 14.5,
                              carRange: 9...20, spriteSide: 30)

    static func `for`(_ mode: TransportMode) -> Consist { mode == .luas ? .luas : .dart }

    /// How much longer than life cars are drawn, so they read at city zoom.
    static let exaggeration: CGFloat = 2.5

    func carPoints(metresPerPoint: Double) -> CGFloat {
        min(max(CGFloat(realCarLength / metresPerPoint) * Self.exaggeration, carRange.lowerBound), carRange.upperBound)
    }

    /// Share of the sprite canvas a car spans when it lies across the screen.
    var spriteFraction: CGFloat {
        let model = cars[0].model
        return CGFloat(model.carLength / (2 * model.orthographicScale))
    }
}

/// A DART (six carriages) or Luas (three articulated sections) laid along its
/// track as chords between the couplings, so it bends through curves and stays
/// coupled.
///
/// Each car is a cached sprite on a plain layer: a frame costs a few track
/// lookups and layer moves per train, never a 3D render.
final class TrainView: MKAnnotationView {
    static let reuseID = "Train"
    static let maxCars = 6
    static let couplingGap: CGFloat = 0.5

    private static let elevation = 50 * Double.pi / 180
    private var consist = Consist.dart
    private let carriages: [CALayer]
    private let caption = UILabel()
    /// What the carriages were last laid out for, to skip frames where nothing moved.
    private var laidOutFor: (distance: Double, frame: TrainFrame)?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        carriages = (0..<Self.maxCars).map { _ in
            let layer = CALayer()
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            // Moved every frame: implicit animations would only lag behind.
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                             "contents": NSNull(), "zPosition": NSNull()]
            return layer
        }
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        collisionMode = .none
        displayPriority = .required
        zPriority = .max
        carriages.forEach { layer.addSublayer($0) }

        caption.font = .systemFont(ofSize: 10, weight: .heavy)
        caption.textAlignment = .center
        caption.backgroundColor = .white
        caption.textColor = Theme.greenUI
        caption.layer.cornerRadius = 7
        caption.layer.masksToBounds = true
        caption.layer.zPosition = 10_000
        caption.isHidden = true
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        laidOutFor = nil
    }

    func configure(with vehicle: Vehicle, eta: String?) {
        zPriority = .max
        let consist = Consist.for(vehicle.mode)
        if caption.text != eta || consist.cars.count != self.consist.cars.count || consist.cars[0].model != self.consist.cars[0].model {
            laidOutFor = nil
        }
        self.consist = consist
        for (k, layer) in carriages.enumerated() { layer.isHidden = k >= consist.cars.count }
        caption.isHidden = eta == nil
        caption.text = eta
        accessibilityLabel = "\(vehicle.mode.title)\(vehicle.headsign.map { " to \($0)" } ?? "")"
    }

    /// Taps anywhere on a car select the train.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        carriages.contains { !$0.isHidden && $0.frame.insetBy(dx: $0.frame.width * 0.15, dy: $0.frame.height * 0.15).contains(point) }
    }

    /// Places every car for the vehicle's current distance along `shape` (its
    /// journey's path, so it always runs towards increasing distance).
    /// Returns false if nothing needed to move.
    @discardableResult
    func layout(distance: Double, shape: RouteShape, frame: TrainFrame) -> Bool {
        guard let annotation else { return false }
        if let last = laidOutFor, last.distance == distance, last.frame == frame { return false }
        laidOutFor = (distance, frame)
        let anchor = frame.screen(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude)
        let cameraHeading = frame.cameraHeading
        let metresPerPoint = frame.metresPerPoint
        let carriagePt = consist.carPoints(metresPerPoint: metresPerPoint)
        let count = consist.cars.count

        // Couplings, front to back. A carriage's on-screen length depends on its angle
        // (the sprite camera looks down at 50°), so each step is sized to the track there.
        func step(at d: Double) -> Double {
            let screenAngle = (shape.point(at: d).bearing - cameraHeading) * .pi / 180
            return Double(carriagePt * Self.footprint(screenAngle: screenAngle) + Self.couplingGap) * metresPerPoint
        }
        // Centred on `distance`: the middle coupling, or the middle of the middle car.
        var couplings = [Double](repeating: distance, count: count + 1)
        let half = count / 2
        if count % 2 == 1 {
            let middle = step(at: distance) / 2
            couplings[half] = distance + middle
            couplings[half + 1] = distance - middle
        }
        for k in stride(from: half - 1, through: 0, by: -1) {
            couplings[k] = couplings[k + 1] + step(at: couplings[k + 1])
        }
        for k in (count % 2 == 1 ? half + 2 : half + 1)...count {
            couplings[k] = couplings[k - 1] - step(at: couplings[k - 1])
        }
        // Keep the whole train on the track at the ends of its path.
        let shift = max(couplings[0] - shape.length, 0) + min(couplings[count], 0)
        let points = couplings.map { d -> CGPoint in
            let p = shape.point(at: d - shift)
            let screen = frame.screen(latitude: p.latitude, longitude: p.longitude)
            return CGPoint(x: screen.x - anchor.x, y: screen.y - anchor.y)
        }

        let side = carriagePt / consist.spriteFraction
        let lift = VehicleSpriteRenderer.groundOffset(side: side, model: consist.cars[0].model)
        // MapKit hit-tests the view's frame, so grow it (centred on the anchor) to cover the train.
        let extent = points.reduce(0) { max($0, abs($1.x), abs($1.y)) } + side
        let size = (extent * 2 / 16).rounded(.up) * 16
        if bounds.width != size {
            bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let local = points.map { CGPoint(x: $0.x + centre.x, y: $0.y + centre.y) }
        for (k, car) in consist.cars.enumerated() {
            let layer = carriages[k]
            let front = local[k], back = local[k + 1]
            let mid = CGPoint(x: (front.x + back.x) / 2, y: (front.y + back.y) / 2)
            // Screen angle of the chord, clockwise from up; reversed cars face the other way.
            var chord = atan2(Double(front.x - back.x), Double(back.y - front.y))
            if car.reversed { chord += .pi }
            let yaw = atan2(sin(Self.elevation) * sin(chord), cos(chord))
            let bucket = VehicleSpriteRenderer.bucket(for: yaw * 180 / .pi)
            layer.contents = TrainSpriteCache.image(car.model, bucket: bucket, side: consist.spriteSide)?.cgImage
            // Turn the nearest pre-rendered angle the last few degrees onto the chord.
            let bucketYaw = Double(bucket) * VehicleSpriteRenderer.bucketDegrees * .pi / 180
            let bucketChord = atan2(sin(bucketYaw), cos(bucketYaw) * sin(Self.elevation))
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.position = CGPoint(x: mid.x, y: mid.y - lift)
            layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(remainder(chord - bucketChord, 2 * .pi))))
            // Nearer the bottom of the screen is nearer the camera.
            layer.zPosition = mid.y
        }

        caption.isHidden = caption.text == nil
        if !caption.isHidden {
            let width = caption.intrinsicContentSize.width + 10
            caption.frame = CGRect(x: local[0].x - width / 2, y: local[0].y - lift - side / 2 - 14, width: width, height: 14)
        }
        return true
    }

    /// On-screen length of a unit-length carriage lying at `screenAngle`, as the
    /// 50° sprite camera foreshortens anything pointing up the screen.
    static func footprint(screenAngle: Double) -> CGFloat {
        let yaw = atan2(sin(elevation) * sin(screenAngle), cos(screenAngle))
        return CGFloat(hypot(sin(yaw), cos(yaw) * sin(elevation)))
    }
}

/// Each car model at every heading bucket. Rear-facing cars reuse the sprite
/// turned 180°, so the whole fleet needs 24 renders per car model.
enum TrainSpriteCache {
    private struct Key: Hashable {
        let model: SpriteModel
        let bucket: Int
    }

    private static var images: [Key: UIImage] = [:]

    static func image(_ model: SpriteModel, bucket: Int, side: CGFloat) -> UIImage? {
        let key = Key(model: model, bucket: bucket)
        if let cached = images[key] { return cached }
        let image = VehicleSpriteRenderer.image(model: model, bucket: bucket, side: side)
        images[key] = image
        return image
    }
}
