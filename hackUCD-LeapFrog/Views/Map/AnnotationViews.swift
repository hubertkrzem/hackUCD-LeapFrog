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

/// A live vehicle: a coloured disc with the route number and a heading arrow.
/// The disc is a cached bitmap, so each marker is one image plus the arrow.
final class VehicleMarkerView: MKAnnotationView {
    static let reuseID = "Vehicle"
    static let diameter: CGFloat = 28
    static let canvas: CGFloat = 40

    private let arrow = CAShapeLayer()
    private let caption = UILabel()
    private var imageKey: String?
    private var appliedBearing: Double?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.canvas, height: Self.canvas)
        collisionMode = .circle
        displayPriority = .required
        zPriority = .max

        arrow.frame = bounds
        let mid = bounds.midX
        let path = UIBezierPath()
        path.move(to: CGPoint(x: mid, y: 0))
        path.addLine(to: CGPoint(x: mid + 6, y: 8))
        path.addLine(to: CGPoint(x: mid - 6, y: 8))
        path.close()
        arrow.path = path.cgPath
        arrow.actions = ["transform": NSNull()]
        layer.addSublayer(arrow)

        caption.font = .systemFont(ofSize: 10, weight: .heavy)
        caption.textAlignment = .center
        caption.backgroundColor = .white
        caption.layer.cornerRadius = 7
        caption.layer.masksToBounds = true
        caption.isHidden = true
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        appliedBearing = nil
    }

    func configure(with vehicle: Vehicle, eta: String?) {
        let key = MarkerImageCache.key(for: vehicle)
        if key != imageKey {
            imageKey = key
            image = MarkerImageCache.image(for: vehicle, key: key)
            arrow.fillColor = vehicle.mode.tintUI.cgColor
        }

        if let bearing = vehicle.bearing {
            arrow.isHidden = false
            if bearing != appliedBearing {
                appliedBearing = bearing
                arrow.setAffineTransform(CGAffineTransform(rotationAngle: bearing * .pi / 180))
            }
        } else {
            arrow.isHidden = true
        }

        caption.isHidden = eta == nil
        if let eta {
            caption.text = eta
            caption.textColor = Theme.greenUI
            let width = caption.intrinsicContentSize.width + 10
            caption.frame = CGRect(x: (Self.canvas - width) / 2, y: Self.canvas - 4, width: width, height: 14)
        }
        accessibilityLabel = "\(vehicle.mode.title) \(vehicle.routeName)\(vehicle.headsign.map { " to \($0)" } ?? "")"
    }
}

/// Pre-rendered vehicle discs keyed by mode, route label and style.
enum MarkerImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func key(for vehicle: Vehicle) -> String {
        "\(vehicle.mode.rawValue)|\(vehicle.mode == .bus ? vehicle.routeName : "")|\(vehicle.isEstimated)"
    }

    static func image(for vehicle: Vehicle, key: String) -> UIImage {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let image = render(vehicle)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func render(_ vehicle: Vehicle) -> UIImage {
        let canvas = VehicleMarkerView.canvas, d = VehicleMarkerView.diameter
        let tint = vehicle.mode.tintUI
        let disc = CGRect(x: (canvas - d) / 2, y: (canvas - d) / 2, width: d, height: d)
        return UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas)).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: disc).fill()
            cg.restoreGState()

            (vehicle.isEstimated ? tint.withAlphaComponent(0.75) : tint).setFill()
            UIBezierPath(ovalIn: disc.insetBy(dx: 2, dy: 2)).fill()

            if vehicle.mode == .bus {
                let name = vehicle.routeName
                // Shrink long route names (e.g. "41X", "120A") to fit the disc.
                var fontSize: CGFloat = 11
                var attributes: [NSAttributedString.Key: Any] = [:]
                var size = CGSize.zero
                repeat {
                    attributes = [.font: UIFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: UIColor.white]
                    size = (name as NSString).size(withAttributes: attributes)
                    fontSize -= 0.5
                } while size.width > d - 5 && fontSize >= 7
                size.width = min(size.width, d - 4)
                (name as NSString).draw(
                    with: CGRect(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2, width: size.width, height: size.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil
                )
            } else if let symbol = UIImage(systemName: vehicle.mode.symbol,
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)) {
                let icon = symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
                icon.draw(at: CGPoint(x: disc.midX - icon.size.width / 2, y: disc.midY - icon.size.height / 2))
            }
        }
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
