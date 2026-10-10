import PassKit
import SwiftUI

/// Set up and top up a cloud-based Leap Card that lives in Apple Wallet.
struct LeapDigitalView: View {
    let store: LeapDigitalStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreviewNotice()
                if let card = store.card {
                    CardHome(card: card, store: store)
                } else {
                    CardSetup(store: store)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.surface)
        .navigationTitle("LeapDigital")
        .navigationBarTitleDisplayMode(.inline)
        // Solid white bar: no translucent blur of the content scrolling underneath.
        .toolbarBackground(Theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct PreviewNotice: View {
    var body: some View {
        Label {
            Text("A preview of the NTA's planned account-based Leap. Cards and top-ups here are simulated.")
                .font(.footnote)
                .foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: "sparkles").foregroundStyle(Theme.green)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Setup

private struct CardSetup: View {
    let store: LeapDigitalStore
    @State private var name = ""
    @State private var fareType: DigitalLeapCard.FareType = .adult

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LeapCardArt(holder: name.isEmpty ? "Your name" : name, fareType: fareType, balance: nil, number: nil)

            VStack(alignment: .leading, spacing: 12) {
                Benefit(symbol: "wave.3.right", text: "Tap your iPhone or Apple Watch on any Leap validator — no physical card.")
                Benefit(symbol: "bolt.fill", text: "Top-ups land instantly: the balance lives in your account, not on a chip.")
                Benefit(symbol: "arrow.triangle.2.circlepath", text: "Lose your phone? Your balance and fare caps move to the new device.")
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Name on card")
                TextField("Full name", text: $name)
                    .textContentType(.name)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Fare type")
                VStack(spacing: 0) {
                    ForEach(DigitalLeapCard.FareType.allCases) { type in
                        Button { fareType = type } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(type.title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                                    Text(type.detail).font(.caption).foregroundStyle(Theme.secondaryInk)
                                }
                                Spacer()
                                Image(systemName: fareType == type ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(fareType == type ? Theme.green : Theme.hairline)
                                    .font(.title3)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(fareType == type ? .isSelected : [])
                        if type != DigitalLeapCard.FareType.allCases.last { Divider().padding(.leading, 14) }
                    }
                }
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            PrimaryButton(title: "Create LeapDigital card", symbol: "plus.circle.fill") {
                withAnimation(.snappy) { store.createCard(holderName: name, fareType: fareType) }
            }
        }
    }
}

// MARK: - Card home

private struct CardHome: View {
    let card: DigitalLeapCard
    let store: LeapDigitalStore
    @State private var selectedAmount = 2_000
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LeapCardArt(holder: card.holderName, fareType: card.fareType, balance: card.balance, number: card.maskedNumber)

            walletSection
            topUpSection
            activitySection

            Button("Remove card from this device", role: .destructive) { confirmingRemove = true }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .confirmationDialog("Remove LeapDigital card?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                    Button("Remove card", role: .destructive) { withAnimation { store.removeCard() } }
                } message: {
                    Text("In the preview the card and its balance are only stored on this device.")
                }
        }
    }

    @ViewBuilder
    private var walletSection: some View {
        if card.addedToWallet {
            Label("In Apple Wallet · Express Mode on", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.green.opacity(0.08), in: Capsule())
        } else {
            VStack(spacing: 6) {
                AddToWalletButton { withAnimation { store.markAddedToWallet() } }
                    .frame(height: 48)
                Text("Preview: shows how it will look. Real Wallet passes will be issued by the NTA.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var topUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Top up")
            HStack(spacing: 8) {
                ForEach(LeapDigitalStore.topUpAmounts, id: \.self) { amount in
                    let selected = amount == selectedAmount
                    Button { selectedAmount = amount } label: {
                        Text(Euro.format(cents: amount).replacingOccurrences(of: ".00", with: ""))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(selected ? .white : Theme.ink)
                            .background(selected ? Theme.green : Theme.canvas, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            switch store.topUpState {
            case .processing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Processing payment…").foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            default:
                PrimaryButton(title: "Top up \(Euro.format(cents: selectedAmount))", symbol: "creditcard.fill") {
                    Task { await store.topUp(cents: selectedAmount) }
                }
            }

            Group {
                switch store.topUpState {
                case .succeeded(let amount):
                    Label("\(Euro.format(cents: amount)) added — ready to tap", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                default:
                    Label(store.payments.disclosure, systemImage: "lock.fill")
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .font(.caption)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Activity")
            if card.transactions.isEmpty {
                Text("No activity yet. Top up, then tap on to your first journey.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(card.transactions.prefix(8)) { transaction in
                        HStack(spacing: 12) {
                            Image(systemName: transaction.kind == .topUp ? "arrow.down.circle.fill" : "tram.fill")
                                .foregroundStyle(transaction.kind == .topUp ? Theme.green : Theme.secondaryInk)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(transaction.detail).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(transaction.date, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer()
                            Text((transaction.amount > 0 ? "+" : "") + Euro.format(cents: transaction.amount))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(transaction.amount > 0 ? Theme.green : Theme.ink)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if transaction.id != card.transactions.prefix(8).last?.id { Divider().padding(.leading, 48) }
                    }
                }
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - Pieces

/// The digital card itself: TFI green, contactless mark, balance.
struct LeapCardArt: View {
    let holder: String
    let fareType: DigitalLeapCard.FareType
    let balance: Int?
    let number: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("leap")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("DIGITAL")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .opacity(0.85)
                Spacer()
                Image(systemName: "wave.3.right")
                    .font(.system(size: 20, weight: .semibold))
            }
            Spacer(minLength: 12)
            if let balance {
                Text("Balance")
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
                Text(Euro.format(cents: balance))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(holder).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(fareType.title).font(.caption).opacity(0.85)
                }
                Spacer()
                if let number {
                    Text(number).font(.subheadline.monospaced()).opacity(0.9)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity)
        .aspectRatio(1.586, contentMode: .fit) // ID-1 card proportions
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.green, Color(UIColor(hex: 0x0B5A3C))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Theme.brightGreen.opacity(0.25))
                        .frame(width: 180)
                        .offset(x: 60, y: 70)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Theme.green.opacity(0.35), radius: 14, y: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Apple's standard "Add to Apple Wallet" button.
private struct AddToWalletButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> PKAddPassButton {
        let button = PKAddPassButton(addPassButtonStyle: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: PKAddPassButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

private struct Benefit: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.green)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(Theme.secondaryInk)
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(Theme.green, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
