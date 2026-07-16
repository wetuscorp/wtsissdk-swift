# Changelog

## 0.2.0-alpha.1

- Upgraded event delivery to Mobile Protocol V2 while preserving direct Universal Link behavior.
- Added consent-gated Identity V1 operations: `identify`, `updateUser`, `setReportedAttribution`, and `resetIdentity`.
- Added persistent, idempotent identity mutations that flush before queued events.
- Preserved the installation UUID across logout while rotating profile and session identity.

## 0.1.0-alpha.1

- Initial public alpha with direct deep-link resolution, typed errors, local install identity, persistent event/revenue queue, bounded cache and explicit flush.
- iOS deferred deep links intentionally return `nil` in protocol V1.
