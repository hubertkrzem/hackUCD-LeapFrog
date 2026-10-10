import SwiftUI

/// The slide-up panel along the bottom of the map.
///
/// - Collapsed: the mode filters with a swipe-up hint.
/// - Expanded: two thirds of the screen, map still visible above — stop search,
///   Leap Card top-up and TFI Driver Check.
/// - Searching: full screen, search field at the top, results above the keyboard.
struct BottomMenu: View {
    enum Detent {
        case collapsed, expanded, searching
    }

    enum Destination: Hashable {
        case leapCard, driverCheck
    }

    #if DEBUG
    /// For screenshots: `-menu collapsed|expanded|searching|leapCard|driverCheck` and `-menuQuery "Tara"`.
    private static let launchArgument = UserDefaults.standard.string(forKey: "menu")
    #endif

    @Binding var detent: Detent
    let model: LiveMapModel
    /// Full screen height (including safe areas) and the safe-area insets, measured by the parent.
    let screenHeight: CGFloat
    let safeArea: EdgeInsets
    let onPickStop: (Stop) -> Void

    @State private var query = BottomMenu.launchQuery
    @State private var path = BottomMenu.launchPath
    @FocusState private var searchFocused: Bool
    @GestureState private var drag: CGFloat = 0

    /// Grabber, hint and filter bar; the bottom safe area is added on top.
    static let collapsedContentHeight: CGFloat = 118

    var collapsedHeight: CGFloat { Self.collapsedContentHeight + safeArea.bottom }
    private var expandedHeight: CGFloat { screenHeight * 2 / 3 }

    private var height: CGFloat {
        let resting = detent == .collapsed ? collapsedHeight : expandedHeight
        // Follow the finger, with a little give past the expanded height.
        return min(max(resting - drag, collapsedHeight), expandedHeight + 40)
    }

    /// 0 when collapsed, 1 when expanded; crossfades the two layouts while dragging.
    private var progress: CGFloat {
        min(max((height - collapsedHeight) / max(expandedHeight - collapsedHeight, 1), 0), 1)
    }

    var body: some View {
        if detent == .searching {
            searchScreen
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            panel
        }
    }

    // MARK: Launch state

    // Overridable in Debug builds via launch arguments; the app always opens collapsed otherwise.
    private static var launchQuery: String {
        #if DEBUG
        UserDefaults.standard.string(forKey: "menuQuery") ?? ""
        #else
        ""
        #endif
    }

    private static var launchPath: [Destination] {
        #if DEBUG
        switch launchArgument {
        case "leapCard": [.leapCard]
        case "driverCheck": [.driverCheck]
        default: []
        }
        #else
        []
        #endif
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.hairline)
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            ZStack(alignment: .top) {
                collapsedContent
                    .opacity(Double(1 - progress * 2))
                    .allowsHitTesting(detent == .collapsed)
                    .accessibilityHidden(detent != .collapsed)
                expandedContent
                    .opacity(Double(progress * 2 - 1))
                    .allowsHitTesting(detent == .expanded)
                    .accessibilityHidden(detent != .expanded)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.ink.opacity(0.14), radius: 16, y: -2)
        )
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private var collapsedContent: some View {
        VStack(spacing: 10) {
            Button { setDetent(.expanded) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Swipe up for search, Leap Card & more")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open menu")
            .accessibilityHint("Search stops, top up your Leap Card or check a taxi driver")

            ModeFilterBar(model: model, inPanel: true)
                .padding(.horizontal, 16)
        }
    }

    private var expandedContent: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 18) {
                Button { startSearch() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.secondaryInk)
                        Text("Search stops")
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                    }
                    .font(.body)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search stops")

                VStack(spacing: 0) {
                    NavigationLink(value: Destination.leapCard) {
                        MenuRow(symbol: "creditcard.fill", title: "Leap Card", subtitle: "Check your balance and top up")
                    }
                    Divider().padding(.leading, 66)
                    NavigationLink(value: Destination.driverCheck) {
                        MenuRow(symbol: "checkmark.shield.fill", title: "TFI Driver Check",
                                subtitle: "Check a taxi and driver are licensed")
                    }
                }
                .buttonStyle(.plain)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.surface)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .leapCard: LeapCardView()
                case .driverCheck: DriverCheckView()
                }
            }
        }
        .tint(Theme.green)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.height
                if detent == .collapsed, predicted < -60 {
                    setDetent(.expanded)
                } else if detent == .expanded, predicted > 80 {
                    setDetent(.collapsed)
                }
            }
    }

    private func setDetent(_ new: Detent) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            detent = new
        }
        if new == .collapsed { path = [] }
    }

    // MARK: Search

    private var results: [Stop] {
        StopSearch.results(for: query, in: model.data.displayStops)
    }

    private var searchScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.secondaryInk)
                    TextField("Search stops", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button("Cancel") { endSearch(then: .expanded) }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.green)
            }
            .padding(.horizontal, 16)
            .padding(.top, safeArea.top + 8)
            .padding(.bottom, 10)

            Divider()

            List(results) { stop in
                Button {
                    endSearch(then: .collapsed)
                    onPickStop(stop)
                } label: {
                    StopResultRow(stop: stop, isWatched: model.watchedStopId == stop.id)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        // Fill under the status bar and home indicator, but stay above the keyboard.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .tint(Theme.green)
        .onAppear { searchFocused = true }
    }

    private func startSearch() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { detent = .searching }
    }

    private func endSearch(then next: Detent) {
        searchFocused = false
        query = ""
        setDetent(next)
    }
}

/// A row in the expanded menu: green icon tile, title, subtitle and a chevron.
private struct MenuRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Theme.green, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Stop search shared by the menu: rail stations first when browsing, then matches by name or code.
extension BottomMenu.Detent {
    static var launchState: Self {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "menu") {
        case "expanded", "leapCard", "driverCheck": return .expanded
        case "searching": return .searching
        default: return .collapsed
        }
        #else
        return .collapsed
        #endif
    }
}

enum StopSearch {
    static func results(for query: String, in stops: [Stop]) -> [Stop] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return stops.filter { $0.mode != .bus }.sorted { $0.name < $1.name }
        }
        return stops
            .filter { $0.name.localizedStandardContains(trimmed) || $0.code == trimmed }
            .sorted { ($0.mode == .bus ? 1 : 0, $0.name) < ($1.mode == .bus ? 1 : 0, $1.name) }
            .prefix(60)
            .map { $0 }
    }
}

struct StopResultRow: View {
    let stop: Stop
    let isWatched: Bool

    var body: some View {
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
            if isWatched {
                Image(systemName: "eye.fill").foregroundStyle(Theme.green)
            }
        }
    }
}

// MARK: - Menu destinations

private struct LeapCardView: View {
    static let topUpURL = URL(string: "https://www.leapcard.ie")!

    var body: some View {
        MenuDestinationLayout(
            symbol: "creditcard.fill",
            title: "Leap Card",
            intro: "Top up your TFI Leap Card and check your balance and journey history.",
            points: [
                ("person.crop.circle", "Log in to your Leap account to top up online."),
                ("clock.arrow.circlepath", "Online top-ups are collected when you next tap your card on a validator."),
                ("iphone.radiowaves.left.and.right", "With the TFI Leap Top-Up app, you can top up by holding the card to your phone."),
            ],
            linkTitle: "Top up on leapcard.ie",
            link: Self.topUpURL
        )
        .navigationTitle("Leap Card")
    }
}

private struct DriverCheckView: View {
    static let driverCheckURL = URL(string: "https://www.transportforireland.ie/getting-around/by-taxi/driver-check-app/")!

    var body: some View {
        MenuDestinationLayout(
            symbol: "checkmark.shield.fill",
            title: "TFI Driver Check",
            intro: "Before you get into a taxi, hackney or limousine, check that the vehicle and driver are licensed.",
            points: [
                ("car.fill", "Check the vehicle's registration and licence number from its roof or door signs."),
                ("person.text.rectangle", "Confirm the driver against the ID card displayed on the dashboard."),
                ("square.and.arrow.up", "Share your journey details with a friend."),
            ],
            linkTitle: "Open TFI Driver Check",
            link: Self.driverCheckURL
        )
        .navigationTitle("Driver Check")
    }
}

private struct MenuDestinationLayout: View {
    let symbol: String
    let title: String
    let intro: String
    let points: [(symbol: String, text: String)]
    let linkTitle: String
    let link: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Theme.green, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.ink)
                }
                Text(intro)
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(points, id: \.text) { point in
                        Label {
                            Text(point.text).foregroundStyle(Theme.ink)
                        } icon: {
                            Image(systemName: point.symbol).foregroundStyle(Theme.green)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Link(destination: link) {
                    Label(linkTitle, systemImage: "arrow.up.right")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(Theme.green, in: Capsule())
                }
            }
            .padding(16)
        }
        .background(Theme.surface)
        .navigationBarTitleDisplayMode(.inline)
    }
}
