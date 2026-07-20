import Foundation

enum ExperienceTrust {
  /// Replaced with the root ceremony's base64 SPKI Ed25519 public key before
  /// publishing a release. The release workflow rejects this placeholder.
  static let rootPublicKey = "__WTS_EXPERIENCE_ROOT_PUBLIC_KEY__"
}
