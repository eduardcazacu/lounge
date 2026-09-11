#!/usr/bin/env bash
# Delivers a real APNs payload to a Simulator and shows what it did to the
# home-screen widget. No Apple Developer account needed: simctl injects the
# payload locally.
#
#   ios/tools/push-test.sh ["iPhone 17"]
#
# One manual step. `simctl push` refuses to deliver to an app that has not been
# granted notification permission, and simctl has no way to grant it — there is
# no `privacy ... notifications` service. So the script launches the app, waits
# for you to tap Allow, and then pushes.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17}"
BUNDLE="com.eduardcazacu.instant"
DERIVED="${DERIVED_DATA:-/tmp/instant-push-test}"

echo "==> building"
xcodebuild build -project Instant.xcodeproj -scheme Instant \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" -quiet

UDID=$(xcrun simctl list devices | grep -m1 "$DEVICE (" | grep -oE "[0-9A-F-]{36}")
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/Instant.app"
xcrun simctl launch "$UDID" "$BUNDLE" --args \
  -instantUITestStubs -instantUITestSignedIn -instantUITestRequestPush >/dev/null

echo
echo "==> tap Allow on the notification prompt in the Simulator, then press return"
read -r _

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true

SNAPSHOT=$(find ~/Library/Developer/CoreSimulator/Devices/"$UDID"/data/Containers/Shared/AppGroup \
  -name widget-snapshot.json 2>/dev/null | head -1)
echo "==> widget snapshot before the push"
python3 -m json.tool "$SNAPSHOT" 2>/dev/null || echo "(none yet)"

PAYLOAD=$(mktemp -t instant-push).apns
cat > "$PAYLOAD" <<JSON
{
  "Simulator Target Bundle": "$BUNDLE",
  "aps": {
    "alert": { "title": "Ana sent you an instant", "body": "Open it before it disappears." },
    "sound": "default",
    "mutable-content": 1
  },
  "data": {
    "openUrl": "/instant",
    "instantId": "11111111-2222-3333-4444-555555555555",
    "senderId": 4242,
    "senderName": "Push Test",
    "senderThemeKey": "gold",
    "senderProfilePictureUrl": null
  }
}
JSON

echo "==> pushing, with the app closed"
xcrun simctl push "$UDID" "$BUNDLE" "$PAYLOAD"
sleep 3

echo "==> widget snapshot after the push"
python3 -m json.tool "$SNAPSHOT"
echo
echo "A 'Push Test' contact above means the Notification Service Extension ran"
echo "and updated the widget without the app being open."
