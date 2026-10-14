#!/bin/bash
# Builds build/Dead Air.app. Set CODESIGN_IDENTITY to sign with a real
# certificate; otherwise it's ad-hoc signed (macOS may re-ask for microphone
# access after each rebuild).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DeadAir"

APP="build/Dead Air.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeadAir"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime --entitlements Resources/DeadAir.entitlements --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
