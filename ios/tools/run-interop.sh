#!/usr/bin/env bash
# Host-side crypto interop check. Compiles the real app sources — no copies.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
swiftc -O \
  Instant/Core/Crypto/Base64URL.swift \
  Instant/Core/Crypto/InstantCrypto.swift \
  Instant/Core/Crypto/SafetyNumber.swift \
  Instant/Core/Crypto/DeviceIdentity.swift \
  Instant/Core/Store/Keychain.swift \
  tools/interop/main.swift \
  -o "$BUILD/interop"
"$BUILD/interop"
