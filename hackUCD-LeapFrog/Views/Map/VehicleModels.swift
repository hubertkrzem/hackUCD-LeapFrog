import SceneKit
import UIKit

/// Low-poly SceneKit models of each vehicle in its livery.
/// Units are roughly metres; the front of every model faces -Z.
enum VehicleModelFactory {
    private static let busYellow = UIColor(hex: 0xFFC72C)
    private static let dartGreen = UIColor(hex: 0x4FAE32)
    private static let dartDarkGreen = UIColor(hex: 0x1E6B34)
    private static let dartStripe = UIColor(hex: 0xD8F0C8)
    private static let dartRoofGreen = UIColor(hex: 0x3C8F2A)
    private static let roofDark = UIColor(hex: 0x4A5157)
    private static let warningYellow = UIColor(hex: 0xFFD200)
    private static let luasGrey = UIColor(hex: 0xC6CBD0)
    private static let roofGrey = UIColor(hex: 0x9DA3A9)
    private static let glass = UIColor(hex: 0x1C2630)

    static func node(for model: SpriteModel) -> SCNNode {
        let node: SCNNode = switch model {
        case .vehicle(.bus): bus()
        case .vehicle(.dart): dart()
        case .vehicle(.luas): luas()
        case .dartCar: dartCar()
        case .luasCab: luasSection(cab: true)
        case .luasMiddle: luasSection(cab: false)
        }
        // Toy-like proportions: true widths read as slivers at map scale.
        let wrapper = SCNNode()
        node.scale = SCNVector3(1.5, 1.15, 1)
        wrapper.addChildNode(node)
        return wrapper
    }

    /// A Dublin double-decker: yellow body, green skirt and between-decks band.
    private static func bus() -> SCNNode {
        let root = SCNNode()
        let length: CGFloat = 13, width: CGFloat = 2.55, height: CGFloat = 4.3
        root.addChildNode(box(width, height - 0.4, length, chamfer: 0.35, color: busYellow, at: SCNVector3(0, 0.2 + Float(height) / 2, 0)))
        // Green "hints": lower skirt and a band between the decks.
        root.addChildNode(box(width + 0.04, 0.75, length - 0.2, chamfer: 0.1, color: Theme.greenUI, at: SCNVector3(0, 0.75, 0)))
        root.addChildNode(box(width + 0.04, 0.3, length - 0.3, chamfer: 0.05, color: Theme.greenUI, at: SCNVector3(0, 2.45, 0)))
        // Window bands on both decks, plus the windscreen at the front.
        root.addChildNode(box(width + 0.03, 0.9, length - 1.6, chamfer: 0.05, color: glass, at: SCNVector3(0, 1.8, 0.5)))
        root.addChildNode(box(width + 0.03, 0.95, length - 0.9, chamfer: 0.05, color: glass, at: SCNVector3(0, 3.3, 0.1)))
        root.addChildNode(box(width - 0.3, 2.6, 0.06, chamfer: 0, color: glass, at: SCNVector3(0, 2.6, -Float(length) / 2 - 0.02)))
        addWheels(to: root, width: width, axles: [-Float(length) / 2 + 2.3, Float(length) / 2 - 2.8])
        return root
    }

    /// DART carriage length; a train on the map is three two-car units of these.
    static let dartCarLength: Float = 12

    /// A DART (8100-style) carriage: green body with a dark green skirt and a pale
    /// stripe, a grey roof, a sloped yellow-nosed cab at the front (-Z) and a
    /// gangway at the back, so cars read as coupled when drawn end to end.
    private static func dartCar() -> SCNNode {
        let root = SCNNode()
        let length = CGFloat(dartCarLength), width: CGFloat = 2.9, height: CGFloat = 3.7
        let half = dartCarLength / 2
        root.addChildNode(box(width, height - 0.55, length - 0.9, chamfer: 0.3, color: dartGreen,
                              at: SCNVector3(0, 0.3 + Float(height - 0.55) / 2, 0.45)))
        root.addChildNode(box(width + 0.04, 0.7, length - 1.0, chamfer: 0.1, color: dartDarkGreen, at: SCNVector3(0, 0.75, 0.45)))
        root.addChildNode(box(width + 0.05, 0.12, length - 1.1, chamfer: 0, color: dartStripe, at: SCNVector3(0, 1.2, 0.45)))
        // Window band broken by body-coloured pillars.
        root.addChildNode(box(width + 0.03, 0.95, length - 2.6, chamfer: 0.05, color: glass, at: SCNVector3(0, 2.25, 0.5)))
        for z: Float in [-2.6, -0.3, 2.0, 4.3] {
            root.addChildNode(box(width + 0.06, 0.95, 0.3, chamfer: 0, color: dartGreen, at: SCNVector3(0, 2.25, z)))
        }
        // Seen from above the roof is most of the carriage, so it stays green to read as a DART.
        root.addChildNode(box(width - 0.35, 0.28, length - 1.6, chamfer: 0.12, color: dartRoofGreen, at: SCNVector3(0, Float(height) + 0.06, 0.5)))
        for z: Float in [-1.5, 2.5] {
            root.addChildNode(box(1.0, 0.22, 1.2, chamfer: 0.05, color: roofGrey, at: SCNVector3(0, Float(height) + 0.3, z)))
        }

        // Cab: a raked windscreen over a yellow nose with headlights.
        let cabZ = -half + 0.45
        root.addChildNode(box(width - 0.05, 1.5, 0.9, chamfer: 0.25, color: warningYellow, at: SCNVector3(0, 1.05, cabZ)))
        let screen = box(width - 0.25, 1.35, 0.5, chamfer: 0.12, color: glass, at: SCNVector3(0, 2.45, cabZ + 0.15))
        screen.eulerAngles.x = -0.35
        root.addChildNode(screen)
        root.addChildNode(box(width - 0.2, 0.5, 0.95, chamfer: 0.2, color: dartGreen, at: SCNVector3(0, Float(height) - 0.2, cabZ + 0.2)))
        for x: Float in [-0.95, 0.95] {
            root.addChildNode(box(0.4, 0.2, 0.08, chamfer: 0, color: .white, at: SCNVector3(x, 0.85, -half - 0.02)))
        }
        // Gangway bellows at the back.
        root.addChildNode(box(1.6, 2.5, 0.5, chamfer: 0.1, color: roofDark, at: SCNVector3(0, 1.8, half + 0.1)))
        addWheels(to: root, width: width, axles: [-half + 2.2, half - 2.2])
        return root
    }

    /// A two-car DART unit, for trains that can't be placed on the track.
    private static func dart() -> SCNNode {
        let root = SCNNode()
        let lead = dartCar(), trail = dartCar()
        lead.position.z = -dartCarLength / 2 - 0.2
        trail.position.z = dartCarLength / 2 + 0.2
        trail.eulerAngles.y = .pi
        root.addChildNode(lead)
        root.addChildNode(trail)
        // Shrink to roughly the other vehicles' footprint.
        root.scale = SCNVector3(0.75, 0.75, 0.75)
        let wrapper = SCNNode()
        wrapper.addChildNode(root)
        return wrapper
    }

    /// Luas section length; a tram on the map is cab + middle + cab.
    static let luasSectionLength: Float = 8

    /// One section of a Citadis-style Luas: silver-grey body, purple skirt, long
    /// windows. A cab section has a purple nose with a wraparound windscreen at
    /// the front (-Z); a middle section carries the pantograph. Dark bellows at
    /// the joints make sections read as one articulated tram.
    private static func luasSection(cab: Bool) -> SCNNode {
        let root = SCNNode()
        let length = CGFloat(luasSectionLength), width: CGFloat = 2.4, height: CGFloat = 3.3
        let half = luasSectionLength / 2
        let bodyLength = length - (cab ? 1.0 : 0.6), bodyZ: Float = cab ? 0.5 : 0
        root.addChildNode(box(width, height - 0.3, bodyLength, chamfer: 0.3, color: luasGrey,
                              at: SCNVector3(0, 0.15 + Float(height - 0.3) / 2 + 0.15, bodyZ)))
        root.addChildNode(box(width + 0.04, 0.55, bodyLength - 0.1, chamfer: 0.1, color: TransportMode.luas.tintUI, at: SCNVector3(0, 0.6, bodyZ)))
        root.addChildNode(box(width + 0.03, 1.15, bodyLength - 1.0, chamfer: 0.05, color: glass, at: SCNVector3(0, 1.95, bodyZ)))
        for z: Float in [bodyZ - 1.4, bodyZ + 1.4] {
            root.addChildNode(box(width + 0.06, 1.15, 0.22, chamfer: 0, color: luasGrey, at: SCNVector3(0, 1.95, z)))
        }
        root.addChildNode(box(width - 0.4, 0.15, bodyLength - 0.6, chamfer: 0.07, color: roofGrey, at: SCNVector3(0, Float(height) + 0.05, bodyZ)))
        if cab {
            let noseZ = -half + 0.5
            root.addChildNode(box(width - 0.05, 1.3, 1.0, chamfer: 0.35, color: TransportMode.luas.tintUI, at: SCNVector3(0, 0.95, noseZ)))
            let screen = box(width - 0.2, 1.4, 0.55, chamfer: 0.2, color: glass, at: SCNVector3(0, 2.25, noseZ + 0.1))
            screen.eulerAngles.x = -0.25
            root.addChildNode(screen)
            root.addChildNode(box(width - 0.15, 0.45, 1.0, chamfer: 0.2, color: TransportMode.luas.tintUI, at: SCNVector3(0, Float(height) - 0.15, noseZ + 0.15)))
            for x: Float in [-0.8, 0.8] {
                root.addChildNode(box(0.35, 0.18, 0.08, chamfer: 0, color: .white, at: SCNVector3(x, 0.8, -half - 0.02)))
            }
        } else {
            // Pantograph: a dark frame on the roof.
            root.addChildNode(box(1.3, 0.12, 0.5, chamfer: 0, color: glass, at: SCNVector3(0, Float(height) + 0.2, 0)))
            root.addChildNode(box(0.1, 0.5, 1.2, chamfer: 0, color: glass, at: SCNVector3(0, Float(height) + 0.45, 0)))
            root.addChildNode(box(1.6, 0.08, 0.15, chamfer: 0, color: glass, at: SCNVector3(0, Float(height) + 0.72, 0)))
            root.addChildNode(box(1.8, 2.4, 0.4, chamfer: 0.1, color: roofDark, at: SCNVector3(0, 1.7, -half - 0.05)))
        }
        root.addChildNode(box(1.8, 2.4, 0.4, chamfer: 0.1, color: roofDark, at: SCNVector3(0, 1.7, half + 0.05)))
        addWheels(to: root, width: width, axles: [0])
        return root
    }

    /// A three-section Luas tram, for trams that can't be placed on the track.
    private static func luas() -> SCNNode {
        let root = SCNNode()
        let sections = [luasSection(cab: true), luasSection(cab: false), luasSection(cab: true)]
        for (index, section) in sections.enumerated() {
            section.position.z = Float(index - 1) * (luasSectionLength + 0.15)
            if index == 2 { section.eulerAngles.y = .pi }
            root.addChildNode(section)
        }
        root.scale = SCNVector3(0.8, 0.8, 0.8)
        let wrapper = SCNNode()
        wrapper.addChildNode(root)
        return wrapper
    }

    private static func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat,
                            chamfer: CGFloat, color: UIColor, at position: SCNVector3) -> SCNNode {
        let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: chamfer)
        geometry.firstMaterial = material(color)
        let node = SCNNode(geometry: geometry)
        node.position = position
        return node
    }

    private static func addWheels(to root: SCNNode, width: CGFloat, axles: [Float]) {
        let wheel = SCNCylinder(radius: 0.5, height: 0.3)
        wheel.firstMaterial = material(glass)
        for z in axles {
            for side: Float in [-1, 1] {
                let node = SCNNode(geometry: wheel)
                node.position = SCNVector3(side * Float(width / 2 - 0.1), 0.5, z)
                node.eulerAngles.z = .pi / 2
                root.addChildNode(node)
            }
        }
    }

    private static func material(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.specular.contents = UIColor(white: 0.35, alpha: 1)
        material.shininess = 0.4
        return material
    }
}

/// Renders the vehicle models offscreen from a fixed oblique camera, so the map
/// gets 3D-looking sprites at the same cost as plain cached images.
@MainActor
enum VehicleSpriteRenderer {
    /// Bearings are snapped to this many degrees; one sprite per bucket.
    static let bucketDegrees = 15.0
    private static let camera = SCNCamera()
    private static let elevation = 50 * Double.pi / 180
    private static let aimHeight = 1.5

    private static let scene: SCNScene = {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // ~50° above the horizon, looking north, so "up" on screen is the vehicle's forward at bearing 0.
        let pitch = Float(Self.elevation)
        cameraNode.position = SCNVector3(0, 40 * sin(pitch), 40 * cos(pitch))
        cameraNode.look(at: SCNVector3(0, Float(aimHeight), 0))
        scene.rootNode.addChildNode(cameraNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 900
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowColor = UIColor.black.withAlphaComponent(0.3)
        sun.shadowRadius = 4
        sun.shadowSampleCount = 8
        sun.orthographicScale = 16
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = SCNVector3(-12, 30, 12)
        sunNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sunNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 550
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Invisible ground that only receives the model's shadow.
        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .shadowOnly
        floor.firstMaterial = floorMaterial
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        scene.rootNode.addChildNode(holder)
        return scene
    }()

    private static let holder = SCNNode()
    private static var models: [SpriteModel: SCNNode] = [:]
    private static let renderer: SCNRenderer = {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        return renderer
    }()

    /// Screen points between the sprite's centre and the vehicle's ground point
    /// (the camera aims `aimHeight` above the ground at `elevation`).
    static func groundOffset(side: CGFloat, model: SpriteModel = .vehicle(.bus)) -> CGFloat {
        let metresPerPoint = 2 * model.orthographicScale / Double(side)
        return CGFloat(aimHeight * cos(elevation) / metresPerPoint)
    }

    static func bucket(for bearing: Double) -> Int {
        let buckets = Int(360 / bucketDegrees)
        let normalised = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((normalised / bucketDegrees).rounded()) % buckets
    }

    static func image(mode: TransportMode, bucket: Int, estimated: Bool, side: CGFloat) -> UIImage {
        image(model: .vehicle(mode), bucket: bucket, estimated: estimated, side: side)
    }

    static func image(model key: SpriteModel, bucket: Int, estimated: Bool = false, side: CGFloat) -> UIImage {
        _ = scene
        camera.orthographicScale = key.orthographicScale
        holder.childNodes.forEach { $0.removeFromParentNode() }
        let model = models[key] ?? VehicleModelFactory.node(for: key)
        models[key] = model
        // Bearings run clockwise from north; SceneKit's Y rotation runs counter-clockwise.
        model.eulerAngles.y = -Float(Double(bucket) * bucketDegrees * .pi / 180)
        model.opacity = estimated ? 0.75 : 1
        holder.addChildNode(model)

        let scale = UIScreen.main.scale
        let pixels = CGSize(width: side * scale, height: side * scale)
        let snapshot = renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
        guard let cgImage = snapshot.cgImage else { return snapshot }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

/// What a sprite shows: a whole vehicle, or one carriage/section of a train or tram.
enum SpriteModel: Hashable {
    case vehicle(TransportMode)
    case dartCar
    case luasCab
    case luasMiddle

    /// Half the height of the camera's view, in model units.
    var orthographicScale: Double {
        switch self {
        case .vehicle: 10
        // Tight on one carriage, with room for it at any angle.
        case .dartCar: 7.5
        case .luasCab, .luasMiddle: 5.5
        }
    }

    /// Length of one carriage or section along the track, in model units.
    var carLength: Double {
        switch self {
        case .vehicle: 0
        case .dartCar: Double(VehicleModelFactory.dartCarLength)
        case .luasCab, .luasMiddle: Double(VehicleModelFactory.luasSectionLength)
        }
    }
}
