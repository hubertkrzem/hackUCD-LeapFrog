import Foundation

/// One bus route variant (a GTFS shape): its road geometry, cumulative
/// distance, and a timing profile (seconds after trip start at each stop).
nonisolated struct RouteShape: Sendable {
    let latitudes: [Double]
    let longitudes: [Double]
    /// Metres from the start of the route to each point.
    let cumulative: [Double]
    /// Timing profile: metres along the route → scheduled seconds after the trip starts.
    let profileDistances: [Double]
    let profileOffsets: [Double]

    var length: Double { cumulative.last ?? 0 }
    var hasProfile: Bool { profileDistances.count >= 2 }

    /// Average scheduled pace over the whole trip, in m/s.
    var scheduledSpeed: Double? {
        guard hasProfile, let t = profileOffsets.last, t > 0 else { return nil }
        return (profileDistances.last! - profileDistances.first!) / t
    }

    init(latitudes: [Double], longitudes: [Double], profileDistances: [Double], profileOffsets: [Double]) {
        self.latitudes = latitudes
        self.longitudes = longitudes
        self.profileDistances = profileDistances
        self.profileOffsets = profileOffsets
        var cumulative = [0.0]
        cumulative.reserveCapacity(latitudes.count)
        for i in latitudes.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + Geo.distance(latitudes[i - 1], longitudes[i - 1], latitudes[i], longitudes[i]))
        }
        self.cumulative = cumulative
    }

    /// Snaps a coordinate to the route. With a `hint` (the last known distance)
    /// only nearby road is searched, so loops and overlapping stretches don't
    /// pull a bus back to the wrong pass.
    func project(latitude: Double, longitude: Double, near hint: Double? = nil) -> (distance: Double, offRoute: Double)? {
        guard latitudes.count > 1 else { return nil }
        let lastSegment = latitudes.count - 2
        if let hint {
            let lower = segmentIndex(at: hint - 300), upper = segmentIndex(at: hint + 2_000)
            let windowed = nearest(latitude, longitude, segments: lower...upper)
            if windowed.offRoute <= 150 { return windowed }
        }
        return nearest(latitude, longitude, segments: 0...lastSegment)
    }

    private func nearest(_ lat: Double, _ lon: Double, segments: ClosedRange<Int>) -> (distance: Double, offRoute: Double) {
        var best = (distance: 0.0, offRoute: Double.infinity)
        let k = cos(lat * .pi / 180) * 111_320.0
        for i in segments {
            let ax = (lon - longitudes[i]) * k, ay = (lat - latitudes[i]) * 110_540
            let bx = (longitudes[i + 1] - longitudes[i]) * k, by = (latitudes[i + 1] - latitudes[i]) * 110_540
            let length2 = bx * bx + by * by
            let t = length2 == 0 ? 0 : min(max((ax * bx + ay * by) / length2, 0), 1)
            let off = hypot(ax - t * bx, ay - t * by)
            if off < best.offRoute {
                best = (cumulative[i] + t * (cumulative[i + 1] - cumulative[i]), off)
            }
        }
        return best
    }

    /// Index of the segment containing `distance` (clamped to the route).
    func segmentIndex(at distance: Double) -> Int {
        var low = 0, high = cumulative.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if cumulative[mid] <= distance { low = mid } else { high = mid }
        }
        return min(low, max(cumulative.count - 2, 0))
    }

    /// The point `distance` metres along the route, and the road's bearing there.
    func point(at distance: Double) -> (latitude: Double, longitude: Double, bearing: Double) {
        let d = min(max(distance, 0), length)
        let i = segmentIndex(at: d)
        guard latitudes.count > 1 else { return (latitudes.first ?? 0, longitudes.first ?? 0, 0) }
        let span = cumulative[i + 1] - cumulative[i]
        let t = span > 0 ? (d - cumulative[i]) / span : 0
        return (
            latitudes[i] + (latitudes[i + 1] - latitudes[i]) * t,
            longitudes[i] + (longitudes[i + 1] - longitudes[i]) * t,
            Geo.bearing(latitudes[i], longitudes[i], latitudes[i + 1], longitudes[i + 1])
        )
    }

    /// Scheduled seconds after trip start at `distance` (linear between stops).
    func scheduledOffset(at distance: Double) -> Double? {
        guard hasProfile else { return nil }
        return Self.interpolate(distance, xs: profileDistances, ys: profileOffsets)
    }

    /// Where the timetable puts the bus `offset` seconds after its trip starts.
    func distance(atOffset offset: Double) -> Double? {
        guard hasProfile else { return nil }
        return Self.interpolate(offset, xs: profileOffsets, ys: profileDistances)
    }

    /// Piecewise-linear lookup on a non-decreasing `xs`, clamped at both ends.
    static func interpolate(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var low = 0, high = xs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if xs[mid] <= x { low = mid } else { high = mid }
        }
        let span = xs[high] - xs[low]
        return span > 0 ? ys[low] + (ys[high] - ys[low]) * (x - xs[low]) / span : ys[high]
    }

    var coordinates: [(latitude: Double, longitude: Double)] {
        Array(zip(latitudes, longitudes))
    }
}

/// All bus route shapes, generated by tools/build_static_data.py. Shapes are
/// decoded on first use and cached.
nonisolated final class BusRouteStore: @unchecked Sendable {
    /// trip_id → shape index.
    let trips: [String: Int]
    /// "route_id|direction_id" → candidate shape indices.
    let routeShapes: [String: [Int]]
    let shapeCount: Int

    private let geometry: Data
    private let offsets: [Int]
    private let lock = NSLock()
    private var cache: [Int: RouteShape] = [:]

    init(geometry: Data, tripsJSON: Data) throws {
        guard geometry.count >= 8, geometry.prefix(4) == Data("LFB1".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.geometry = geometry
        let count = Int(geometry.readUInt32(at: 4))
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        var offset = 8
        for _ in 0..<count {
            offsets.append(offset)
            let points = Int(geometry.readUInt32(at: offset)), profile = Int(geometry.readUInt32(at: offset + 4))
            offset += 8 + points * 8 + profile * 8
        }
        guard offset == geometry.count else { throw CocoaError(.fileReadCorruptFile) }
        self.offsets = offsets
        shapeCount = count

        let json = try JSONSerialization.jsonObject(with: tripsJSON) as? [String: Any]
        trips = json?["trips"] as? [String: Int] ?? [:]
        routeShapes = json?["routes"] as? [String: [Int]] ?? [:]
    }

    @concurrent
    static func loadFromBundle(_ bundle: Bundle = .main) async throws -> BusRouteStore {
        func inflate(_ name: String, _ ext: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).\(ext)"])
            }
            // Raw DEFLATE, as written by the build script.
            return try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
        }
        return try BusRouteStore(geometry: inflate("bus_shapes", "bin"), tripsJSON: inflate("bus_trips.json", "deflate"))
    }

    func shape(_ index: Int) -> RouteShape? {
        guard offsets.indices.contains(index) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[index] { return cached }
        var offset = offsets[index]
        let points = Int(geometry.readUInt32(at: offset)), profile = Int(geometry.readUInt32(at: offset + 4))
        offset += 8
        var latitudes = [Double](), longitudes = [Double]()
        latitudes.reserveCapacity(points)
        longitudes.reserveCapacity(points)
        for _ in 0..<points {
            latitudes.append(Double(geometry.readInt32(at: offset)) / 1e5)
            longitudes.append(Double(geometry.readInt32(at: offset + 4)) / 1e5)
            offset += 8
        }
        var distances = [Double](), times = [Double]()
        for _ in 0..<profile {
            distances.append(Double(geometry.readFloat32(at: offset)))
            times.append(Double(geometry.readFloat32(at: offset + 4)))
            offset += 8
        }
        let shape = RouteShape(latitudes: latitudes, longitudes: longitudes, profileDistances: distances, profileOffsets: times)
        cache[index] = shape
        return shape
    }

    /// Candidate shapes for a vehicle: its exact trip if known, else every
    /// variant of its route and direction.
    func candidateShapes(tripId: String?, routeId: String?, directionId: Int?) -> [Int] {
        if let tripId, let index = trips[tripId] { return [index] }
        guard let routeId else { return [] }
        if let directionId { return routeShapes["\(routeId)|\(directionId)"] ?? [] }
        return (routeShapes["\(routeId)|0"] ?? []) + (routeShapes["\(routeId)|1"] ?? [])
    }
}

/// Small spherical-geometry helpers shared by the route code.
nonisolated enum Geo {
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(a)))
    }

    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

private extension Data {
    nonisolated func readUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    nonisolated func readInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset))
    }

    nonisolated func readFloat32(at offset: Int) -> Float32 {
        Float32(bitPattern: readUInt32(at: offset))
    }
}
