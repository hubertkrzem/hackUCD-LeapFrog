import Foundation

nonisolated enum TransportMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bus, luas, dart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bus: "Bus"
        case .luas: "Luas"
        case .dart: "DART"
        }
    }

    var symbol: String {
        switch self {
        case .bus: "bus.fill"
        case .luas: "tram.fill"
        case .dart: "train.side.front.car"
        }
    }
}
