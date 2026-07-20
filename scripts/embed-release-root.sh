#!/usr/bin/env bash
set -euo pipefail

root_source='Sources/WtsSDK/ExperienceTrust.swift'
placeholder='__WTS_EXPERIENCE_ROOT_PUBLIC_KEY__'
root_key="${WTS_EXPERIENCE_ROOT_PUBLIC_KEY:-}"

test -n "$root_key" || {
  echo 'WTS_EXPERIENCE_ROOT_PUBLIC_KEY is required for release builds.' >&2
  exit 1
}
printf '%s' "$root_key" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || {
  echo 'Experiences root public key is not canonical base64.' >&2
  exit 1
}

der_file=$(mktemp)
trap 'rm -f "$der_file" "$root_source.bak"' EXIT
printf '%s' "$root_key" | openssl base64 -d -A > "$der_file"
openssl pkey -pubin -inform DER -in "$der_file" -text -noout 2>/dev/null |
  grep -Fq 'ED25519' || {
  echo 'Experiences root public key must be an Ed25519 SPKI DER key.' >&2
  exit 1
}

grep -Fq "$placeholder" "$root_source" || {
  echo 'Experiences root placeholder is missing or was already replaced.' >&2
  exit 1
}
sed -i.bak "s|$placeholder|$root_key|" "$root_source"
rm -f "$root_source.bak"
