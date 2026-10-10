import SwiftUI

struct ContentView: View {
    @State private var model = LiveMapModel()
    @State private var showingSearch = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            TransitMapView(
                data: model.data,
                vehicles: model.displayedVehicles,
                vehiclesVersion: model.displayVersion,
                enabledModes: model.enabledModes,
                watchedStop: model.watchedStop,
                etas: model.watchETAs,
                selectedVehicleId: model.selectedVehicleId,
                cameraRequest: model.cameraRequest,
                onSelect: { model.selection = $0 },
                onRegionChange: { model.mapCenterChanged($0) }
            )
            .ignoresSafeArea()

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
                HStack {
                    Spacer()
                    MapControls(
                        onSearch: { showingSearch = true },
                        onLocate: { model.showUserLocation() },
                        onHome: { model.showDublin() }
                    )
                }
                ModeFilterBar(model: model)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        .sheet(isPresented: $showingSearch) {
            SearchSheet(model: model) { stop in
                showingSearch = false
                model.focus(on: stop)
            }
            .presentationDragIndicator(.visible)
        }
    }
}

#Preview {
    ContentView()
}
