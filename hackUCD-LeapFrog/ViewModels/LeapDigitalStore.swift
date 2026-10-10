import Foundation
import Observation

/// The rider's LeapDigital card, saved on the device until the NTA's
/// account-based back end exists.
@Observable
final class LeapDigitalStore {
    enum TopUpState: Equatable {
        case idle
        case processing
        case succeeded(amount: Int)
        case failed(String)
    }

    static let topUpAmounts = [500, 1000, 2000, 3000, 5000]
    /// Upper limit on a single top-up, in cents.
    static let maxTopUp = 10_000

    private(set) var card: DigitalLeapCard?
    private(set) var topUpState: TopUpState = .idle
    let payments: any PaymentProvider

    private let defaults: UserDefaults
    private static let key = "leapDigitalCard"

    init(defaults: UserDefaults = .standard, payments: any PaymentProvider = PaymentProviders.current) {
        self.defaults = defaults
        self.payments = payments
        card = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(DigitalLeapCard.self, from: $0) }
        #if DEBUG
        if card == nil, defaults.bool(forKey: "leapDigitalDemo") { card = Self.demoCard }
        #endif
    }

    func createCard(holderName: String, fareType: DigitalLeapCard.FareType) {
        let name = holderName.trimmingCharacters(in: .whitespacesAndNewlines)
        card = DigitalLeapCard.new(holderName: name.isEmpty ? "Leap rider" : name, fareType: fareType)
        save()
    }

    func topUp(cents: Int) async {
        guard let current = card, topUpState != .processing, cents > 0, cents <= Self.maxTopUp else { return }
        topUpState = .processing
        do {
            let receipt = try await payments.pay(PaymentRequest(
                amount: cents, cardId: current.id, description: "LeapDigital top-up"
            ))
            // A real back end would credit the balance from the payment webhook; here we credit locally.
            card?.balance += receipt.amount
            card?.transactions.insert(.init(id: UUID(), kind: .topUp, amount: receipt.amount, date: receipt.date,
                                            detail: "Top-up · \(receipt.reference)"), at: 0)
            save()
            topUpState = .succeeded(amount: receipt.amount)
        } catch {
            topUpState = .failed(error.localizedDescription)
        }
    }

    func markAddedToWallet() {
        card?.addedToWallet = true
        save()
    }

    func removeCard() {
        card = nil
        topUpState = .idle
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        guard let card, let data = try? JSONEncoder().encode(card) else { return }
        defaults.set(data, forKey: Self.key)
    }

    #if DEBUG
    /// For screenshots: launch with `-leapDigitalDemo 1`.
    private static var demoCard: DigitalLeapCard {
        var card = DigitalLeapCard.new(holderName: "Alex Murphy", fareType: .youngAdult)
        card.balance = 1_340
        card.transactions = [
            .init(id: UUID(), kind: .fare, amount: -130, date: .now.addingTimeInterval(-3_600), detail: "Dublin Bus · 46A"),
            .init(id: UUID(), kind: .fare, amount: -130, date: .now.addingTimeInterval(-30_000), detail: "Luas · Green line"),
            .init(id: UUID(), kind: .topUp, amount: 2_000, date: .now.addingTimeInterval(-90_000), detail: "Top-up"),
        ]
        return card
    }
    #endif
}
