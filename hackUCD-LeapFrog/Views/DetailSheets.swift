import SwiftUI

struct ModeBadge: View {
    let mode: TransportMode
    var text: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(mode.tint)
            if let text {
                Text(text)
                    .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .padding(4)
            } else {
                Image(systemName: mode.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
    }
}

struct SheetHeader<Accessory: View>: View {
    let mode: TransportMode
    let badgeText: String?
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            ModeBadge(mode: mode, text: badgeText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer()
            accessory
        }
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(mode: TransportMode, badgeText: String?, title: String, subtitle: String) {
        self.init(mode: mode, badgeText: badgeText, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Stop

struct StopDetailSheet: View {
    let stop: Stop
    let model: LiveMapModel

    @State private var luasForecast: LuasClient.Forecast?
    @State private var luasError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(
                    mode: stop.mode,
                    badgeText: nil,
                    title: stop.name,
                    subtitle: stop.code.isEmpty ? "\(stop.mode.title) stop" : "\(stop.mode.title) · Stop \(stop.code)"
                )
                WatchStopButton(isWatching: model.watchedStopId == stop.id) {
                    withAnimation(.snappy) { model.watch(model.watchedStopId == stop.id ? nil : stop) }
                }
                if stop.mode == .luas {
                    luasSection
                } else {
                    liveSection(model.arrivals(for: stop))
                }
            }
            .padding(20)
        }
        .background(Theme.surface)
        .task(id: stop.id) { await pollLuas() }
    }

    @ViewBuilder
    private var luasSection: some View {
        if let message = luasForecast?.message, !message.isEmpty {
            Label(message, systemImage: "info.circle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.green)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        if let forecast = luasForecast {
            let groups = Dictionary(grouping: forecast.arrivals, by: { $0.group ?? "" })
            if groups.isEmpty {
                EmptyArrivals(text: "No trams forecast right now")
            }
            ForEach(groups.keys.sorted(), id: \.self) { direction in
                ArrivalSection(title: direction, arrivals: groups[direction] ?? [], mode: .luas)
            }
        } else if let luasError {
            EmptyArrivals(text: luasError)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
    }

    @ViewBuilder
    private func liveSection(_ arrivals: [Arrival]) -> some View {
        if arrivals.isEmpty {
            EmptyArrivals(text: model.hasAPIKey
                ? "No live updates for this stop right now"
                : "Add your NTA API key to see live arrivals")
        } else {
            ArrivalSection(title: "Live updates", arrivals: Array(arrivals.prefix(12)), mode: stop.mode)
        }
    }

    private func pollLuas() async {
        guard stop.mode == .luas, let code = stop.luasCode else { return }
        while !Task.isCancelled {
            do {
                luasForecast = try await model.luas.forecast(stopCode: code)
                luasError = nil
            } catch {
                if luasForecast == nil { luasError = "Couldn't reach Luas forecasts" }
            }
            try? await Task.sleep(for: .seconds(20))
        }
    }
}

struct ArrivalSection: View {
    let title: String
    let arrivals: [Arrival]
    let mode: TransportMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryInk)
            VStack(spacing: 0) {
                ForEach(Array(arrivals.enumerated()), id: \.element.id) { index, arrival in
                    if index > 0 { Divider().padding(.leading, 56) }
                    ArrivalRow(arrival: arrival, mode: mode)
                }
            }
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct ArrivalRow: View {
    let arrival: Arrival
    let mode: TransportMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 12) {
                ModeBadge(mode: mode, text: mode == .bus ? arrival.routeName : nil, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(arrival.destination.isEmpty ? arrival.routeName : arrival.destination)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let delay = arrival.delay {
                        Text(delayText(delay))
                            .font(.caption)
                            .foregroundStyle(delay > 120 ? .orange : Theme.green)
                    }
                }
                Spacer()
                Text(dueText(now: context.date))
                    .font(.system(.body, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func dueText(now: Date) -> String {
        let minutes: Int? = arrival.dueMinutes ?? arrival.time.map { Int($0.timeIntervalSince(now) / 60) }
        guard let minutes else { return "–" }
        return minutes <= 0 ? "Due" : "\(minutes) min"
    }

    private func delayText(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        if minutes == 0 { return "On time" }
        return seconds > 0 ? "\(minutes) min late" : "\(minutes) min early"
    }
}

struct EmptyArrivals: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Vehicle

struct VehicleDetailSheet: View {
    let vehicle: Vehicle
    let model: LiveMapModel

    /// Follow the vehicle across refreshes so the sheet stays current.
    private var current: Vehicle {
        model.vehicles.first { $0.id == vehicle.id } ?? vehicle
    }

    var body: some View {
        let vehicle = current
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(
                    mode: vehicle.mode,
                    badgeText: vehicle.mode == .bus ? vehicle.routeName : nil,
                    title: vehicle.headsign.map { "To \($0)" } ?? vehicle.routeDescription ?? vehicle.routeName,
                    subtitle: vehicle.operatorName ?? vehicle.mode.title
                )
                VStack(spacing: 0) {
                    if let description = vehicle.routeDescription {
                        InfoRow(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Route", value: description)
                        Divider().padding(.leading, 44)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        InfoRow(symbol: "clock", title: "Updated",
                                value: "\(max(0, Int(context.date.timeIntervalSince(vehicle.timestamp))))s ago")
                    }
                    Divider().padding(.leading, 44)
                    InfoRow(symbol: vehicle.isEstimated ? "wand.and.stars" : "dot.radiowaves.left.and.right",
                            title: "Source", value: vehicle.source.label)
                }
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if vehicle.isEstimated {
                    Text("This tram's position is estimated between stops from live predicted times, as the feed has no GPS position for it.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .padding(20)
        }
        .background(Theme.surface)
    }
}

struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.green)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(Theme.secondaryInk)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - Watch control

struct WatchStopButton: View {
    let isWatching: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isWatching ? "Stop watching" : "Watch this stop",
                  systemImage: isWatching ? "eye.slash.fill" : "eye.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(isWatching ? Theme.green : .white)
                .background(isWatching ? Theme.green.opacity(0.1) : Theme.green, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows only vehicles heading to this stop")
    }
}

// MARK: - Search

struct SearchSheet: View {
    let model: LiveMapModel
    let onPick: (Stop) -> Void

    @State private var query = ""

    private var results: [Stop] {
        let stops = model.data.displayStops
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Rail first when browsing: they're the most likely destinations.
            return stops.filter { $0.mode != .bus }.sorted { $0.name < $1.name }
        }
        return stops
            .filter { $0.name.localizedStandardContains(trimmed) || $0.code == trimmed }
            .sorted { ($0.mode == .bus ? 1 : 0, $0.name) < ($1.mode == .bus ? 1 : 0, $1.name) }
            .prefix(60)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List(results) { stop in
                Button { onPick(stop) } label: {
                    HStack(spacing: 12) {
                        ModeBadge(mode: stop.mode, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stop.name)
                                .foregroundStyle(Theme.ink)
                            Text(stop.code.isEmpty ? stop.mode.title : "\(stop.mode.title) · \(stop.code)")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        if model.watchedStopId == stop.id {
                            Image(systemName: "eye.fill").foregroundStyle(Theme.green)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stop name or number")
            .navigationTitle("Find a stop")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.green)
    }
}
