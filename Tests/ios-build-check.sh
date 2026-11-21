#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export TMPDIR="$PWD/.build/tmp"
RUN_DIR="$PWD/.build/ios-build/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$TMPDIR" "$RUN_DIR"
python3 scripts/generate-ios-project.py
for target_platform in iphoneos iphonesimulator; do
  xcodebuild -project iOS/WireCamera.xcodeproj -scheme WireCamera -sdk "$target_platform" -configuration Debug -derivedDataPath "$PWD/.build/ios-derived" CODE_SIGNING_ALLOWED=NO build > "$RUN_DIR/$target_platform.log" 2>&1
done
printf '{"passed":true,"deviceBuild":true,"simulatorBuild":true}\n' > "$RUN_DIR/report.json"
printf 'Artifacts: %s\n' "$RUN_DIR"
