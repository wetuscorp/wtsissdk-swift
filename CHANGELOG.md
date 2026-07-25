# Changelog

## 0.5.0-alpha.2

- Fixed SwiftPM and CocoaPods releases to carry the canonical production
  Experiences root public key instead of a release-time placeholder.
- Made release validation immutable and reproducible by checking the committed
  Ed25519 SPKI key and production fingerprint without rewriting source.
- Public APIs and Experiences Protocol V2 fixtures are unchanged.

## 0.4.0-alpha.1

- Verify Experience manifests with configured base64 SPKI DER Ed25519 public
  keys before any manifest is parsed or used; unsigned compatibility payloads
  now fail closed.
- Bind each verified signed manifest to its configured source key and reject
  unsafe or insecure Experience deep-link schemes even if a host allowlist is
  misconfigured.
- Gate personalized Experience decisions on a server-accepted `identify`
  binding; contextual delivery remains available while identity is pending.
- Added a manual-presentation handle and explicit render, impression, action,
  dismiss, and render-failure lifecycle acknowledgements with idempotency and
  stale-handle rejection.
- Require an allowlisted host for HTTPS deep-link Experience actions; an
  allowed custom scheme never authorizes an arbitrary HTTPS URL.
- Preserve SDK Test & Validate as an isolated opt-in surface at
  `0.4.0-alpha.1`.

## 0.3.0-alpha.1

- Added Mobile Protocol V3 built-in `screen` events.
- Added explicitly opt-in wts.is Experiences V1 delivery.
- Added contextual/personalized consent, native modal and bottom-sheet rendering, and manual mode.
- Added typed safe-action allowlists and action/availability callbacks.
- Added visibility-qualified impressions and persistent idempotent interaction retry.
- Added opt-in SDK Test Session V1 pairing, diagnostics, isolated probes, and
  explicit test-only Experience impression/action reporting.

## 0.2.0-alpha.1

- Upgraded event delivery to Mobile Protocol V2 while preserving direct Universal Link behavior.
- Added consent-gated Identity V1 operations: `identify`, `updateUser`, `setReportedAttribution`, and `resetIdentity`.
- Added persistent, idempotent identity mutations that flush before queued events.
- Preserved the installation UUID across logout while rotating profile and session identity.
- Reset the server-side profile binding when profile consent is denied.
- Preserved opaque external user IDs and retried retryable batch rejections.
- Added stable public error codes for native and cross-platform callers.

## 0.1.0-alpha.1

- Initial public alpha with direct deep-link resolution, typed errors, local install identity, persistent event/revenue queue, bounded cache and explicit flush.
- iOS deferred deep links intentionally return `nil` in protocol V1.
