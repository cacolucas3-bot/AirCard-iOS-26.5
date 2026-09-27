import PassKit

/// Compile-safe scaffold for Apple's issuer provisioning extension.
///
/// This target intentionally does not provision a real card or generate payment
/// credentials. Apple requires issuer entitlement before Wallet can invoke it.
final class IssuerProvisioningExtension: PKIssuerProvisioningExtensionHandler {
    override func status(completion: @escaping (PKIssuerProvisioningExtensionStatus) -> Void) {
        let status = PKIssuerProvisioningExtensionStatus()
        status.passEntriesAvailable = false
        status.remotePassEntriesAvailable = false
        status.requiresAuthentication = false
        completion(status)
    }

    override func passEntries(completion: @escaping ([PKIssuerProvisioningExtensionPassEntry]) -> Void) {
        // No real payment passes are returned. A production issuer implementation
        // would create PKIssuerProvisioningExtensionPaymentPassEntry objects here.
        completion([])
    }

    override func remotePassEntries(completion: @escaping ([PKIssuerProvisioningExtensionPassEntry]) -> Void) {
        completion([])
    }

    override func generateAddPaymentPassRequestForPassEntryWithIdentifier(
        _ identifier: String,
        configuration: PKAddPaymentPassRequestConfiguration,
        certificateChain certificates: [Data],
        nonce: Data,
        nonceSignature: Data,
        completionHandler completion: @escaping (PKAddPaymentPassRequest?) -> Void
    ) {
        // Deliberately return nil: no issuer backend, card credentials, or
        // cryptographic provisioning flow is present in this lab scaffold.
        completion(nil)
    }
}
