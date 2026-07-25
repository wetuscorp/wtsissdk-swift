#!/usr/bin/env bash
set -euo pipefail

root_source='Sources/WtsSDK/ExperienceTrust.swift'
expected_key='MCowBQYDK2VwAyEAIohLiu8A9lRHsKxWoDnPemlwc+O5lFMxnZNx5oPNuOY='
expected_fingerprint='SHA256:c_dZ_7kxZ_zrwwzdif7yziZCREvj6PTilcqkacX-ac4'

root_key=$(sed -n '/rootPublicKey =/{n;s/^[[:space:]]*"\([^"]*\)".*/\1/p;}' "$root_source")
test -n "$root_key" || { echo 'Embedded Experiences root public key is missing.' >&2; exit 1; }
test "$root_key" = "$expected_key" || {
  echo 'Embedded Experiences root public key does not match production.' >&2
  exit 1
}

der_file=$(mktemp)
trap 'rm -f "$der_file"' EXIT
printf '%s' "$root_key" | openssl base64 -d -A > "$der_file"
test "$(openssl base64 -A -in "$der_file")" = "$root_key" || {
  echo 'Embedded Experiences root public key is not canonical base64.' >&2
  exit 1
}
openssl pkey -pubin -inform DER -in "$der_file" -text -noout 2>/dev/null |
  grep -Fq 'ED25519' || {
  echo 'Embedded Experiences root public key is not an Ed25519 SPKI DER key.' >&2
  exit 1
}
fingerprint="SHA256:$(openssl dgst -sha256 -binary "$der_file" |
  openssl base64 -A |
  tr '+/' '-_' |
  tr -d '=')"
test "$fingerprint" = "$expected_fingerprint" || {
  echo "Unexpected Experiences root fingerprint: $fingerprint" >&2
  exit 1
}

if test -n "${WTS_EXPERIENCE_ROOT_PUBLIC_KEY:-}"; then
  test "$WTS_EXPERIENCE_ROOT_PUBLIC_KEY" = "$root_key" || {
    echo 'WTS_EXPERIENCE_ROOT_PUBLIC_KEY does not match the committed public root.' >&2
    exit 1
  }
fi

echo "Verified committed Experiences root $expected_fingerprint."
