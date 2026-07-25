import Foundation

enum ExperienceTrust {
  /// Public, long-lived trust anchor used to verify root-signed online keysets.
  /// The corresponding private key is offline and never enters source control.
  static let rootPublicKey =
    "MCowBQYDK2VwAyEAIohLiu8A9lRHsKxWoDnPemlwc+O5lFMxnZNx5oPNuOY="
}
