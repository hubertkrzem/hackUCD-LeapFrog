import Foundation

/// A request to charge the rider for a LeapDigital top-up.
nonisolated struct PaymentRequest: Sendable {
    /// Amount in cents, EUR.
    let amount: Int
    let cardId: UUID
    let description: String
}

nonisolated struct PaymentReceipt: Sendable {
    let reference: String
    let amount: Int
    let date: Date
}

nonisolated enum PaymentError: LocalizedError, Equatable {
    case notConfigured
    case declined(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Payments aren't set up yet"
        case .declined(let reason): "Payment declined: \(reason)"
        case .cancelled: "Payment cancelled"
        }
    }
}

/// Anything that can take money for a top-up. The app talks only to this, so
/// swapping the preview provider for Stripe Connect is a one-line change in
/// `PaymentProviders.current`.
protocol PaymentProvider: Sendable {
    /// Shown under the top-up button, e.g. "Preview — no money is taken".
    var disclosure: String { get }
    func pay(_ request: PaymentRequest) async throws -> PaymentReceipt
}

nonisolated enum PaymentProviders {
    /// The provider the app uses. Returns Stripe Connect once it's configured
    /// (see `StripeConnectPaymentProvider`), otherwise the preview provider.
    static var current: any PaymentProvider {
        if let stripe = StripeConnectPaymentProvider.fromConfiguration() {
            return stripe
        }
        return PreviewPaymentProvider()
    }
}

/// Simulates a successful card payment so the flow can be demoed end to end.
nonisolated struct PreviewPaymentProvider: PaymentProvider {
    var delay: Duration = .seconds(1.2)

    var disclosure: String { "Preview: no money is taken." }

    func pay(_ request: PaymentRequest) async throws -> PaymentReceipt {
        try await Task.sleep(for: delay)
        return PaymentReceipt(reference: "PREVIEW-\(UUID().uuidString.prefix(8))", amount: request.amount, date: .now)
    }
}

/// Placeholder for taking real payments with Stripe Connect.
///
/// Intended set-up:
/// 1. The NTA (or its ticketing operator) is the Stripe **platform**; the
///    revenue-collecting operator is a **connected account**.
/// 2. The app asks our back end to create a PaymentIntent:
///    `POST {backendURL}/leap/top-ups { cardId, amount }`. The back end creates it
///    with `transfer_data[destination] = <connected account>` (and an
///    `application_fee_amount` if the platform takes a fee), then returns the
///    `client_secret`, an ephemeral key and the customer ID.
/// 3. The app presents Stripe's PaymentSheet (Apple Pay + cards) from the
///    `stripe-ios` Swift package (`StripePaymentSheet`).
/// 4. The back end credits the cloud Leap balance from Stripe's
///    `payment_intent.succeeded` webhook, never from the app, so a top-up can't be
///    faked client-side. The app then refreshes the balance.
///
/// To enable it, add `StripePublishableKey` and `PaymentsBackendURL` to
/// Secrets.plist, add the `stripe-ios` package, and implement `pay(_:)`.
nonisolated struct StripeConnectPaymentProvider: PaymentProvider {
    let publishableKey: String
    let backendURL: URL

    var disclosure: String { "Payments are processed securely by Stripe." }

    static func fromConfiguration(bundle: Bundle = .main) -> StripeConnectPaymentProvider? {
        guard let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url),
              let key = plist["StripePublishableKey"] as? String, !key.isEmpty,
              let backend = (plist["PaymentsBackendURL"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return StripeConnectPaymentProvider(publishableKey: key, backendURL: backend)
    }

    func pay(_ request: PaymentRequest) async throws -> PaymentReceipt {
        // TODO: Stripe Connect — create the PaymentIntent via `backendURL`, then
        // present PaymentSheet with the returned client secret (see type docs).
        throw PaymentError.notConfigured
    }
}
