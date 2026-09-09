#!/usr/bin/env bash
# Delivers a real APNs payload to the Simulator and drives the deep link.
#
# This needs no Apple Developer account: simctl injects the payload locally.
# It covers everything on the device side of a push; what it cannot cover is
# Apple accepting the request the backend sends.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
BUNDLE="com.eduardcazacu.instant"

cat > /tmp/instant-push.apns <<'JSON'
{
  "Simulator Target Bundle": "com.eduardcazacu.instant",
  "aps": {
    "alert": { "title": "Ana sent you an instant", "body": "Open it before it disappears." },
    "sound": "default"
  },
  "data": { "openUrl": "/instant", "instantId": "11111111-2222-3333-4444-555555555555" }
}
JSON

xcrun simctl boot "$DEVICE" 2>/dev/null || true

INSTANT_UITEST_PUSH=1 xcodebuild test \
  -project Instant.xcodeproj -scheme Instant \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:InstantUITests/PushDeepLinkUITests &
TEST_PID=$!

sleep 25
xcrun simctl push "$DEVICE" "$BUNDLE" /tmp/instant-push.apns || true
wait "$TEST_PID"
