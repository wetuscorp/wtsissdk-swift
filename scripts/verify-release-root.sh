#!/usr/bin/env bash
set -euo pipefail

root_source='Sources/WtsSDK/ExperienceTrust.swift'
if grep -Fq '__WTS_EXPERIENCE_ROOT_PUBLIC_KEY__' "$root_source"; then
  echo 'Embed the root ceremony public Ed25519 SPKI key before publishing.' >&2
  exit 1
fi

root_key=$(sed -n 's/.*rootPublicKey = "\([^"]*\)".*/\1/p' "$root_source")
test -n "$root_key" || { echo 'Embedded Experiences root public key is missing.' >&2; exit 1; }
ruby -rbase64 -e 'Base64.strict_decode64(ARGV.fetch(0))' "$root_key" >/dev/null 2>&1 || {
  echo 'Embedded Experiences root public key is not valid base64.' >&2
  exit 1
}
