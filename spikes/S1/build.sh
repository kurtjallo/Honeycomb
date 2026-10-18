#!/bin/sh
# Builds build/HoneycombS1.app. Usage:
#   ./build.sh                                        ad-hoc signed, version 1
#   VERSION=2 ./build.sh                              a second build, for the update test
#   SIGN_ID="Honeycomb Spike Signing" ./build.sh      signed with the self-signed certificate
set -eu
cd "$(dirname "$0")"
SIGN_ID="${SIGN_ID:--}"
VERSION="${VERSION:-1}"

swift build -c release
APP=build/HoneycombS1.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/S1Capture .build/release/ToneHelper "$APP/Contents/MacOS/"
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"

codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/ToneHelper"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (version $VERSION, signed with: $SIGN_ID)"
codesign --display --requirements - "$APP" 2>/dev/null | grep designated || true
