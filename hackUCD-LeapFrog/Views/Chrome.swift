import SwiftUI

struct HeaderCard: View {
    let status: LiveMapModel.Status
    let lastUpdated: Date?
    let hasAPIKey: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.green)
                Image(systemName: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("LeapFrog")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Live transit · Dublin")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer(minLength: 8)
            StatusPill(status: status, lastUpdated: lastUpdated, hasAPIKey: hasAPIKey)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .card()
    }
}

struct StatusPill: View {
    let status: LiveMapModel.Status
    let lastUpdated: Date?
    let hasAPIKey: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .overlay {
                        if status == .live {
                            Circle().stroke(color.opacity(0.35), lineWidth: 4)
                        }
                    }
                Text(label(now: context.date))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(status == .live ? Theme.green : Theme.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.1), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status {
        case .live: Theme.brightGreen
        case .loading: .gray
        case .degraded: .orange
        case .failed: .red
        }
    }

    private func label(now: Date) -> String {
        switch status {
        case .loading:
            return "Connecting…"
        case .failed:
            return hasAPIKey ? "Offline" : "No API key"
        case .live, .degraded:
            guard let lastUpdated else { return "Live" }
            let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
            let age = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
            return status == .live ? "Live · \(age)" : (hasAPIKey ? "Partial · \(age)" : "No API key")
        }
    }
}

struct ModeFilterBar: View {
    let model: LiveMapModel
    /// Inside the bottom menu the bar sits on a grey track instead of its own floating card.
    var inPanel = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TransportMode.allCases) { mode in
                let isOn = model.enabledModes.contains(mode)
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.toggle(mode) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                        Text(model.vehicleCount(for: mode), format: .number.notation(.compactName))
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((isOn ? Color.white : mode.tint).opacity(isOn ? 0.25 : 0.12), in: Capsule())
                    }
                    .foregroundStyle(isOn ? .white : Theme.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isOn ? mode.tint : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityLabel("\(mode.title), \(model.vehicleCount(for: mode)) vehicles")
            }
        }
        .padding(5)
        .background {
            if inPanel {
                Capsule().fill(Theme.canvas)
            } else {
                Capsule().fill(Theme.surface)
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
                    .shadow(color: Theme.ink.opacity(0.12), radius: 14, y: 6)
            }
        }
    }
}

struct MapControls: View {
    let onLocate: () -> Void
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            controlButton("location.fill", label: "My location", action: onLocate)
            Divider().frame(width: 28)
            controlButton("building.2.fill", label: "Dublin city centre", action: onHome)
        }
        .card(radius: 16)
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.green)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Slim row under the header while a stop is being watched.
struct WatchingBanner: View {
    let stop: Stop
    let vehicleCount: Int
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Theme.green, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Watching")
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.secondaryInk)
                        Text(stop.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(vehicleCount == 0 ? "None on the way" : "\(vehicleCount) on the way")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.green)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 28, height: 28)
                    .background(Theme.canvas, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop watching \(stop.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card(radius: 18)
    }
}
