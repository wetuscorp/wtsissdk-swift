import CryptoKit
import Foundation

/// Verifies the signed Experience manifest envelope before it can influence
/// runtime decisions. The collector's unsigned `manifest` compatibility field
/// is intentionally never returned or used here.
enum ExperienceManifestVerifier {
  static func verify(
    response: ExperienceBootstrapResponse,
    rootPublicKey: String,
    expectedSourceKey: String,
    now: Date,
    decoder: JSONDecoder
  ) -> ExperienceBootstrapResponse.Manifest? {
    guard
      let rootKeyData = Data(base64Encoded: rootPublicKey),
      let keysetPayload = Data(base64URLEncoded: response.onlineKeyset.signedPayload),
      let rootSignature = Data(base64URLEncoded: response.onlineKeyset.rootSignature),
      let payload = Data(base64URLEncoded: response.signedPayload),
      let signature = Data(base64URLEncoded: response.signature)
    else { return nil }

    do {
      let rootKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: try ed25519RawKey(fromSPKIDER: rootKeyData)
      )
      guard rootKey.isValidSignature(rootSignature, for: keysetPayload) else { return nil }
      let verifiedKeyset = try decoder.decode(
        ExperienceBootstrapResponse.OnlineKeysetPayload.self,
        from: keysetPayload
      )
      guard verifiedKeyset.version == response.onlineKeyset.version,
        verifiedKeyset.issuedAt == response.onlineKeyset.issuedAt,
        verifiedKeyset.expiresAt == response.onlineKeyset.expiresAt,
        verifiedKeyset.keys == response.onlineKeyset.keys,
        verifiedKeyset.issuedAt <= now,
        verifiedKeyset.expiresAt > now,
        let onlineKey = verifiedKeyset.keys.first(where: {
          $0.keyId == response.keyId && $0.algorithm == "Ed25519"
            && $0.notBefore <= now && $0.expiresAt > now
        }),
        let onlineKeyData = Data(base64Encoded: onlineKey.publicKey)
      else { return nil }
      let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: try ed25519RawKey(fromSPKIDER: onlineKeyData)
      )
      guard publicKey.isValidSignature(signature, for: payload) else { return nil }
      let manifest = try decoder.decode(ExperienceBootstrapResponse.Manifest.self, from: payload)
      guard manifest.sourceKey == expectedSourceKey,
        manifest.issuedAt <= now,
        manifest.expiresAt > now,
        WtsISO8601Date.parse(response.expiresAt) == manifest.expiresAt
      else { return nil }
      return manifest
    } catch {
      return nil
    }
  }

  /// CryptoKit accepts Ed25519 raw keys, while the public control-plane API
  /// intentionally exposes portable SPKI DER. Ed25519 SPKI DER has one
  /// canonical, fixed-length SubjectPublicKeyInfo encoding (RFC 8410).
  private static func ed25519RawKey(fromSPKIDER value: Data) throws -> Data {
    let prefix = Data([
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])
    guard value.count == prefix.count + 32, value.starts(with: prefix) else {
      throw VerificationError.invalidSPKIDER
    }
    return value.dropFirst(prefix.count)
  }

  private enum VerificationError: Error {
    case invalidSPKIDER
  }
}

extension ExperienceBootstrapResponse {
  struct OnlineKeysetPayload: Decodable {
    let version: Int
    let issuedAt: Date
    let expiresAt: Date
    let keys: [OnlineKeyset.Key]
  }
}

private extension Data {
  init?(base64URLEncoded value: String) {
    guard !value.isEmpty,
      value.allSatisfy({ character in
        character.isLetter || character.isNumber || character == "-" || character == "_"
      })
    else { return nil }

    var normalized = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    self.init(base64Encoded: normalized)
  }
}
