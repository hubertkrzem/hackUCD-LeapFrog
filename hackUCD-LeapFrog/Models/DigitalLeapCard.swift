import Foundation

/// A cloud-based Leap Card: the balance lives in the account, not on a chip,
/// so it can be carried in Apple Wallet and topped up instantly.
///
/// This is a preview of the NTA's planned account-based ticketing; nothing here
/// talks to a real Leap back end yet.
nonisolated struct DigitalLeapCard: Codable, Hashable, Sendable {
    enum FareType: String, Codable, CaseIterable, Identifiable, Sendable {
        case adult, youngAdult, student, child

        var id: String { rawValue }

        var title: String {
            switch self {
            case .adult: "Adult"
            case .youngAdult: "Young Adult"
            case .student: "Student"
            case .child: "Child"
            }
        }

        var detail: String {
            switch self {
            case .adult: "Standard fares"
            case .youngAdult: "Ages 19–23, discounted fares"
            case .student: "Full-time students, with student ID"
            case .child: "Under 19"
            }
        }
    }

    let id: UUID
    var holderName: String
    var fareType: FareType
    /// 16-digit card number, shown masked.
    let number: String
    /// Balance in cents.
    var balance: Int
    let createdAt: Date
    var addedToWallet: Bool
    var transactions: [Transaction]

    var maskedNumber: String { "•••• \(number.suffix(4))" }

    nonisolated struct Transaction: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case topUp, fare
        }

        let id: UUID
        let kind: Kind
        /// Cents: positive for top-ups, negative for fares.
        let amount: Int
        let date: Date
        let detail: String
    }

    static func new(holderName: String, fareType: FareType, now: Date = .now) -> DigitalLeapCard {
        let digits = (0..<12).map { _ in String(Int.random(in: 0...9)) }.joined()
        return DigitalLeapCard(
            id: UUID(), holderName: holderName, fareType: fareType, number: "3086" + digits,
            balance: 0, createdAt: now, addedToWallet: false, transactions: []
        )
    }
}

nonisolated enum Euro {
    static func format(cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "EUR"))
    }
}
