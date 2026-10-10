import MapKit
import UIKit

/// A small white-ringed dot for a stop. Clusters per mode when crowded.
final class StopDotView: MKAnnotationView {
    static let reuseID = "StopDot"

    private let dot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        addSubview(dot)
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.18
        dot.layer.shadowRadius = 1.5
        dot.layer.shadowOffset = CGSize(width: 0, height: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with stop: Stop) {
        let size: CGFloat = stop.mode == .bus ? 11 : 15
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.frame = bounds
        dot.layer.cornerRadius = size / 2
        // An explicit path spares Core Animation an offscreen pass per dot.
        dot.layer.shadowPath = UIBezierPath(ovalIn: dot.bounds).cgPath
        dot.layer.borderWidth = stop.mode == .bus ? 2 : 2.5
        // Rail stations read as white with a coloured ring; bus stops as solid dots.
        dot.backgroundColor = stop.mode == .bus ? stop.mode.tintUI : .white
        dot.layer.borderColor = stop.mode == .bus ? UIColor.white.cgColor : stop.mode.tintUI.cgColor
        clusteringIdentifier = "stops-\(stop.mode.rawValue)"
        displayPriority = stop.mode == .bus ? .defaultLow : .defaultHigh
        zPriority = .min
        accessibilityLabel = "\(stop.mode.title) stop, \(stop.name)"
    }
}

/// A rounded count badge for clustered stops, tinted by the stops' mode.
final class StopClusterView: MKAnnotationView {
    static let reuseID = "StopCluster"

    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
        layer.borderWidth = 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with cluster: MKClusterAnnotation) {
        let mode = (cluster.memberAnnotations.first as? StopAnnotation)?.stop.mode ?? .bus
        let count = cluster.memberAnnotations.count
        let size: CGFloat = count < 10 ? 24 : count < 100 ? 28 : 34
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        label.frame = bounds
        label.text = "\(count)"
        layer.cornerRadius = size / 2
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
        backgroundColor = .white
        layer.borderColor = mode.tintUI.cgColor
        label.textColor = mode.tintUI
        displayPriority = .defaultHigh
        zPriority = .min
    }
}

/// A live vehicle: a pre-rendered 3D model turned to its heading, with a route
/// badge above buses. Sprites are cached per mode and bearing bucket.
final class VehicleMarkerView: MKAnnotationView {
    static let reuseID = "Vehicle"
    static let canvas: CGFloat = 52

    private let badge = UILabel()
    private let caption = UILabel()
    private var imageKey: String?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.canvas, height: Self.canvas)
        collisionMode = .circle
        displayPriority = .required
        zPriority = .max
        // The sprite camera aims 1.5 m above the model's middle; lift the view so the
        // vehicle's ground point, not that aim point, sits on its map coordinate.
        centerOffset = CGPoint(x: 0, y: -VehicleSpriteRenderer.groundOffset(side: Self.canvas))

        for label in [badge, caption] {
            label.font = .systemFont(ofSize: 10, weight: .heavy)
            label.textAlignment = .center
            label.backgroundColor = .white
            label.layer.cornerRadius = 7
            label.layer.masksToBounds = true
            label.isHidden = true
            addSubview(label)
        }
        badge.textColor = Theme.greenUI
        badge.layer.borderColor = Theme.greenUI.cgColor
        badge.layer.borderWidth = 1
        caption.textColor = Theme.greenUI
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `heading` is relative to the screen (bearing minus camera heading), since
    /// annotation views don't rotate with the map. Unknown headings face up.
    func configure(with vehicle: Vehicle, eta: String?, heading: Double?) {
        let bucket = VehicleSpriteRenderer.bucket(for: heading ?? 0)
        let key = MarkerImageCache.key(for: vehicle, bucket: bucket)
        if key != imageKey {
            imageKey = key
            image = MarkerImageCache.image(for: vehicle, bucket: bucket, key: key)
        }

        badge.isHidden = vehicle.mode != .bus
        if vehicle.mode == .bus {
            badge.text = vehicle.routeName
            let width = max(badge.intrinsicContentSize.width + 10, 22)
            badge.frame = CGRect(x: (Self.canvas - width) / 2, y: -6, width: width, height: 14)
        }

        caption.isHidden = eta == nil
        if let eta {
            caption.text = eta
            let width = caption.intrinsicContentSize.width + 10
            caption.frame = CGRect(x: (Self.canvas - width) / 2, y: Self.canvas - 6, width: width, height: 14)
        }
        accessibilityLabel = "\(vehicle.mode.title) \(vehicle.routeName)\(vehicle.headsign.map { " to \($0)" } ?? "")"
    }
}

/// Pre-rendered vehicle sprites keyed by mode, heading bucket and style.
enum MarkerImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func key(for vehicle: Vehicle, bucket: Int) -> String {
        "\(vehicle.mode.rawValue)|\(bucket)|\(vehicle.isEstimated)"
    }

    static func image(for vehicle: Vehicle, bucket: Int, key: String) -> UIImage {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let image = VehicleSpriteRenderer.image(mode: vehicle.mode, bucket: bucket,
                                                estimated: vehicle.isEstimated, side: VehicleMarkerView.canvas)
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// The stop the user is watching: a larger pin with a pulsing halo.
final class WatchedStopView: MKAnnotationView {
    static let reuseID = "WatchedStop"

    private let halo = CALayer()
    private let core = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        displayPriority = .required
        zPriority = .max
        collisionMode = .none

        halo.frame = bounds
        halo.cornerRadius = 22
        halo.backgroundColor = Theme.brightGreenUI.withAlphaComponent(0.35).cgColor
        layer.addSublayer(halo)

        core.frame = bounds.insetBy(dx: 12, dy: 12)
        core.cornerRadius = 10
        core.backgroundColor = Theme.greenUI.cgColor
        core.borderColor = UIColor.white.cgColor
        core.borderWidth = 3
        core.shadowColor = UIColor.black.cgColor
        core.shadowOpacity = 0.25
        core.shadowRadius = 3
        core.shadowOffset = CGSize(width: 0, height: 1)
        core.shadowPath = UIBezierPath(ovalIn: core.bounds).cgPath
        layer.addSublayer(core)
        startPulse()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        startPulse()
    }

    private func startPulse() {
        guard halo.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(group, forKey: "pulse")
    }
}
