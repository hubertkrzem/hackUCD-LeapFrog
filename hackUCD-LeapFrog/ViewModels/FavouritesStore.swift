import Foundation
import Observation

/// Favourite route_ids, persisted in UserDefaults.
/// Currently unused: favourites are switched off in the UI for now.
@Observable
final class FavouritesStore {
    /// E1, E2, 133, 131, S6 and the Luas Green line.
    static let defaultRouteIds: Set<String> = ["1 E1 a", "1 E2 a", "2 133 e", "2 131 a", "3 S6 a", "10000 GREEN g a"]
    private static let key = "favouriteRouteIds"

    private let defaults: UserDefaults
    private(set) var routeIds: Set<String> {
        didSet { defaults.set(Array(routeIds).sorted(), forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        routeIds = (defaults.array(forKey: Self.key) as? [String]).map(Set.init) ?? Self.defaultRouteIds
    }

    func contains(_ routeId: String?) -> Bool {
        routeId.map(routeIds.contains) ?? false
    }

    func toggle(_ routeId: String) {
        if routeIds.contains(routeId) {
            routeIds.remove(routeId)
        } else {
            routeIds.insert(routeId)
        }
    }
}
