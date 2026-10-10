import SwiftUI

struct ContentView: View {
    @State private var model = LiveMapModel()
    @State private var menu = BottomMenu.Detent.launchState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            ZStack(alignment: .bottom) {
                content(controlsInset: BottomMenu.collapsedContentHeight + safeArea.bottom)
                BottomMenu(
                    detent: $menu,
                    model: model,
                    screenHeight: geometry.size.height + safeArea.top + safeArea.bottom,
                    safeArea: safeArea,
                    onPickStop: { model.focus(on: $0) }
                )
            }
            // The menu runs to the bottom edge; it pads for the home indicator itself.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .tint(Theme.green)
        .preferredColorScheme(.light)
        // Poll only while active; the task is cancelled when the scene backgrounds.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.run()
        }
        .sheet(item: $model.selection) { selection in
            Group {
                switch selection {
                case .stop(let stop): StopDetailSheet(stop: stop, model: model)
                case .vehicle(let vehicle): VehicleDetailSheet(vehicle: vehicle, model: model)
                }
            }
            .presentationDetents([.fraction(0.38), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.38)))
        }
    }

    private func closeMenu() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { menu = .collapsed }
    }

    /// The map plus its floating chrome; the bottom menu is layered over this.
    private func content(controlsInset: CGFloat) -> some View {
        ZStack {
            TransitMapView(
                data: model.data,
                vehicles: model.displayedVehicles,
                vehiclesVersion: model.displayVersion,
                enabledModes: model.enabledModes,
                watchedStop: model.watchedStop,
                etas: model.watchETAs,
                selectedVehicleId: model.selectedVehicleId,
                estimatedPositions: model.estimatedPositions,
                positionsVersion: model.positionsVersion,
                trainPlacements: model.trainPlacements,
                railPaths: model.railPaths,
                selectedRoute: model.selectedRoute,
                cameraRequest: model.cameraRequest,
                onSelect: { model.selection = $0 },
                onRegionChange: { model.mapCenterChanged($0) }
            )
            .ignoresSafeArea()

            // While the menu is open, a tap on the map closes it (rather than selecting things underneath).
            if menu == .expanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { closeMenu() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Close menu")
            }

            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    HeaderCard(status: model.status, lastUpdated: model.lastUpdated, hasAPIKey: model.hasAPIKey)
                    if let stop = model.watchedStop {
                        WatchingBanner(
                            stop: stop,
                            vehicleCount: model.displayedVehicles.filter { $0.mode == .bus }.count,
                            onTap: { model.focus(on: stop) },
                            onClear: { withAnimation(.snappy) { model.watch(nil) } }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                Spacer()
                if menu == .collapsed {
                    HStack {
                        Spacer()
                        MapControls(
                            onLocate: { model.showUserLocation() },
                            onHome: { model.showDublin() }
                        )
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // Keep the controls just above the collapsed menu.
            .padding(.bottom, controlsInset + 12)
            // The keyboard only appears with full-screen search, which covers this layer.
            .ignoresSafeArea(.keyboard)
        }
    }
}

#Preview {
    ContentView()
}
