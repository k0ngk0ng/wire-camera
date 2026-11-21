#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export TMPDIR="$PWD/.build/tmp"
RUN_DIR="$PWD/.build/ios-install/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR" "$TMPDIR"
TEAM_ID="${WIRECAMERA_TEAM_ID:?请通过 WIRECAMERA_TEAM_ID 指定 Xcode Personal Team 标识。}"
DEVICE_ID="${WIRECAMERA_DEVICE_ID:?请通过 WIRECAMERA_DEVICE_ID 指定已配对的 iPhone 标识。}"
xcodebuild -project iOS/WireCamera.xcodeproj -scheme WireCamera -configuration Release -destination "id=$DEVICE_ID" -derivedDataPath "$PWD/.build/ios-derived" -allowProvisioningUpdates -allowProvisioningDeviceRegistration "DEVELOPMENT_TEAM=$TEAM_ID" build > "$RUN_DIR/build.log" 2>&1
APP_PATH="$PWD/.build/ios-derived/Build/Products/Release-iphoneos/WireCamera.app"
codesign --verify --deep --strict "$APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" > "$RUN_DIR/install.log" 2>&1
xcrun devicectl device process launch --device "$DEVICE_ID" com.wirecamera.iphone.k0ngk0ng > "$RUN_DIR/launch.log" 2>&1
printf '{"passed":true,"installed":true,"launched":true,"version":"1.0.0"}\n' > "$RUN_DIR/report.json"
printf 'Artifacts: %s\n' "$RUN_DIR"
